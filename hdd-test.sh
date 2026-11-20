#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
RUNS_DIR=$SCRIPT_DIR/runs

BLOCKSIZE=4096
BLOCKSIZE_SET=0
SMART_TYPE=""
SMART_TYPE_SET=0
SKIP_SHORT=0
SKIP_LONG=0
ASSUME_YES=0
SELFTEST_POLL=60
SELFTEST_MAX_WAIT=86400
CMD=""
DEV_ARG=""
OUT_DIR=""
RUN_DIR=""
DEV=""
BYID=""
MODEL=""
SERIAL=""
CAPACITY=""
START_ISO=""
START_EPOCH=""
STAGE_NAME=""
STAGE_T0=0
VERDICT=""
ORIG_ARGS=("$@")

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
num() { local v=${1//[^0-9]/}; printf '%s' "${v:-0}"; }
fmt_size() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s B' "$1"; }
fmt_dur() {
  local s=$1
  if ((s >= 3600)); then
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif ((s >= 60)); then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$RUN_DIR/log.txt"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

usage() {
  cat <<'EOF'
用法: hdd-test.sh <命令> [设备] [选项]

命令:
  list                 列出候选磁盘（无需 root）
  all <设备>            基线 -> 测速 -> 短自检 -> 长自检 -> 读扫描 -> 报告
  baseline <设备>       只取 SMART 基线
  selftest <设备>       SMART 短自检 + 长自检
  read <设备>           全盘只读扫描 (badblocks)
  write <设备>          全盘写测试，破坏数据，必须加 --yes
  bench <设备>          顺序读速度
  report [目录]         用已保存的数据重新生成报告（默认最近一次）

选项:
  -o, --out DIR         结果目录；不给则用 runs/<时间>-<序列号>，同一块盘自动复用
  -b, --blocksize N     badblocks 块大小，默认 4096
  -d, --smart-type T    传给 smartctl -d，USB 桥接常用 sat
      --yes             确认执行破坏性写测试
      --skip-short      跳过短自检
      --skip-long       跳过长自检
  -h, --help

示例:
  sudo ./hdd-test.sh all /dev/sda
  sudo ./hdd-test.sh all /dev/sdb --skip-short
  sudo ./hdd-test.sh write /dev/sdb --yes
  ./hdd-test.sh report

判定: PASS=0, WARN=1, FAIL=2
EOF
}

while (($#)); do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    -o | --out)
      OUT_DIR=${2:-}
      [[ -n $OUT_DIR ]] || die "--out 需要参数"
      shift 2
      ;;
    -b | --blocksize)
      BLOCKSIZE=${2:-}
      BLOCKSIZE_SET=1
      [[ $BLOCKSIZE =~ ^[0-9]+$ ]] || die "块大小必须是数字"
      shift 2
      ;;
    -d | --smart-type)
      SMART_TYPE=${2:-}
      SMART_TYPE_SET=1
      [[ -n $SMART_TYPE ]] || die "--smart-type 需要参数"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --skip-short)
      SKIP_SHORT=1
      shift
      ;;
    --skip-long)
      SKIP_LONG=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "未知选项: $1"
      ;;
    *)
      if [[ -z $CMD ]]; then
        CMD=$1
      elif [[ -z $DEV_ARG ]]; then
        DEV_ARG=$1
      else
        die "多余参数: $1"
      fi
      shift
      ;;
  esac
done

[[ -n $CMD ]] || {
  usage
  exit 1
}

smart() {
  if [[ -n ${SMART_TYPE:-} ]]; then
    smartctl -d "$SMART_TYPE" "$@"
  else
    smartctl "$@"
  fi
}

