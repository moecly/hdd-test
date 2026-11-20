# hdd-test

二手机械硬盘到货体检。跑 SMART 自检、全盘只读扫描、可选的破坏性写测试，把每一步的原始输出留在结果目录里，最后生成 `REPORT.md` 和可以直接粘贴给商家的 `seller-summary.txt`。

## 依赖

`smartctl`（smartmontools）、`badblocks`（e2fsprogs）、`lsblk`/`blockdev`/`findmnt`/`dmesg`（util-linux）、`hdparm`（可选）。

`nix develop` 里已经装好；其他发行版：

```bash
sudo apt install smartmontools e2fsprogs hdparm util-linux
```

## 快速开始

```bash
# 1. 看有哪些盘
./hdd-test.sh list

# 2. 基线 + 测速 + 短/长自检 + 全盘只读扫描 + 报告
sudo ./hdd-test.sh all /dev/sdb

# 3. 盘上没有要留的数据，再补一次写测试（会清空全盘）
sudo ./hdd-test.sh write /dev/sdb --yes

# 4. 随时根据已有数据重新出报告
./hdd-test.sh report
```

`all` 不包含写测试。脚本会自动跳过已经完成的阶段（同一块盘按序列号复用结果目录），中断后重跑同一条命令即可。

## 命令

| 命令 | 做什么 | 需要 root |
|---|---|---|
| `list` | 列出磁盘、分区、挂载点 | 否 |
| `all <dev>` | baseline → bench → selftest → read → report | 是 |
| `baseline <dev>` | 保存 SMART 基线、自检日志、错误日志、内核日志 | 是 |
| `selftest <dev>` | 短自检 + 长自检，轮询到结束 | 是 |
| `read <dev>` | `badblocks -b 4096 -sv` 全盘只读 | 是 |
| `write <dev>` | `badblocks -b 4096 -wsv` 写+校验 4 轮 | 是 |
| `bench <dev>` | `hdparm -t --direct` + `dd` 前 2 GiB | 是 |
| `report [dir]` | 读结果目录重新生成报告 | 否 |

选项：`-o/--out DIR`、`-b/--blocksize N`、`-d/--smart-type T`、`--yes`、`--skip-short`、`--skip-long`。

退出码：`0` PASS，`1` WARN，`2` FAIL。

## 结果目录

默认 `runs/<时间>-<序列号>/`，同一块盘再次运行会复用原目录。

| 文件 | 内容 |
|---|---|
| `REPORT.md` | 结论、逐项属性前后对比、坏块数、覆盖情况 |
| `seller-summary.txt` | 纯文本摘要，直接发给商家 |
| `smart-before.txt` / `smart-attrs-before.txt` | 测试前完整 SMART / 属性表 |
| `smart-attrs-after-<stage>.txt` | 每个阶段结束后的属性表（用来算增量） |
| `selftest-*.txt` | 自检命令输出与自检日志 |
| `error-*.txt` | ATA 错误日志 |
| `badblocks-read.txt` / `badblocks-write.txt` | 坏块号列表（`-o` 输出，纯数字，单位是 `-b` 指定的块大小） |
| `badblocks-*.log` | 扫描过程与进度 |
| `dmesg-*.log` | 各阶段的内核 ATA 日志快照 |
| `timings.tsv` | 各阶段耗时 |
| `bench.txt` | 顺序读速度 |
| `env.txt` | 主机、内核、smartctl 版本、lsblk、`smartctl -i` |
| `log.txt` | 阶段开始/结束时间线 |

## 判定规则

FAIL：

- 5 重映射、197 待定、198 离线不可纠，任意一项**基线非 0 或测试中增长**
- 自检日志出现 read/write failure、fatal、aborted、interrupted
- `badblocks` 读出任何坏块

WARN：

- 183 运行时坏块非 0、199 接口 CRC 非 0 或增长
- 187 报告不可纠错增长
- 内核日志新增 ATA error / reset / failed command
- 温度 > 50 °C，通电时间 > 30000 小时
- 没有执行任何扫描或自检

## 时间预估

按 130 MB/s 估算，写测试按 8 个全盘 pass 算：

| 容量 | 只读扫描 | 写测试 | SMART 长自检 |
|---|---|---|---|
| 320 GB | ~45 分钟 | ~6 小时 | ~71 分钟 |
| 500 GB | ~70 分钟 | ~9 小时 | ~85 分钟 |
| 3 TB | ~6 小时 | ~50 小时 | 6–9 小时 |

长自检时长由固件在上电时给出，脚本按盘上报的进度轮询，不会提前结束。

## 注意

- **写测试是破坏性的**，会把分区表和数据一起清掉；脚本会拒绝系统盘、拒绝仍有挂载分区的盘，并要求 `--yes`。
- 读扫描也拒绝系统盘；有挂载时要求 `--yes`，因为会占满 IO。
- USB 硬盘盒经常不透传 SMART，长自检也可能失败。优先直插 SATA；只能 USB 时用 `-d sat`（脚本会自动尝试），并用 `smartctl -x` 确认能读到属性。
- 不要用 `chkdsk /r` 或 `fsck` 代替盘面扫描：它们只看文件系统，未分配区域完全不碰。
- 扫描期间保持供电稳定、温度正常，避免机器休眠（可配合 `systemd-inhibit`）。
- 坏块号是 `-b` 指定块大小的序号；换算 LBA 乘 `BLOCKSIZE / 512`。
