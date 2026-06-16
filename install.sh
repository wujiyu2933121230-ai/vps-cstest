#!/bin/bash
set -euo pipefail

# ── 配置 ──
REPO="wujiyu2933121230-ai/vps-cstest"
BRANCH="main"
SUBDIR="vps-init"
INSTALL_DIR="/opt/vps-init"
CMD_LINK="/usr/local/bin/vps"

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 前置检查 ──
if [[ $EUID -ne 0 ]]; then log_error "请使用 root 身份运行"; exit 1; fi
if [[ ! -f /etc/debian_version ]]; then log_error "仅支持 Debian/Ubuntu 系统"; exit 1; fi
for cmd in curl tar; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "缺少 $cmd，请先安装: apt install -y $cmd"; exit 1
    fi
done

# ── 清理 ──
TMP=$(mktemp -d) || { log_error "创建临时目录失败"; exit 1; }
trap "rm -rf $TMP" EXIT INT TERM

# ── 下载 ──
log_info "正在下载 vps-init..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$BRANCH" -o "$TMP/repo.tar.gz"

# ── 解压 ──
log_info "正在解压..."
tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
SRC="$TMP/vps-cstest-$BRANCH/$SUBDIR"

# ── 校验 ──
required_files=(vps-init.sh lib.sh system.sh ssh.sh ufw.sh anytls.sh hy2.sh)
for f in "${required_files[@]}"; do
    if [[ ! -f "$SRC/$f" ]]; then
        log_error "文件缺失: $f，下载可能不完整"; exit 1
    fi
done

# ── 安装 ──
log_info "安装到 $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR"
cp -a "$SRC" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/vps-init.sh"

# ── 创建快捷命令 ──
ln -sf "$INSTALL_DIR/vps-init.sh" "$CMD_LINK"
log_info "快捷命令已创建: $CMD_LINK"

echo ""
log_info "安装完成！"
echo ""
echo "  运行方式: sudo vps"
echo ""

# ── 运行 ──
exec bash "$INSTALL_DIR/vps-init.sh"
