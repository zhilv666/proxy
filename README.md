# proxy

[![Release](https://img.shields.io/github/v/release/zhilv666/proxy)](https://github.com/zhilv666/proxy/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Zig](https://img.shields.io/badge/zig-0.15.2-orange)

用 Zig 编写的跨平台代理命令行工具：一条命令带代理执行，内置命令别名和连通性检测。

```bash
proxy curl https://google.com     # 带代理执行任意命令
proxy 2 curl https://google.com   # 用 2 号节点跑这一条，不改当前配置
proxy on                          # 进入代理子 shell: 里面的命令都走代理,exit 返回
proxy status                      # 检测代理连通性与延迟
proxy serve                       # 在浏览器中管理代理节点和命令别名
```

**核心特性**

- 🚀 零依赖单文件，Windows / Linux / macOS 全平台
- 🔗 http / https / socks5 / socks4 四种代理协议
- 🔀 多代理节点：`proxy switch dev` 在公司内网 / 本地开发 / 海外节点间一键切换
- 🔢 按序号临时指定节点：`proxy 2 curl https://google.com` 只这一条走 2 号节点，不改当前配置
- 🐚 代理子 shell:`proxy on` 进入一个命令都自动走代理的 shell,`exit` 返回原环境,历史命令互通
- 📡 内置 TCP / HTTP Ping：实时查看代理连通性和响应延迟
- 🏷️ 命令别名系统，支持平台特定别名与跨平台合并显示
- 🌐 内嵌网页管理：代理配置、节点和别名的增删查改，支持拖动排序、搜索与平台筛选
- 🔐 认证代理支持（用户名密码自动 URL 编码）

## 安装

**Scoop (Windows)**

```powershell
scoop bucket add proxy https://github.com/zhilv666/proxy
scoop install proxy
```

**Homebrew (macOS / Linux)**

```bash
brew tap zhilv666/tap
brew install proxy
```

**一键脚本**

```bash
# Linux / macOS
curl -fsSL https://zhilv666.github.io/proxy/install.sh | bash

# Windows (PowerShell)
irm https://zhilv666.github.io/proxy/install.ps1 | iex
```

**手动下载**

从 [Releases](https://github.com/zhilv666/proxy/releases) 下载对应平台的压缩包（附 `SHA256SUMS.txt` 校验），解压后将 `proxy` 放入 `PATH` 即可。

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

产物位于 `zig-out/bin/proxy`（Windows 为 `proxy.exe`）。非 Debug 构建自动 strip 调试信息，网页资源内嵌于二进制，无需单独分发。

</details>

## 快速开始

```bash
# 1. 配置代理
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
<summary><b>🌐 网页管理</b> — <code>proxy serve</code></summary>

```bash
proxy serve                 # 打开浏览器访问 http://127.0.0.1:8080/
proxy serve --port 9090      # 自定义网页端口
proxy serve --help
```

启动后输出访问地址，按 `Ctrl+C` 停止。服务仅监听本机 `127.0.0.1`，无需安装 Node.js 或其他运行时。

- **当前代理**：查看和编辑协议、主机、端口及认证信息；支持恢复默认和另存为节点。
- **代理节点**：新增、查询、编辑、重命名、删除、启用、解除关联；可按名称、地址或协议搜索。
- **命令别名**：新增、查询、编辑、删除；支持修改名称和所属平台，按名称、命令搜索及平台筛选。
- **拖动排序**：拖动节点或别名左侧的手柄，松开后自动保存；支持触屏和键盘方向键。节点顺序同步到 CLI 序号，搜索或筛选下排序会保留隐藏条目的位置。
- **配置同步**：与 CLI 共用 `~/.proxy/` 或 `PROXY_HOME`；编辑当前配置会同步到关联节点，编辑激活节点也会同步当前配置。
- **保存行为**：新建节点不会自动切换；删除激活节点会保留当前代理参数并解除关联；恢复默认保留节点和别名。

详细用法、接口和验证方式见 [网页管理说明](docs/SERVE.md)。

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
<summary><b>🔀 多节点切换</b> — <code>proxy switch</code> / <code>proxy node</code></summary>

把多套代理配置保存为命名节点，随时一键切换：

```bash
# 保存节点: 先配置好，再存名字 (同名覆盖)
proxy config set host 127.0.0.1
proxy config set port 7890
proxy node save dev                # 本地开发代理

# 存完就"激活"在 dev 上了，此时改配置会写回 dev
# 要另起一个配置不同的节点，先脱离
proxy node unlink
proxy config set host 10.1.0.8
proxy config set port 8080
proxy node save company            # 公司内网代理

# 一键切换
proxy switch dev
# ✓ 已切换到节点 dev: http://127.0.0.1:7890

# 管理
proxy node list                    # 列出节点，▸ 标记当前
proxy node remove company          # 删除节点
```

```
节点列表:

   1 ▸ dev         http://127.0.0.1:7890   ← 当前
   2   company     http://10.1.0.8:8080
   3   hk          socks5://1.2.3.4:1080
```

**按序号指定节点** — 不想先切再用，直接把序号写在命令前面：

```bash
proxy 3 curl https://google.com    # 只这一条走 hk，当前节点仍是 dev
proxy 3 npm install
proxy 3 status                     # 临时检测 hk 的连通性
proxy 3                            # 不带命令 = 切换到 hk (等同 proxy switch 3)
```

序号即 `proxy node list` 的行号（1 起始），凡是要写节点名的地方都能用：

```bash
proxy switch 2
proxy node rename 2 office
proxy node remove 2
```

- `proxy <序号> <命令>` 只影响这一次执行，**不写配置文件**，当前节点原样不动
- 节点名优先于序号：真有节点叫 `1` 时，`proxy 1` 命中的是它而不是第一行
- 序号跟着列表顺序走，删除节点后会重排，脚本里建议仍用节点名
- `proxy <序号>` 后面只能跟要执行的命令，不接 `config` / `node` / `switch` 等管理子命令

- 节点存储于 `~/.proxy/profiles.json`，切换即整体覆盖当前配置
- `proxy status` 会显示当前节点名
- **写透**：有激活节点时 `config set`直接同步写回该节点。
  想改当前配置而不动节点，先 `proxy node unlink` 脱离
- `proxy node rename <旧> <新>` 重命名节点

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
<summary><b>🐚 代理子 shell</b> — <code>proxy on</code></summary>

不想每条命令都前缀 <code>proxy</code>, 而想“进入一个都走代理的环境”时:

```bash
proxy on          # 进入当前节点的代理子 shell
proxy 2 on        # 不切换当前节点,只进 2 号节点的代理环境

# 里面直接敲, 自动走代理:
curl https://google.com
git pull
npm install

exit              # 返回原来的 shell, 原环境不受影响
```

- **实现**: 启动一个注入了 <code>http_proxy</code> / <code>https_proxy</code> / <code>all_proxy</code> 的交互子 shell (继承 <code>$SHELL</code> 或平台默认 shell)
- **环境**: 子 shell 里读到的是这份注入后的环境,不再读外面的; 退出后外面原样
- **历史**: 依然是同一个用户与同一份 <code>HISTFILE</code>, 进出历史互通
- **用法**: 里面直接敲原生命令 (curl/git/npm 等); 若还要管理配置请先 <code>exit</code> 回到外面
- **注意**: 这是“子 shell”而非 screen/tmux,不支持 detach 后离开再回来

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

> Windows 上只注入小写的 `http_proxy` / `https_proxy` / `all_proxy`：系统环境变量本就不区分大小写，原生程序读大写照样拿得到；而 Git Bash / MSYS 这类子进程区分大小写，小写是通用惯例。

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

`profiles.json`（代理节点，`proxy node save` 创建）：

```json
{
  "dev":     { "host": "127.0.0.1", "port": "7890", "protocol": "http", "username": "", "password": "" },
  "company": { "host": "10.1.0.8",  "port": "8080", "protocol": "http", "username": "", "password": "" }
}
```

首次 `config set` / `alias add` / `node save` 时自动创建。

</details>

<details>
<summary><b>🔖 版本信息</b> — <code>proxy -v</code></summary>

```
proxy version 1.2.0

提交哈希: 9bccdac
构建时间: 2026-07-26 19:22 +08
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


</details>

<details>
<summary><b>🛠️ 开发</b></summary>

**项目结构**

```
├── src/
│   ├── main.zig        # 入口与命令分发
│   ├── config.zig      # 配置管理 (JSON 持久化)
│   ├── profile.zig     # 多节点保存/切换/重命名
│   ├── alias.zig       # 别名管理
│   ├── serve.zig       # 本地 HTTP 服务与配置管理接口
│   ├── storage.zig     # JSON 读取与原子保存
│   ├── web/            # 内嵌管理网页 (HTML/CSS/JS)
│   ├── check.zig       # 连通性检测 (TCP/HTTP/SOCKS)
│   └── output.zig      # Windows UTF-8 输出
├── scripts/            # 测试与 CHANGELOG 生成脚本
└── .github/workflows/  # 推 tag 自动发布
```

**常用命令**

```bash
zig build test                                   # 单元测试
python scripts/test_serve.py                      # 网页接口与 CLI 联调测试 (先 zig build)
python -B scripts/test_serve_browser.py             # 拖拽/触屏/键盘与布局验证 (需 Playwright Chromium)
zig build -Dtarget=x86_64-linux                  # 交叉编译
bash scripts/test.sh                             # 功能测试
bash scripts/gen-changelog.sh v1.2.0 --notes-only  # 预览更新日志
```

**发布流程**：提交代码 → `git tag v1.x.y` → `git push origin main --tags`，GitHub Actions 自动生成 CHANGELOG 回写主分支、交叉编译五个平台并创建 Release。

</details>

## 许可证

[MIT](LICENSE)
