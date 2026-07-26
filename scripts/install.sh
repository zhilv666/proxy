#!/bin/bash
# proxy 一键安装脚本 (Linux / macOS)
#   curl -fsSL https://raw.githubusercontent.com/zhilv666/proxy/main/scripts/install.sh | bash
# 自定义安装目录: PROXY_INSTALL_DIR=~/.local/bin bash install.sh
set -euo pipefail

REPO="zhilv666/proxy"

case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) echo "不支持的系统: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    arm64 | aarch64) arch="aarch64" ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

echo "获取最新版本..."
TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"
[ -n "$TAG" ] || { echo "错误: 无法获取最新版本"; exit 1; }

URL="https://github.com/${REPO}/releases/download/${TAG}/proxy-${TAG}-${arch}-${os}.tar.gz"
DIR="${PROXY_INSTALL_DIR:-/usr/local/bin}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "下载 ${URL}"
curl -fsSL "$URL" -o "$tmp/proxy.tar.gz"
tar -xzf "$tmp/proxy.tar.gz" -C "$tmp"

mkdir -p "$DIR" 2>/dev/null || true
if [ -w "$DIR" ]; then
    install -m 755 "$tmp/proxy" "$DIR/proxy"
else
    echo "写入 $DIR 需要 sudo:"
    sudo install -m 755 "$tmp/proxy" "$DIR/proxy"
fi

echo "✓ proxy ${TAG} 已安装到 ${DIR}/proxy"
"$DIR/proxy" -v || true
