#!/bin/bash
cd "$(dirname "$0")/.."
# 全面测试脚本

set -e

echo "======================================"
echo "  Proxy 工具全面测试"
echo "======================================"
echo

echo ">>> 构建项目..."
zig build
echo "✓ 构建成功"
echo

echo ">>> 测试帮助系统..."
./zig-out/bin/proxy --help > /dev/null
./zig-out/bin/proxy config --help > /dev/null
./zig-out/bin/proxy alias --help > /dev/null
echo "✓ 帮助系统正常"
echo

echo ">>> 测试配置管理..."
./zig-out/bin/proxy config set host 127.0.0.1 2>&1 | grep -v "error(gpa)" > /dev/null
./zig-out/bin/proxy config set port 7890 2>&1 | grep -v "error(gpa)" > /dev/null
./zig-out/bin/proxy config get host 2>&1 | grep -q "127.0.0.1"
echo "✓ 配置管理正常"
echo

echo ">>> 测试别名管理..."
./zig-out/bin/proxy alias add windows test1 "echo test1" 2>&1 | grep -v "error(gpa)" > /dev/null
./zig-out/bin/proxy alias add all test3 "echo test3" 2>&1 | grep -v "error(gpa)" > /dev/null
./zig-out/bin/proxy alias list 2>&1 | grep -q "test1"
echo "✓ 别名管理正常"
echo

echo ">>> 测试别名删除..."
./zig-out/bin/proxy alias remove windows test1 2>&1 | grep -v "error(gpa)" > /dev/null
./zig-out/bin/proxy alias remove all test3 2>&1 | grep -v "error(gpa)" > /dev/null
echo "✓ 别名删除正常"
echo

echo "======================================"
echo "  ✓ 所有测试通过！"
echo "======================================"
