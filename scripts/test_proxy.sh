#!/bin/bash
cd "$(dirname "$0")/.."

echo "=== 测试代理工具 ==="
echo

echo "1. 测试配置管理"
./zig-out/bin/proxy config set host 192.168.1.1
./zig-out/bin/proxy config set port 8080
./zig-out/bin/proxy config list
echo

echo "2. 测试别名管理"
./zig-out/bin/proxy alias add windows ll "ls -l"
./zig-out/bin/proxy alias add linux ll "ls -lh"
./zig-out/bin/proxy alias add all gs "git status"
./zig-out/bin/proxy alias list
echo

echo "3. 测试别名执行"
./zig-out/bin/proxy ll | head -5
echo

echo "4. 测试删除别名"
./zig-out/bin/proxy alias remove linux ll
./zig-out/bin/proxy alias list
echo

echo "5. 测试帮助信息"
./zig-out/bin/proxy --help
echo

echo "=== 所有测试完成 ==="
