# Proxy CLI Tool

一个用 Zig 编写的跨平台代理工具，支持命令别名和配置管理。

## 功能特性

- ✅ 跨平台支持 (Windows/Linux/macOS)
- ✅ 配置管理 (host/port/protocol/user/password)
- ✅ 命令别名系统 (支持平台特定别名)
- ✅ 环境变量配置 (PROXY_HOME)
- ✅ 自动检测并展开别名
- ✅ 支持认证代理 (URL 编码)
- ✅ 零依赖，纯 Zig 实现

## 编译

```bash
# Debug 模式
zig build

# Release 模式 (推荐)
zig build -Doptimize=ReleaseFast

# 其他优化选项
zig build -Doptimize=ReleaseSafe    # 带安全检查的优化
zig build -Doptimize=ReleaseSmall   # 体积最小化
```

编译后的可执行文件位于 `zig-out/bin/proxy` (或 `proxy.exe` on Windows)

## 快速开始

```bash
# 1. 设置代理配置
proxy config set host 127.0.0.1
proxy config set port 7890
proxy config set proto http

# 2. 使用代理执行命令
proxy curl https://google.com

# 3. 使用内置别名
proxy ll    # 等同于 ls -l
proxy la    # 等同于 ls -la
```

## 使用方法

### 1. 配置管理

```bash
# 查看所有配置
proxy config get

# 输出:
# 代理配置:
#   host: 127.0.0.1
#   port: 7890
#   proto: http
#   user: myuser
#   password: ******

# 查看单个配置项
proxy config get host       # 输出: 127.0.0.1
proxy config get port       # 输出: 7890
proxy config get proto      # 输出: http

# 设置配置项
proxy config set host 127.0.0.1
proxy config set port 7890
proxy config set proto http           # http 或 https
proxy config set user myuser
proxy config set password mypass
```

**支持的配置项:**
- `host` - 代理服务器地址
- `port` - 代理服务器端口
- `proto` - 协议 (http/https)
- `user` - 用户名 (可选)
- `password` - 密码 (可选)

### 2. 别名管理

```bash
# 列出所有别名
proxy alias list

# 输出示例:
# 已配置的别名:
#   ll         -> ls -l                          (all)
#   la         -> ls -la                         (all)
#   l          -> ls -lah                        (all)

# 添加别名
proxy alias add <platform> <name> <command>

# 示例:
proxy alias add all ll "ls -l"              # 所有平台
proxy alias add windows dir "dir /w"        # 仅 Windows
proxy alias add linux la "ls -la"           # 仅 Linux
proxy alias add macos l "ls -lah"           # 仅 macOS

# 删除别名
proxy alias remove <platform> <name>

# 示例:
proxy alias remove all ll
proxy alias remove windows dir
```

**支持的平台:**
- `all` - 所有平台
- `windows` - Windows 系统
- `linux` - Linux 系统
- `macos` - macOS 系统

### 3. 使用代理执行命令

```bash
# 方式 1: 使用别名 (推荐)
proxy ll                    # 自动展开为 ls -l
proxy la                    # 自动展开为 ls -la

# 方式 2: 执行任意命令
proxy curl https://google.com
proxy wget https://example.com
proxy git clone https://github.com/user/repo
proxy npm install
proxy pip install requests

# 方式 3: 在子 shell 中执行
proxy sh -c 'echo $http_proxy'
# 输出: http://127.0.0.1:7890
```

**工作原理:**
1. 检查第一个参数是否是已配置的别名
2. 如果是别名，自动展开为完整命令
3. 设置代理环境变量后执行命令

## 配置文件

### 配置目录

默认配置目录: `~/.proxy/`

自定义配置目录:

```bash
# Linux/macOS
export PROXY_HOME=/path/to/config

# Windows (CMD)
set PROXY_HOME=C:\path\to\config

# Windows (PowerShell)
$env:PROXY_HOME="C:\path\to\config"
```

### 配置文件格式

位置: `$PROXY_HOME/config.json` 或 `~/.proxy/config.json`

```json
{
  "proxy": {
    "host": "127.0.0.1",
    "port": 7890,
    "proto": "http",
    "user": "myuser",
    "pass": "mypass"
  },
  "aliases": [
    {
      "name": "ll",
      "command": "ls -l",
      "platform": "all"
    },
    {
      "name": "la",
      "command": "ls -la",
      "platform": "all"
    },
    {
      "name": "dir",
      "command": "dir /w",
      "platform": "windows"
    }
  ]
}
```

