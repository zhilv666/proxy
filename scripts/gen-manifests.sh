#!/bin/bash
# 包管理器清单生成器: 按指定版本与校验和文件重新生成 Scoop/Homebrew 清单。
#
# 用法: gen-manifests.sh <tag> <SHA256SUMS 文件>
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?用法: gen-manifests.sh <tag> <sums-file>}"
SUMS="${2:?用法: gen-manifests.sh <tag> <sums-file>}"
VERSION="${TAG#v}"
REPO="zhilv666/proxy"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

hash_of() {
    # 兼容 "hash  file" 与 "hash *file" 两种 sha256sum 输出
    LC_ALL=C awk -v f="$1" '{ n=$2; sub(/^\*/, "", n); if (n == f) print $1 }' "$SUMS"
}

H_WIN="$(hash_of "proxy-${TAG}-x86_64-windows.zip")"
H_LINUX_X64="$(hash_of "proxy-${TAG}-x86_64-linux.tar.gz")"
H_LINUX_ARM="$(hash_of "proxy-${TAG}-aarch64-linux.tar.gz")"
H_MAC_X64="$(hash_of "proxy-${TAG}-x86_64-macos.tar.gz")"
H_MAC_ARM="$(hash_of "proxy-${TAG}-aarch64-macos.tar.gz")"

for v in H_WIN H_LINUX_X64 H_LINUX_ARM H_MAC_X64 H_MAC_ARM; do
    [ -n "${!v}" ] || { echo "错误: 校验和缺失 ($v)"; exit 1; }
done

mkdir -p pkg/scoop pkg/homebrew

# -- Scoop (Windows) ---------------------------------------------------------
cat > pkg/scoop/proxy.json <<EOF
{
    "version": "${VERSION}",
    "description": "跨平台代理命令行工具: 一条命令带代理执行，内置 TUI、多节点切换与连通性检测",
    "homepage": "https://github.com/${REPO}",
    "license": "MIT",
    "architecture": {
        "64bit": {
            "url": "${BASE}/proxy-${TAG}-x86_64-windows.zip",
            "hash": "${H_WIN}"
        }
    },
    "bin": "proxy.exe",
    "checkver": {
        "github": "https://github.com/${REPO}"
    },
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "https://github.com/${REPO}/releases/download/v\$version/proxy-v\$version-x86_64-windows.zip"
            }
        },
        "hash": {
            "url": "https://github.com/${REPO}/releases/download/v\$version/SHA256SUMS.txt"
        }
    }
}
EOF

# -- Homebrew (macOS/Linux) --------------------------------------------------
cat > pkg/homebrew/proxy.rb <<EOF
# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/${REPO}"
  version "${VERSION}"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "${BASE}/proxy-${TAG}-aarch64-macos.tar.gz"
      sha256 "${H_MAC_ARM}"
    else
      url "${BASE}/proxy-${TAG}-x86_64-macos.tar.gz"
      sha256 "${H_MAC_X64}"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "${BASE}/proxy-${TAG}-aarch64-linux.tar.gz"
      sha256 "${H_LINUX_ARM}"
    else
      url "${BASE}/proxy-${TAG}-x86_64-linux.tar.gz"
      sha256 "${H_LINUX_X64}"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
EOF

echo "已生成 pkg/scoop/proxy.json 与 pkg/homebrew/proxy.rb (${VERSION})"
