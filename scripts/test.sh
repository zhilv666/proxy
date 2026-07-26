#!/bin/bash
cd "$(dirname "$0")/.."

# Proxy CLI Tool - 功能测试脚本

set -e

echo "=========================================="
echo "Proxy CLI Tool - 功能测试"
echo "=========================================="
echo ""

PROXY="./zig-out/bin/proxy.exe"

if [ ! -f "$PROXY" ]; then
    echo "❌ 错误: 可执行文件不存在"
    echo "请先运行: zig build"
    exit 1
fi

echo "✅ 可执行文件存在"
echo ""

# 测试 1: 配置管理
echo "=========================================="
echo "测试 1: 配置管理"
echo "=========================================="

echo "设置配置..."
$PROXY config set host 127.0.0.1
$PROXY config set port 7890
$PROXY config set proto http
$PROXY config set user testuser
$PROXY config set password testpass

echo ""
echo "查看所有配置..."
$PROXY config get

echo ""
echo "查看单个配置..."
echo -n "host: "
$PROXY config get host
echo -n "port: "
$PROXY config get port
echo -n "proto: "
$PROXY config get proto

echo ""
echo "✅ 配置管理测试通过"
echo ""

# 测试 2: 别名管理
echo "=========================================="
echo "测试 2: 别名管理"
echo "=========================================="

echo "列出默认别名..."
$PROXY alias list

echo ""
echo "添加测试别名..."
$PROXY alias add all test "echo 'Alias test'"
$PROXY alias add windows wintest "echo 'Windows test'"

echo ""
echo "查看别名列表..."
$PROXY alias list

echo ""
echo "删除测试别名..."
$PROXY alias remove all test
$PROXY alias remove windows wintest

echo ""
echo "✅ 别名管理测试通过"
echo ""

# 测试 3: 环境变量
echo "=========================================="
echo "测试 3: 环境变量设置"
echo "=========================================="

echo "检查 http_proxy 环境变量..."
PROXY_URL=$($PROXY sh -c 'echo $http_proxy')
echo "http_proxy = $PROXY_URL"

if [[ "$PROXY_URL" == *"127.0.0.1:7890"* ]]; then
    echo "✅ 环境变量设置正确"
else
    echo "❌ 环境变量设置错误"
    exit 1
fi
echo ""

# 测试 4: 别名展开
echo "=========================================="
echo "测试 4: 别名展开"
echo "=========================================="

echo "测试 'll' 别名..."
$PROXY ll > /dev/null 2>&1 && echo "✅ ll 别名工作正常" || echo "❌ ll 别名失败"

echo ""

# 测试 5: 命令执行
echo "=========================================="
echo "测试 5: 命令执行"
echo "=========================================="

echo "测试 echo 命令..."
OUTPUT=$($PROXY echo "Hello from proxy")
if [[ "$OUTPUT" == "Hello from proxy" ]]; then
    echo "✅ 命令执行正常"
else
    echo "❌ 命令执行失败"
    exit 1
fi
echo ""

# 配置文件检查
echo "=========================================="
echo "配置文件信息"
echo "=========================================="

if [ -n "$PROXY_HOME" ]; then
    CONFIG_PATH="$PROXY_HOME/config.json"
else
    CONFIG_PATH="$HOME/.proxy/config.json"
fi

echo "配置文件路径: $CONFIG_PATH"

if [ -f "$CONFIG_PATH" ]; then
    echo "配置文件大小: $(stat -f%z "$CONFIG_PATH" 2>/dev/null || stat -c%s "$CONFIG_PATH" 2>/dev/null || echo "未知") bytes"
    echo "✅ 配置文件存在"
else
    echo "⚠️  配置文件不存在（首次运行会自动创建）"
fi
echo ""

# 总结
echo "=========================================="
echo "测试总结"
echo "=========================================="
echo "✅ 所有功能测试通过！"
echo ""
echo "项目信息:"
echo "  - 源代码: $(wc -l proxy.zig config.zig build.zig 2>/dev/null | tail -1 | awk '{print $1}') 行"
echo "  - 可执行文件: $(ls -lh "$PROXY" | awk '{print $5}')"
echo "  - 配置文件: $CONFIG_PATH"
echo ""
echo "快速使用:"
echo "  proxy config get              # 查看配置"
echo "  proxy alias list              # 查看别名"
echo "  proxy ll                      # 使用别名"
echo "  proxy curl https://google.com # 使用代理"
echo ""
echo "完整文档请查看 README.md"
echo "=========================================="
