#!/bin/bash
# 更新日志生成器
#
# 用法:
#   gen-changelog.sh <tag>               生成 <tag> 的日志段落并插入 CHANGELOG.md
#   gen-changelog.sh <tag> --notes-only  只把段落输出到 stdout (用作 Release Notes)
#
# 段落内容取自上一个 tag 到 <tag> 之间的提交记录，按提交前缀简单归类。
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?用法: gen-changelog.sh <tag> [--notes-only]}"
MODE="${2:-}"

VERSION="${TAG#v}"
PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
RANGE="${PREV:+${PREV}..}${TAG}"
DATE="$(git log -1 --format=%ad --date=short "${TAG}")"

# 按前缀归类提交 (feat/fix/docs/其他)，兼容 "✨ feat(...)" 这类 emoji 前缀。
# LC_ALL=C 让 grep 按字节匹配，四字节 emoji 在部分环境的 UTF-8 字符类下会匹配失败。
subjects() {
    # 排除 CI 自身的更新日志回写提交
    git log --no-merges --pretty='%s (%h)' "${RANGE}" | LC_ALL=C grep -Ev '^docs: 更新 v[0-9.]+ 更新日志' || true
}

collect() {
    local pattern="$1"
    subjects | LC_ALL=C grep -E "^([^ ]+ )?${pattern}" | sed 's/^/- /' || true
}

FEAT="$(collect 'feat')"
FIX="$(collect '(fix|bugfix|hotfix)')"
DOCS="$(collect '(docs|doc)')"
OTHER="$(subjects | LC_ALL=C grep -Ev '^([^ ]+ )?(feat|fix|bugfix|hotfix|docs|doc)' | sed 's/^/- /' || true)"

NOTES="## [${VERSION}] - ${DATE}"
append_section() {
    local title="$1" body="$2"
    [ -n "$body" ] && NOTES="${NOTES}

### ${title}
${body}"
    return 0
}
append_section "新增" "$FEAT"
append_section "修复" "$FIX"
append_section "文档" "$DOCS"
append_section "其他" "$OTHER"

if [ "$MODE" = "--notes-only" ]; then
    printf '%s\n' "$NOTES"
    exit 0
fi

# 已记录过该版本 (含手写条目) 则跳过，避免重复
if [ -f CHANGELOG.md ] && grep -qF "## [${VERSION}]" CHANGELOG.md; then
    echo "CHANGELOG.md 已包含 ${VERSION}，跳过"
    exit 0
fi

[ -f CHANGELOG.md ] || printf '# Changelog\n' > CHANGELOG.md

# 插入到 "# Changelog" 标题之后，保持最新版本在最上面
{
    head -n 1 CHANGELOG.md
    echo ""
    printf '%s\n' "$NOTES"
    tail -n +2 CHANGELOG.md
} > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md
echo "已写入 CHANGELOG.md: ${VERSION}"
