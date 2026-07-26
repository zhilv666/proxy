# Proxy - 跨平台代理工具

一个使用 Zig 编写的跨平台命令行代理工具，支持配置管理、命令别名和 TUI 界面。

## 特性

- ✅ 跨平台支持 (Windows, Linux, macOS)
- ✅ 代理配置管理
- ✅ 命令别名系统
- ✅ TUI 交互界面
- ✅ 层级式帮助文档
- ✅ 自动别名展开

## 编译

```bash
# 开发版本
zig build

# 发布版本（优化）
zig build -Doptimize=ReleaseFast

# 小体积版本
zig build -Doptimize=ReleaseSmall
```

## 使用方法

### 基本命令

```bash
# 显示帮助
proxy --help

# 显示版本
proxy --version

# 使用代理执行命令
proxy curl https://google.com
```

### 配置管理

```bash
# 设置代理配置
proxy config set host 127.0.0.1
proxy config set port 7890
proxy config set protocol http
proxy config set username myuser
proxy config set password mypass

# 查看配置
proxy config get host
proxy config list

# 显示配置帮助
proxy config --help
```

### 别名管理

```bash
# 添加平台特定别名
proxy alias add windows ll "ls -l"
proxy alias add linux ll "ls -lh"
proxy alias add macos ll "ls -lG"

# 添加跨平台别名
proxy alias add all gs "git status"
proxy alias add all gp "git pull"

# 列出所有别名
proxy alias list

# 删除别名
proxy alias remove windows ll

# 显示别名帮助
proxy alias --help
```

### 使用别名

```bash
# 别名会自动展开并使用代理执行
proxy ll
# 等价于: proxy ls -l (在 Windows 上)

proxy gs
# 等价于: proxy git status (所有平台)
```

### TUI 界面

```bash
# 启动交互式 TUI 界面
proxy tui
```

在 TUI 界面中：
- 使用 ↑↓ 键选择菜单项
- 按 Enter 确认选择
- 按 q 退出

## 配置文件位置

配置文件存储在：
- **Linux/macOS**: `~/.proxy/`
- **Windows**: `%USERPROFILE%/.proxy/`

包含以下文件：
- `config.json` - 代理配置
- `aliases.json` - 命令别名

## 示例配置文件

### config.json
```json
{
  "host": "127.0.0.1",
  "port": 7890,
  "protocol": "http",
  "username": "",
  "password": ""
}
```

### aliases.json
```json
{
  "windows": {
    "ll": "ls -l"
  },
  "linux": {
    "ll": "ls -lh"
  },
  "macos": {
    "ll": "ls -lG"
  },
  "all": {
    "gs": "git status",
    "gp": "git pull"
  }
}
```

## 工作原理

1. **代理设置**: 工具会设置以下环境变量：
   - `http_proxy`
   - `https_proxy`
   - `HTTP_PROXY`
   - `HTTPS_PROXY`
   - `ALL_PROXY`
   - `all_proxy`

2. **别名展开**: 
   - 当执行命令时，工具首先检查是否有匹配的别名
   - 支持平台特定别名和跨平台别名（`all`）
   - 别名优先级：当前平台 > all

3. **命令执行**: 
   - 设置代理环境变量
   - 执行目标命令
   - 继承父进程的输入输出

## 开发

项目结构：
```
.
├── build.zig          # 构建配置
├── proxy.zig          # 主程序入口
├── src/
│   ├── config.zig     # 配置管理模块
│   ├── alias.zig      # 别名管理模块
│   └── tui.zig        # TUI 界面模块
└── zig-out/bin/       # 编译输出
```

## 许可证

MIT License
