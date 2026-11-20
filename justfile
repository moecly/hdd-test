default:
    @just --list

# Enter the Nix development shell.
develop:
    nix develop

# Check the Nix flake.
check:
    nix flake check

# Update flake inputs.
update:
    nix flake update

# Show flake outputs.
show:
    nix flake show

# Format Nix files.
fmt:
    nix fmt

# 列出候选磁盘
disks:
    ./hdd-test.sh list

# 完整体检，不含破坏性写测试
scan DEV:
    ./hdd-test.sh all {{DEV}}

# 破坏性写测试，会清空全盘
wipe DEV:
    ./hdd-test.sh write {{DEV}} --yes

# 重新生成报告
report DIR="":
    ./hdd-test.sh report {{DIR}}

# 语法检查
lint:
    bash -n hdd-test.sh
