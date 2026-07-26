# proxy

[![Release](https://img.shields.io/github/v/release/zhilv666/proxy)](https://github.com/zhilv666/proxy/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Zig](https://img.shields.io/badge/zig-0.15.2-orange)

用 Zig 编写的跨平台代理命令行工具：一条命令带代理执行，内置全屏 TUI、命令别名和连通性检测。

```bash
proxy curl https://google.com     # 带代理执行任意命令
proxy tui                         # 全屏交互式配置界面
proxy status                      # 检测代理连通性与延迟
```

**核心特性**

- 🚀 零依赖单文件，Windows / Linux / macOS 全平台
- 🖥️ 全屏 TUI：方向键导航、行内编辑、宽屏双栏自适应布局
- 🔗 http / https / socks5 / socks4 四种代理协议
- 📡 内置 TCP / HTTP Ping：实时查看代理连通性和响应延迟
- 🏷️ 命令别名系统，支持平台特定别名与跨平台合并显示
- 🔐 认证代理支持（用户名密码自动 URL 编码）

## 安装

从 [Releases](https://github.com/zhilv666/proxy/releases) 下载对应平台的压缩包，解压后将 `proxy` 放入 `PATH` 即可。

<details>
<summary>从源码构建</summary>

需要 [Zig 0.15.2](https://ziglang.org/download/)：

```bash
git clone https://github.com/zhilv666/proxy.git
cd proxy

zig build                            # Debug
zig build -Doptimize=ReleaseFast     # Release (推荐)
zig build small                      # 体积最小化
zig build test                       # 运行单元测试
```

产物位于 `zig-out/bin/proxy`（Windows 为 `proxy.exe`）。非 Debug 构建自动 strip 调试信息，二进制约 250KB~500KB。

</details>

## 快速开始

```bash
# 1. 配置代理 (或直接 proxy tui 可视化配置)
proxy config set host 127.0.0.1
proxy config set port 7890

# 2. 检测代理是否可用
proxy status

# 3. 带代理执行命令
proxy curl https://google.com
proxy git clone https://github.com/user/repo.git

# 4. 配置别名，少敲几个字
proxy alias add all gs "git status"
proxy gs
```

## 使用文档

<details>
<summary><b>🖥️ TUI 交互界面</b> — <code>proxy tui</code></summary>

全屏交互式界面，宽屏（≥90 列）自动切换左右双栏布局，窗口缩放实时自适应：

```
 PROXY · 跨平台代理配置管理
 代理地址 http://127.0.0.1:7890

╭─ 配置 ──────────────────────╮ ╭─ 别名 1/3 ─────────────────────────────╮
│ ▸ Host       127.0.0.1(默认)│ │ ▸ [linux+macos]  gs    → git status    │
│   Port       7890 (默认)    │ │   [all]          ll    → ls -la        │
│   ...                       │ │   [windows]      打开  → explorer .    │
╰─────────────────────────────╯ ╰────────────────────────────────────────╯
```

| 按键 | 功能 |
|---|---|
| `↑↓` / `j k` | 移动光标 |
| `Tab` | 切换配置 / 别名面板 |
| `Enter` | 编辑所选项（配置行内编辑；别名编辑命令） |
| `a` | 添加别名（平台复选框可多选，空格勾选，一次保存到多个平台） |
| `d` → `y` | 删除所选别名（整组删除） |
| `r` | 重新加载配置 |
| `q` / `Esc` | 退出 |

- Protocol 为固定选项选择（`←→` 切换），其余字段自由输入，留空保存恢复默认
- 同名同命令的别名跨平台合并为一行显示，如 `[linux+macos] gs → git status`
- 勾选 all 或三个系统全选时，自动归并为一条 `all` 记录

</details>

<details>
<summary><b>📡 连通性检测</b> — <code>proxy status</code> / <code>proxy check</code></summary>

```bash
proxy status                          # 默认测试 gstatic generate_204
proxy check https://www.google.com    # 自定义测试地址
```

输出示例：

```
代理状态检测

  代理地址   http://127.0.0.1:7890
  测试地址   http://www.gstatic.com/generate_204

  TCP 连接   ✓ 3/3 成功   延迟 0.17 / 2.88 / 8.25 ms (min/avg/max)
  HTTP 请求  ✓ HTTP 204   耗时 1218 ms

  代理状态   ✓ 可用
```

- **TCP 连接**：3 轮连接代理端口测握手延迟，反映代理进程是否存活
- **HTTP 请求**：真实经代理转发一次请求，反映节点出口是否可用
  - http 代理：`http://` 地址直接 GET，`https://` 地址走 CONNECT 隧道，支持 Basic 认证
  - socks5 / socks4(a) 代理：标准握手 + CONNECT
  - https 代理（与代理本身建 TLS）暂不支持转发检测，仅做 TCP 测试
- 读写超时 5 秒，代理挂起不会卡死

</details>

<details>
<summary><b>⚙️ 配置管理</b> — <code>proxy config</code></summary>

```bash
proxy config set <key> <value>    # 设置
proxy config get <key>            # 查看单项
proxy config list                 # 查看全部
```

| 配置项 | 说明 | 默认值 |
|---|---|---|
| `host` | 代理服务器地址 | `127.0.0.1` |
| `port` | 代理服务器端口 | `7890` |
| `protocol` | 代理协议 `http` / `https` / `socks5` / `socks4` | `http` |
| `username` | 用户名（可选，别名 `user`） | 未设置 |
| `password` | 密码（可选，别名 `pass`） | 未设置 |

```bash
proxy config set host 192.168.1.1
proxy config set protocol socks5
proxy config set username myuser
proxy config set password 'p@ss:word'    # 特殊字符自动 URL 编码
```

</details>

<details>
<summary><b>🏷️ 别名管理</b> — <code>proxy alias</code></summary>

```bash
proxy alias add <platform> <name> <command>   # 添加
proxy alias remove <platform> <name>          # 删除
proxy alias list                              # 列出
```

平台取值：`all`（所有平台）、`windows`、`linux`、`macos`。执行时优先匹配当前平台的别名，找不到再回退到 `all`。

```bash
proxy alias add all gs "git status"
proxy alias add linux update "sudo apt update"
proxy alias add windows open "explorer ."
proxy alias add macos open "open ."       # 同名别名可按平台给不同命令

proxy gs          # → git status (带代理环境)
proxy open        # Windows 上 → explorer . ; macOS 上 → open .
proxy gs --short  # 追加参数原样传递 → git status --short
```

</details>

<details>
<summary><b>🚀 代理执行与环境变量</b></summary>

`proxy <command>` 会为子进程注入以下环境变量后执行：

```
http_proxy / HTTP_PROXY
https_proxy / HTTPS_PROXY
all_proxy / ALL_PROXY
```

值形如 `http://127.0.0.1:7890`，配置了认证则为 `http://user:pass@host:port`（自动 URL 编码）。

```bash
proxy curl https://google.com
proxy git clone https://github.com/user/repo.git
proxy npm install
proxy pip install requests
proxy cargo build

# 验证环境变量
proxy sh -c 'env | grep -i proxy'
```

</details>

<details>
<summary><b>📁 配置文件</b></summary>

默认目录 `~/.proxy/`，可通过 `PROXY_HOME` 环境变量自定义。

`config.json`：

```json
{
  "host": "127.0.0.1",
  "port": "7890",
  "protocol": "http",
  "username": "",
  "password": ""
}
```

`aliases.json`（按平台分组）：

```json
{
  "all":     { "gs": "git status" },
  "windows": { "open": "explorer ." },
  "macos":   { "open": "open ." }
}
```

首次 `config set` / `alias add` 时自动创建。

</details>

<details>
<summary><b>🔖 版本信息</b> — <code>proxy -v</code></summary>

```
proxy version 1.2.0

提交哈希: 9bccdac
构建时间: 2026-07-26 11:22 UTC
Zig 版本: 0.15.2
目标平台: x86_64-windows (ReleaseFast)
```

版本号构建时从 `git describe` 自动获取，也可用 `zig build -Dversion=x.y.z` 手动指定。

</details>

<details>
<summary><b>🔧 故障排查</b></summary>

**代理连接失败**（`curl: (7) Failed to connect`）

```bash
proxy status              # 先看 TCP 连接是否成功
proxy config list         # 确认 host/port 配置
```

TCP 失败 → 代理进程没跑或端口不对；TCP 成功但 HTTP 失败 → 节点出口异常或协议选错（如 socks 端口配了 http 协议）。

**HTTP 407** — 代理要求认证，检查 `username` / `password` 配置。

**别名不生效**

```bash
proxy alias list          # 确认别名存在且平台匹配当前系统 (或 all)
```

**TUI 无法启动** — TUI 需要交互式终端，输入/输出被重定向时会直接报错退出。

</details>

<details>
<summary><b>🛠️ 开发</b></summary>

**项目结构**

```
├── src/
│   ├── main.zig        # 入口与命令分发
│   ├── config.zig      # 配置管理 (JSON 持久化)
│   ├── alias.zig       # 别名管理
│   ├── tui.zig         # 全屏 TUI
│   ├── term.zig        # 跨平台终端层 (原始模式/按键解析/CJK 宽度)
│   ├── check.zig       # 连通性检测 (TCP/HTTP/SOCKS)
│   └── output.zig      # Windows UTF-8 输出
├── examples/           # TUI 演示 (zig build demo)
├── scripts/            # 测试与 CHANGELOG 生成脚本
└── .github/workflows/  # 推 tag 自动发布
```

**常用命令**

```bash
zig build test                                   # 单元测试
zig build -Dtarget=x86_64-linux                  # 交叉编译
bash scripts/test.sh                             # 功能测试
bash scripts/gen-changelog.sh v1.2.0 --notes-only  # 预览更新日志
```

**发布流程**：提交代码 → `git tag v1.x.y` → `git push origin main --tags`，GitHub Actions 自动生成 CHANGELOG 回写主分支、交叉编译五个平台并创建 Release。

</details>

## 许可证

[MIT](LICENSE)