### 初始化配置

首次运行 `proxy config set` 或 `proxy alias add` 时会自动创建配置文件。

默认包含以下别名:
- `ll` → `ls -l` (所有平台)
- `la` → `ls -la` (所有平台)
- `l` → `ls -lah` (所有平台)

## 环境变量

执行命令时，自动设置以下环境变量:

```bash
http_proxy=http://user:pass@host:port
https_proxy=http://user:pass@host:port
HTTP_PROXY=http://user:pass@host:port
HTTPS_PROXY=http://user:pass@host:port
ALL_PROXY=http://user:pass@host:port
all_proxy=http://user:pass@host:port
```

**认证支持:**
- 用户名和密码会自动进行 URL 编码
- 支持特殊字符 (如 `@`, `:`, `#` 等)

**验证环境变量:**

```bash
proxy sh -c 'env | grep -i proxy'
```

## 高级用法

### 临时使用不同代理

```bash
# 修改配置
proxy config set host 192.168.1.1
proxy config set port 8080

# 使用新配置
proxy curl https://google.com

# 恢复原配置
proxy config set host 127.0.0.1
proxy config set port 7890
```

### 平台特定别名

```bash
# 在 Windows 上
proxy alias add windows cmd "cmd.exe /c"
proxy cmd dir

# 在 Linux 上
proxy alias add linux update "apt update && apt upgrade -y"
proxy update

# 在 macOS 上
proxy alias add macos brew "brew update && brew upgrade"
proxy brew
```

### 与其他工具集成

```bash
# Git
proxy git clone https://github.com/user/repo.git

# Node.js/NPM
proxy npm install express

# Python/Pip
proxy pip install requests

# Go
proxy go get github.com/user/package

# Cargo
proxy cargo install ripgrep
```

## 故障排查

### 1. 配置文件不存在

**症状:** 运行命令时提示找不到配置文件

**解决方法:**
```bash
# 初始化配置
proxy config set host 127.0.0.1
proxy config set port 7890
```

### 2. 代理连接失败

**症状:** `curl: (7) Failed to connect`

**检查清单:**
- 代理服务器是否运行: `netstat -an | grep 7890`
- 配置是否正确: `proxy config get`
- 防火墙是否阻止

### 3. 别名不生效

**症状:** 别名未被识别

**解决方法:**
```bash
# 检查别名配置
proxy alias list

# 确保平台匹配
# 如果在 Windows 上，确保别名平台是 "all" 或 "windows"
```

### 4. 环境变量未设置

**症状:** `$http_proxy` 为空

**验证:**
```bash
proxy sh -c 'echo $http_proxy'
```

应该输出类似: `http://127.0.0.1:7890`

## 与 Bash 脚本对比

原 Bash 脚本功能:
```bash
proxy_on    # 启用代理环境变量
proxy_off   # 禁用代理环境变量
proxy cmd   # 使用代理执行命令
```

新 Zig 工具优势:
- ✅ 跨平台 (不依赖 Bash)
- ✅ 持久化配置 (无需每次重新设置)
- ✅ 别名系统 (平台特定支持)
- ✅ 更快的启动速度
- ✅ 内存安全 (无内存泄漏)
- ✅ 单个可执行文件

## 开发

### 技术栈
- 语言: Zig 0.15.1
- 标准库: std
- JSON 解析: std.json
- 进程管理: std.process
- 文件系统: std.fs

### 项目结构
```
.
├── build.zig          # 构建配置
├── proxy.zig          # 主程序
├── config.zig         # 配置管理模块
└── README.md          # 文档
```

### 测试

```bash
# 编译
zig build

# 测试配置管理
./zig-out/bin/proxy config get
./zig-out/bin/proxy config set host 127.0.0.1

# 测试别名
./zig-out/bin/proxy alias list
./zig-out/bin/proxy alias add all test "echo test"
./zig-out/bin/proxy test

# 测试代理执行
./zig-out/bin/proxy curl ifconfig.me
./zig-out/bin/proxy ll
```

## 许可证

MIT License - 自由使用、修改和分发

## 贡献

欢迎提交 Issue 和 Pull Request！

## 致谢

基于原 Bash 脚本重写，使用现代系统编程语言 Zig 实现。