resolve_byid() {
  local real=$1 p best=""
  for p in /dev/disk/by-id/*; do
    [[ -L $p ]] || continue
    [[ $(readlink -f -- "$p") == "$real" ]] || continue
    case $p in
      *-part*) continue ;;
    esac
    best=$p
    case $p in
      *ata-* | *wwn-*) break ;;
    esac
  done
  if [[ -n $best ]]; then printf '%s\n' "$best"; else printf '%s\n' "$real"; fi
}

detect_smart_type() {
  if [[ $SMART_TYPE_SET -eq 1 ]]; then
    smartctl -d "$SMART_TYPE" -i "$DEV" >/dev/null 2>&1 || die "smartctl -d $SMART_TYPE 无法访问 $DEV"
    return 0
  fi
  if smartctl -i "$DEV" >/dev/null 2>&1; then
    return 0
  fi
  if smartctl -d sat -i "$DEV" >/dev/null 2>&1; then
    SMART_TYPE=sat
    printf '直接访问失败，自动改用 smartctl -d sat\n'
    return 0
  fi
  die "无法通过 SMART 访问 $DEV；USB 桥接可试 -d sat / -d usbjmicron"
}

read_info() {
  local out
  out=$(smart -i "$DEV") || die "无法读取 $DEV 的基本信息"
  MODEL=$(printf '%s\n' "$out" | awk -F': *' '/^Device Model:/{print $2; exit}')
  SERIAL=$(printf '%s\n' "$out" | awk -F': *' '/^Serial Number:/{print $2; exit}')
  CAPACITY=$(printf '%s\n' "$out" | awk -F': *' '/^User Capacity:/{print $2; exit}')
  if [[ -z $SERIAL ]]; then
    SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | head -n1 | tr -d ' ' || true)
  fi
  [[ -n $MODEL && -n $SERIAL ]] || die "解析型号/序列号失败，无法唯一标识这块盘"
  if ! printf '%s\n' "$out" | grep -q 'SMART support is:.*Enabled'; then
    printf '警告: 这块盘的 SMART 未启用，报告字段会缺失\n' >&2
  fi
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

state_var() {
  local dir=$1 key=$2
  [[ -f $dir/state.env ]] || return 0
  (
    set +u
    # shellcheck disable=SC1090
    source "$dir/state.env"
    printf '%s' "${!key:-}"
  )
}

find_run_for_serial() {
  local serial=$1 d
  [[ -d $RUNS_DIR ]] || return 1
  while IFS= read -r d; do
    d=${d%/}
    [[ -f $d/state.env ]] || continue
    if [[ $(state_var "$d" SERIAL) == "$serial" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  return 1
}

latest_run() {
  [[ -d $RUNS_DIR ]] || return 1
  find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-
}

write_state() {
  {
    printf 'DEV=%q\n' "$DEV"
    printf 'BYID=%q\n' "$BYID"
    printf 'MODEL=%q\n' "$MODEL"
    printf 'SERIAL=%q\n' "$SERIAL"
    printf 'CAPACITY=%q\n' "$CAPACITY"
    printf 'SMART_TYPE=%q\n' "$SMART_TYPE"
    printf 'BLOCKSIZE=%q\n' "$BLOCKSIZE"
    printf 'START_ISO=%q\n' "$START_ISO"
    printf 'START_EPOCH=%q\n' "$START_EPOCH"
  } >"$RUN_DIR/state.env"
}

write_env() {
  {
    printf '时间: %s\n' "$(ts)"
    printf '主机: %s\n' "$(hostname)"
    printf '内核: %s\n' "$(uname -r)"
    printf 'smartctl: %s\n' "$(smartctl --version | head -n1)"
    printf '路径: %s\n' "$DEV"
    printf 'by-id: %s\n' "$BYID"
    printf '容量: %s\n\n' "$(fmt_size "$(blockdev --getsize64 "$DEV")")"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,PTTYPE,MOUNTPOINTS "$DEV" || true
    printf '\n'
    smart -i "$DEV" || true
  } >"$RUN_DIR/env.txt"
}

init_run() {
  [[ -n $DEV_ARG ]] || die "缺少设备参数，例如 /dev/sda"
  [[ -b $(readlink -f -- "$DEV_ARG") ]] || die "$DEV_ARG 不是块设备"
  DEV=$(readlink -f -- "$DEV_ARG")
  detect_smart_type
  read_info
  BYID=$(resolve_byid "$DEV")
  START_ISO=$(ts)
  START_EPOCH=$(date +%s)

  if [[ -n $OUT_DIR ]]; then
    RUN_DIR=${OUT_DIR%/}
  else
    local found=""
    found=$(find_run_for_serial "$SERIAL" || true)
    if [[ -n $found ]]; then
      RUN_DIR=$found
    else
      RUN_DIR=$RUNS_DIR/$(date +%Y%m%d-%H%M%S)-$(safe_name "$SERIAL")
    fi
  fi
  mkdir -p "$RUN_DIR"

  if [[ -f $RUN_DIR/state.env ]]; then
    local saved
    saved=$(state_var "$RUN_DIR" SERIAL)
    [[ $saved == "$SERIAL" ]] || die "目录 $RUN_DIR 记录的是 $saved，当前设备是 $SERIAL，拒绝混用"
    [[ $BLOCKSIZE_SET -eq 1 ]] || BLOCKSIZE=$(state_var "$RUN_DIR" BLOCKSIZE)
    [[ $SMART_TYPE_SET -eq 1 ]] || SMART_TYPE=$(state_var "$RUN_DIR" SMART_TYPE)
    START_ISO=$(state_var "$RUN_DIR" START_ISO)
    START_EPOCH=$(state_var "$RUN_DIR" START_EPOCH)
  fi

  write_state
  write_env
  printf '设备: %s (%s)\n型号: %s\n序列号: %s\n结果目录: %s\n' "$DEV" "$BYID" "$MODEL" "$SERIAL" "$RUN_DIR"
}

mounted_targets() {
  lsblk -no MOUNTPOINTS "$DEV" 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u
}

root_disk() {
  local src dev
  src=$(findmnt -no SOURCE / 2>/dev/null || true)
  [[ -n $src ]] || return 1
  src=${src%%[*}
  dev=$(lsblk -sno NAME,TYPE -- "$src" 2>/dev/null | awk '$2 == "disk" { sub(/^[^A-Za-z0-9]+/, "", $1); print $1; exit }')
  [[ -n $dev ]] || return 1
  printf '/dev/%s' "$dev"
}

guard_read() {
  local rd m
  rd=$(root_disk || true)
  [[ -n $rd && $DEV == "$rd" ]] && die "$DEV 是系统盘，拒绝读扫描（会拖垮系统）"
  m=$(mounted_targets)
  if [[ -n $m && $ASSUME_YES -eq 0 ]]; then
    die "$DEV 仍有挂载: $(printf '%s ' $m)；只读扫描也会占满 IO，确认后加 --yes"
  fi
}

guard_write() {
  local rd m
  rd=$(root_disk || true)
  [[ -n $rd && $DEV == "$rd" ]] && die "$DEV 是系统盘，拒绝写测试"
  m=$(mounted_targets)
  [[ -z $m ]] || die "$DEV 有已挂载的分区: $(printf '%s ' $m)，先卸载"
  [[ $ASSUME_YES -eq 1 ]] || die "写测试会清空 $DEV，确认后加 --yes"
}

attr_field() {
  local file=$1 id=$2 fld=$3
  [[ -f $file ]] || return 0
  awk -v id="$id" -v fld="$fld" '$1 == id { print $fld; exit }' "$file"
}

attr_delta() {
  local before=$1 after=$2
  if [[ -z $before || -z $after ]]; then
    printf '—'
    return
  fi
  local bn an
  bn=$(num "$before")
  an=$(num "$after")
  if ((an > bn)); then
    printf '+%d' $((an - bn))
  elif ((an < bn)); then
    printf -- '-%d' $((bn - an))
  else
    printf '0'
  fi
}

count_blocks() {
  local file=$1 n
  [[ -f $file ]] || {
    printf '0'
    return
  }
  n=$(grep -cE '^[0-9]+$' "$file" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

count_dmesg() {
  local file=$1 n
  [[ -f $file ]] || {
    printf '0'
    return
  }
  n=$(grep -ciE 'I/O error|failed command|hard resetting|link is slow|exception Emask|SError|ata[0-9]+\.[0-9]+: (error|failed)' "$file" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

dmesg_snapshot() {
  local tag=$1
  dmesg --time-format=iso 2>/dev/null |
    grep -iE 'ata[0-9]+|sd [a-z]|I/O error|reset|failed command|SError|Emask' \
      >"$RUN_DIR/dmesg-$tag.log" || true
}

selftest_lines() {
  local file=$1
  [[ -f $file ]] || return 0
  grep -E '^#[[:space:]]*[0-9]+' "$file" 2>/dev/null || true
}

selftest_latest() {
  selftest_lines "$1" | head -n1 || true
}

latest_attrs_file() {
  local f
  for f in smart-attrs-after-write.txt smart-attrs-after-read.txt smart-attrs-after-selftest.txt smart-attrs-before.txt; do
    if [[ -f $RUN_DIR/$f ]]; then
      printf '%s\n' "$RUN_DIR/$f"
      return 0
    fi
  done
  return 0
}

latest_selftest_file() {
  local f
  for f in selftest-after-write.txt selftest-after-read.txt selftest-final.txt selftest-after-selftest.txt selftest-long.txt selftest-before.txt; do
    if [[ -f $RUN_DIR/$f ]]; then
      printf '%s\n' "$RUN_DIR/$f"
      return 0
    fi
  done
  return 0
}

latest_dmesg_file() {
  local f
  for f in dmesg-after-write.log dmesg-after-read.log dmesg-after-selftest.log dmesg-baseline.log; do
    if [[ -f $RUN_DIR/$f ]]; then
      printf '%s\n' "$RUN_DIR/$f"
      return 0
    fi
  done
  return 0
}

stage_start() {
  STAGE_NAME=$1
  STAGE_T0=$(date +%s)
  log "=== $STAGE_NAME 开始 ==="
}

stage_stop() {
  local secs=$(( $(date +%s) - STAGE_T0 ))
  log "=== $STAGE_NAME 结束，用时 $(fmt_dur "$secs") ==="
  printf '%s\t%s\t%s\n' "$STAGE_NAME" "$secs" "$(ts)" >>"$RUN_DIR/timings.tsv"
}

snapshot() {
  local tag=$1
  if [[ ! -b $DEV ]]; then
    log "设备已消失，跳过 $tag 快照"
    return 0
  fi
  smart -A "$DEV" >"$RUN_DIR/smart-attrs-after-$tag.txt" 2>&1 || true
  smart -l selftest "$DEV" >"$RUN_DIR/selftest-after-$tag.txt" 2>&1 || true
  smart -l error "$DEV" >"$RUN_DIR/error-after-$tag.txt" 2>&1 || true
  dmesg_snapshot "$tag"
}

take_baseline() {
  stage_start baseline
  smart -x "$DEV" >"$RUN_DIR/smart-before.txt" 2>&1 || true
  smart -A "$DEV" >"$RUN_DIR/smart-attrs-before.txt" 2>&1 || true
  smart -l selftest "$DEV" >"$RUN_DIR/selftest-before.txt" 2>&1 || true
  smart -l error "$DEV" >"$RUN_DIR/error-before.txt" 2>&1 || true
  dmesg_snapshot baseline
  stage_stop
}

ensure_baseline() {
  if [[ -s $RUN_DIR/smart-attrs-before.txt ]]; then
    printf '已有基线，跳过\n'
    return 0
  fi
  take_baseline
}

run_selftest() {
  local kind=$1 name=$2 file=$RUN_DIR/selftest-$2.txt out
  stage_start "$name"
  if ! out=$(smart -t "$kind" "$DEV" 2>&1); then
    printf '%s\n' "$out" | tee "$file"
    log "$kind 自检启动失败"
    stage_stop
    return 1
  fi
  printf '%s\n' "$out" | tee "$file"
  sleep 5
  local waited=0 status pct
  while :; do
    status=$(smart -a "$DEV" 2>/dev/null || true)
    if ! grep -qi 'Self-test routine in progress' <<<"$status"; then
      break
    fi
    pct=$(grep -oE '[0-9]+% of test remaining' <<<"$status" | tail -n1 || true)
    printf '\r[%s] %s 进行中 %s    ' "$(ts)" "$kind" "${pct:-?}" >&2
    sleep "$SELFTEST_POLL"
    waited=$((waited + SELFTEST_POLL))
    if ((waited >= SELFTEST_MAX_WAIT)); then
      printf '\n等待超时，自检可能仍在后台运行\n' >&2
      break
    fi
  done
  printf '\n' >&2
  smart -l selftest "$DEV" | tee -a "$file" || true
  stage_stop
}

main_bench() {
  stage_start bench
  {
    if command -v hdparm >/dev/null 2>&1; then
      printf '== hdparm -t --direct ==\n'
      hdparm -t --direct "$DEV" 2>&1 || true
    else
      printf 'hdparm 未安装，跳过\n'
    fi
    printf '\n== dd 读取前 2 GiB ==\n'
    { time dd if="$DEV" of=/dev/null bs=1M count=2048 iflag=direct 2>&1; } 2>&1 || true
  } | tee "$RUN_DIR/bench.txt"
  stage_stop
}

main_selftest() {
  if [[ $SKIP_SHORT -eq 0 ]]; then
    run_selftest short short || true
    snapshot selftest
  fi
  if [[ $SKIP_LONG -eq 0 ]]; then
    run_selftest long long || true
  fi
  smart -l selftest "$DEV" >"$RUN_DIR/selftest-final.txt" 2>&1 || true
  snapshot selftest
}

main_read() {
  guard_read
  local size
  size=$(blockdev --getsize64 "$DEV")
  printf '只读扫描 %s (%s)，预计 %s\n' "$DEV" "$(fmt_size "$size")" "$(awk -v b="$size" 'BEGIN{printf "%.1f 小时", b/130e6/3600}')"
  stage_start read
  set +e
  badblocks -b "$BLOCKSIZE" -sv -o "$RUN_DIR/badblocks-read.txt" "$DEV" 2>&1 | tee "$RUN_DIR/badblocks-read.log"
  local rc=${PIPESTATUS[0]}
  set -e
  log "badblocks 退出码 $rc"
  snapshot read
  stage_stop
}

main_write() {
  guard_write
  local size
  size=$(blockdev --getsize64 "$DEV")
  printf '即将对 %s (%s) 执行写测试，盘上数据全部丢失。10 秒后开始，Ctrl-C 取消\n' "$DEV" "$(fmt_size "$size")"
  sleep 10
  stage_start write
  set +e
  badblocks -b "$BLOCKSIZE" -wsv -o "$RUN_DIR/badblocks-write.txt" "$DEV" 2>&1 | tee "$RUN_DIR/badblocks-write.log"
  local rc=${PIPESTATUS[0]}
  set -e
  log "badblocks 退出码 $rc"
  snapshot write
  stage_stop
}

generate_report() {
  local attrs_before=$RUN_DIR/smart-attrs-before.txt
  local attrs_after stfile dm_before dm_after
  attrs_after=$(latest_attrs_file)
  stfile=$(latest_selftest_file)
  dm_before=$RUN_DIR/dmesg-baseline.log
  dm_after=$(latest_dmesg_file)

  local -a fails=() warns=() rows=() bb_rows=()
  local id name b_raw b_norm a_raw a_norm bn an

  if [[ -z $attrs_after ]]; then
    fails+=("没有可用的 SMART 属性数据，无法评估")
  fi

  for id in 5 10 183 184 187 196 197 198 199 4 9 12 193 190 194 191; do
    b_raw=$(attr_field "$attrs_before" "$id" 10)
    b_norm=$(attr_field "$attrs_before" "$id" 4)
    a_raw=$(attr_field "$attrs_after" "$id" 10)
    a_norm=$(attr_field "$attrs_after" "$id" 4)
    if [[ -z $b_raw && -z $a_raw ]]; then
      continue
    fi
    name=$(attr_field "$attrs_after" "$id" 2)
    [[ -z $name ]] && name=$(attr_field "$attrs_before" "$id" 2)
    rows+=("| $id | ${name:-?} | ${b_raw:-—} (${b_norm:-—}) | ${a_raw:-—} (${a_norm:-—}) | $(attr_delta "$b_raw" "$a_raw") |")

    if [[ -n $b_raw && -n $a_raw ]]; then
      bn=$(num "$b_raw")
      an=$(num "$a_raw")
      if ((an > bn)); then
        case $id in
          5 | 197 | 198) fails+=("属性 $id $name: $b_raw -> $a_raw") ;;
          *) warns+=("属性 $id $name: $b_raw -> $a_raw") ;;
        esac
      fi
    fi

    if [[ -n $b_raw ]]; then
      bn=$(num "$b_raw")
      case $id in
        5 | 197 | 198)
          if ((bn > 0)); then fails+=("属性 $id $name 基线已非 0: $b_raw"); fi
          ;;
        183)
          if ((bn > 0)); then warns+=("属性 183 运行时坏块 $b_raw（归一化 ${b_norm:-?}）"); fi
          ;;
        199)
          if ((bn > 0)); then warns+=("属性 199 接口 CRC $b_raw，检查线材/桥接"); fi
          ;;
      esac
    fi
  done

  if [[ -n $stfile ]]; then
    local line
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      if grep -qiE 'failure|fatal|aborted|interrupted' <<<"$line"; then
        fails+=("自检记录: $(sed -E 's/^#[[:space:]]*[0-9]+[[:space:]]+//' <<<"$line")")
      fi
    done < <(selftest_lines "$stfile")
  fi

  local kind kindfile kindlog n
  for kind in read write; do
    kindfile=$RUN_DIR/badblocks-$kind.txt
    kindlog=$RUN_DIR/badblocks-$kind.log
    [[ -f $kindlog ]] || continue
    n=$(count_blocks "$kindfile")
    if [[ -f $kindfile ]]; then
      bb_rows+=("| $kind | $n | $kindfile |")
    else
      bb_rows+=("| $kind | 未生成列表 | $kindlog |")
    fi
    if ((n > 0)); then
      fails+=("$kind 扫描发现 $n 个坏块")
    fi
  done

  local db da temp poh
  db=$(count_dmesg "$dm_before")
  da=$(count_dmesg "$dm_after")
  if ((da > db)); then
    warns+=("内核日志新增 ATA 错误: $db -> $da")
  fi
  temp=$(num "$(attr_field "$attrs_after" 194 10)")
  if ((temp == 0)); then temp=$(num "$(attr_field "$attrs_after" 190 10)"); fi
  if ((temp > 50)); then warns+=("温度 ${temp}°C 偏高"); fi
  poh=$(num "$(attr_field "$attrs_after" 9 10)")
  if ((poh > 30000)); then warns+=("通电时间 ${poh} 小时"); fi

  if [[ ! -f $RUN_DIR/badblocks-read.log && ! -f $RUN_DIR/badblocks-write.log && -z $stfile ]]; then
    warns+=("未执行任何扫描或自检，结论没有意义")
  fi

  VERDICT=PASS
  if ((${#fails[@]} > 0)); then
    VERDICT=FAIL
  elif ((${#warns[@]} > 0)); then
    VERDICT=WARN
  fi

  {
    printf '# 硬盘检测报告\n\n'
    printf -- '- 生成时间: %s\n' "$(ts)"
    printf -- '- 设备: %s\n' "${DEV:-未知}"
    printf -- '- by-id: %s\n' "${BYID:-未知}"
    printf -- '- 型号: %s\n' "${MODEL:-未知}"
    printf -- '- 序列号: %s\n' "${SERIAL:-未知}"
    printf -- '- 容量: %s\n' "${CAPACITY:-未知}"
    printf -- '- 测试开始: %s\n' "${START_ISO:-未知}"
    printf -- '- badblocks 块大小: %s 字节（坏块号为该大小的块序号）\n\n' "${BLOCKSIZE:-?}"
    printf '## 结论\n\n**%s**\n\n' "$VERDICT"
    if ((${#fails[@]} > 0)); then
      printf '### 失败项\n\n'
      printf -- '- %s\n' "${fails[@]}"
      printf '\n'
    fi
    if ((${#warns[@]} > 0)); then
      printf '### 警告项\n\n'
      printf -- '- %s\n' "${warns[@]}"
      printf '\n'
    fi
    printf '## SMART 属性\n\n'
    printf '| ID | 名称 | 测试前 raw(归一化) | 测试后 raw(归一化) | 变化 |\n'
    printf '|---|---|---|---|---|\n'
    if ((${#rows[@]} > 0)); then
      printf '%s\n' "${rows[@]}"
    else
      printf '| — | 无数据 | — | — | — |\n'
    fi
    printf '\n'
    printf '## 自检\n\n'
    local f line
    local found=0
    for f in "$RUN_DIR"/selftest-*.txt; do
      [[ -f $f ]] || continue
      found=1
      line=$(selftest_latest "$f")
      printf -- '- `%s`: %s\n' "$(basename "$f")" "${line:-无记录}"
    done
    if ((found == 0)); then
      printf '未运行自检。\n'
    fi
    printf '\n## 全盘扫描\n\n'
    if ((${#bb_rows[@]} > 0)); then
      printf '| 阶段 | 坏块数 | 明细 |\n|---|---|---|\n'
      printf '%s\n' "${bb_rows[@]}"
    else
      printf '未运行 badblocks。\n'
    fi
    printf '\n## 内核日志\n\n'
    printf -- '- 基线匹配行: %s\n' "$db"
    printf -- '- 测试后匹配行: %s\n\n' "$da"
    printf '## 各阶段耗时\n\n'
    if [[ -f $RUN_DIR/timings.tsv ]]; then
      printf '| 阶段 | 秒 | 结束时间 |\n|---|---|---|\n'
      awk -F'\t' '{printf "| %s | %s | %s |\n", $1, $2, $3}' "$RUN_DIR/timings.tsv"
    else
      printf '无记录。\n'
    fi
    printf '\n## 覆盖情况\n\n'
    [[ -f $RUN_DIR/badblocks-read.log ]] || printf -- '- 未执行只读扫描\n'
    [[ -f $RUN_DIR/badblocks-write.log ]] || printf -- '- 未执行写测试（需要 --yes 且盘上无数据）\n'
    [[ -n $stfile ]] || printf -- '- 未执行 SMART 自检\n'
    printf '\n## 文件\n\n'
    ls -1 "$RUN_DIR"
    printf '\n'
  } >"$RUN_DIR/REPORT.md"

  {
    printf '硬盘检测结果 %s\n' "$(ts)"
    printf '型号: %s\n序列号: %s\n容量: %s\n' "${MODEL:-?}" "${SERIAL:-?}" "${CAPACITY:-?}"
    printf '结论: %s\n' "$VERDICT"
    if ((${#fails[@]} > 0)); then
      printf '\n问题:\n'
      printf -- '- %s\n' "${fails[@]}"
    fi
    if ((${#warns[@]} > 0)); then
      printf '\n需要注意:\n'
      printf -- '- %s\n' "${warns[@]}"
    fi
    printf '\n原始数据: %s\n报告: %s/REPORT.md\n' "$RUN_DIR" "$RUN_DIR"
  } >"$RUN_DIR/seller-summary.txt"

  printf '\n结论: %s\n' "$VERDICT"
  if ((${#fails[@]} > 0)); then
    printf '失败项:\n'
    printf -- '  - %s\n' "${fails[@]}"
  fi
  if ((${#warns[@]} > 0)); then
    printf '警告项:\n'
    printf -- '  - %s\n' "${warns[@]}"
  fi
  printf '报告: %s/REPORT.md\n商家摘要: %s/seller-summary.txt\n' "$RUN_DIR" "$RUN_DIR"
}

cmd_list() {
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN,ROTA,TYPE
  printf '\n分区与挂载:\n'
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
}

cmd_report() {
  local dir=${DEV_ARG:-${OUT_DIR:-}}
  if [[ -z $dir ]]; then
    dir=$(latest_run) || die "找不到结果目录，请指定路径"
  fi
  [[ -d $dir ]] || die "目录不存在: $dir"
  RUN_DIR=${dir%/}
  if [[ -f $RUN_DIR/state.env ]]; then
    # shellcheck disable=SC1091
    source "$RUN_DIR/state.env"
  fi
  generate_report
  printf '结果目录: %s\n' "$RUN_DIR"
  case $VERDICT in
    FAIL) return 2 ;;
    WARN) return 1 ;;
    *) return 0 ;;
  esac
}

case $CMD in
  list)
    cmd_list
    exit 0
    ;;
  report)
    if cmd_report; then exit 0; else exit $?; fi
    ;;
  all | baseline | selftest | read | write | bench) ;;
  *)
    die "未知命令: $CMD"
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  if [[ -t 0 ]]; then
    printf '需要 root，改用 sudo 重新执行\n'
    exec sudo -- "$SELF" "${ORIG_ARGS[@]}"
  fi
  die "需要 root，请用 sudo 运行"
fi

for c in smartctl badblocks lsblk blockdev findmnt dmesg numfmt awk; do
  need_cmd "$c"
done

case $CMD in
  all)
    init_run
    ensure_baseline
    main_bench
    main_selftest
    main_read
    generate_report
    ;;
  baseline)
    init_run
    take_baseline
    ;;
  selftest)
    init_run
    ensure_baseline
    main_selftest
    generate_report
    ;;
  read)
    init_run
    ensure_baseline
    main_read
    generate_report
    ;;
  write)
    init_run
    ensure_baseline
    main_write
    generate_report
    ;;
  bench)
    init_run
    ensure_baseline
    main_bench
    ;;
esac
