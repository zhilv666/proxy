#!/bin/bash
# 把 pkg/homebrew/proxy.rb 同步到 zhilv666/homebrew-tap 仓库。
# 需要环境变量 TAP_TOKEN (对 tap 仓库有 Contents 写权限的 PAT)。
# 用法: sync-tap.sh [版本标识 (仅用于提交信息)]
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:-manual}"
TAP_REPO="zhilv666/homebrew-tap"

if [ -z "${TAP_TOKEN:-}" ]; then
    echo "未配置 TAP_TOKEN，跳过 tap 同步"
    exit 0
fi

[ -f pkg/homebrew/proxy.rb ] || { echo "错误: pkg/homebrew/proxy.rb 不存在"; exit 1; }

# 公开仓库匿名 clone，把认证隔离到 push，便于定位失败阶段
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! git clone --depth 1 "https://github.com/${TAP_REPO}.git" "$tmp/tap"; then
    echo "错误: clone ${TAP_REPO} 失败 (仓库不存在或不可读)"
    exit 1
fi

mkdir -p "$tmp/tap/Formula"
cp pkg/homebrew/proxy.rb "$tmp/tap/Formula/proxy.rb"
cd "$tmp/tap"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Formula/proxy.rb
if git diff --cached --quiet; then
    echo "Formula 无变化，跳过"
    exit 0
fi

git commit -m "proxy ${LABEL}"
if ! git push "https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git" HEAD; then
    echo "错误: push 失败 —— 请检查 TAP_TOKEN 是否有效、是否对 ${TAP_REPO} 授予 Contents 读写权限"
    exit 1
fi
echo "✓ Formula 已同步到 ${TAP_REPO}"
