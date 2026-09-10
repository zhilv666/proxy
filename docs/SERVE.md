# 网页配置管理

`proxy serve` 启动内嵌网页，用于管理已保存节点和命令别名，并显示当前使用的节点。直接修改当前代理参数或解除节点关联请使用 CLI 的 `proxy config set` 与 `proxy node unlink`；对应的 `/api/config` 与 `/api/nodes/unlink` 接口保留。服务和网页都包含在同一个可执行文件中。

## 启动

```bash
proxy serve                 # http://127.0.0.1:8080/
proxy serve --port 9090      # 使用其他端口
proxy serve -p 0             # 自动选择空闲端口，以终端输出为准
proxy serve --help
```

在浏览器中打开终端输出的地址；按 `Ctrl+C` 停止服务。服务仅监听 `127.0.0.1`，端口占用或参数错误会返回非零退出码。

默认使用 `~/.proxy/`（Windows 为用户主目录下的 `.proxy/`）。使用独立配置目录：

```powershell
# PowerShell
$env:PROXY_HOME = 'C:\path\to\proxy-config'
proxy serve
```

```bash
# Linux / macOS
PROXY_HOME="$PWD/proxy-config" proxy serve
```

目录在首次保存时创建。网页和 CLI 共用 `config.json`、`profiles.json`、`aliases.json`，点击「刷新」可读取 CLI 或其他页面保存的最新内容。

## 管理行为

| 操作 | 结果 |
| --- | --- |
| 添加节点 | 新建一份独立配置，当前连接保持原样 |
| 启用节点 | 整体替换当前代理配置，后续 CLI 命令使用该节点；顶部概览同步显示当前节点和地址 |
| 编辑或重命名激活节点 | 同步更新当前代理参数和关联名称 |
| 删除激活节点 | 删除保存的节点，保留当前代理参数并解除关联 |
| 编辑别名 | 可同时修改名称、命令和平台；命令可写多行，每行一条按顺序执行；与其他别名冲突时拒绝保存 |
| 拖动节点 | 松开手柄后保存顺序，网页与 `proxy node list` 的序号同步更新，当前激活节点保持原样 |
| 拖动别名 | 保存展示顺序，支持不同平台交错排列，平台匹配优先级保持原样 |

代理协议支持 `http`、`https`、`socks5`、`socks4`，端口范围为 `1–65535`。别名平台支持 `all`、`windows`、`linux`、`macos`；执行时保留现有 CLI 的平台优先规则。节点名称按字面值处理，不把数字名称解释为列表序号。

名称重名、无效字段和文件读写失败会显示错误；引号、反斜杠和中文按 JSON 规则保存。单个文件先写临时文件，再原子替换。网页不执行别名中的命令。

## 调整列表顺序

按住每行左侧的六点手柄拖动，绿色线条表示放置位置，松开后自动保存；触屏设备可直接拖动手柄。也可以用 Tab 聚焦手柄后按 `↑` / `↓` 上下移动，`Home` / `End` 移到首位或末位，按 `Escape` 取消正在进行的拖动。

搜索或平台筛选后，只调整可见条目的相对顺序，隐藏条目保留原位置。保存失败时保留原有顺序并显示错误；如果其他客户端增加或删除了配置，刷新列表后再排序。

节点顺序保存在 `profiles.json` 的键顺序中，修改名称和删除条目会保留其他节点顺序。别名展示顺序保存在配置目录的 `order.json` 中，原有 `aliases.json` 的平台分组格式不变：

```json
{
  "aliases": [
    { "platform": "windows", "name": "open" },
    { "platform": "all", "name": "gs" }
  ]
}
```

刷新网页或重启服务后仍按保存的顺序显示；新添加的条目排在末尾，改名或移动别名平台会保留已设置的位置。

## 本机 HTTP 接口

请求及响应使用 JSON。写请求必须带上以下请求头：

```http
Content-Type: application/json
X-Proxy-Request: 1
```

接口校验本机 `Host` 和浏览器 `Origin`，不启用跨域访问。每个请求独立读取配置；同一服务中的配置操作串行执行。单个请求体上限为 64 KiB。

| 方法 | 路径 | 请求 / 返回 |
| --- | --- | --- |
| GET | `/api/state` | 返回 `{config, nodes, aliases, platform}` |
| GET | `/api/config` | 返回当前原始配置（空字段代表 CLI 默认值），包含 `node` |
| PUT | `/api/config` | 写入代理字段，保留并同步当前节点关联 |
| DELETE | `/api/config` | 恢复当前默认配置，请求体 `{}` |
| GET | `/api/nodes` | 返回节点数组，每项包含 `name` 和代理字段 |
| POST | `/api/nodes` | 新建节点，包含 `name` 和代理字段 |
| PUT | `/api/nodes` | 编辑节点，包含 `original_name`、新 `name` 和代理字段 |
| PUT | `/api/nodes/order` | 保存完整节点顺序，请求体 `{ "names": ["dev", "office"] }` |
| DELETE | `/api/nodes` | 删除节点，请求体 `{ "name": "dev" }` |
| POST | `/api/nodes/activate` | 启用节点，请求体 `{ "name": "dev" }` |
| POST | `/api/nodes/unlink` | 解除当前关联，请求体 `{}` |
| GET | `/api/aliases` | 返回 `{platform, name, command}` 数组 |
| POST | `/api/aliases` | 新建别名，包含 `platform`、`name`、`command` |
| PUT | `/api/aliases` | 编辑别名，另需 `original_platform` 和 `original_name` |
| PUT | `/api/aliases/order` | 保存完整别名顺序，请求体 `{ "aliases": [{ "platform": "all", "name": "gs" }] }` |
| DELETE | `/api/aliases` | 删除别名，包含 `platform` 和 `name` |

代理字段中的 `host`、`port`、`protocol` 为必填字符串；`username`、`password` 为可选字符串，省略时清空。示例：

```json
{
  "name": "dev",
  "host": "127.0.0.1",
  "port": "7890",
  "protocol": "http",
  "username": "",
  "password": ""
}
```

新建成功返回 `201`，其他写入成功返回 `200` 和 `{ "ok": true }`。排序请求须包含全部现有条目，不能重复，仅调整顺序而不修改配置值。错误响应包含 `error`（可读说明）和 `err`（错误标识）；常见状态为 `400`（输入无效或排序有重复）、`403`（请求来源不符）、`404`（配置不存在）、`409`（重名或排序列表已过期）、`500`（配置文件读取或保存失败）。

## 开发验证

需要 Zig 0.15.2；接口测试额外需要 Python 3，仅使用标准库。

```bash
zig build
zig build test
python scripts/test_serve.py
# 可指定其他位置的编译产物
python scripts/test_serve.py path/to/proxy
```

测试在临时 `PROXY_HOME` 中启动真实服务，覆盖嵌入资源、配置和节点/别名增删查改、激活同步、JSON 特殊字符、CLI 互通、顺序持久化、改名和删除后的顺序、过期排序请求、重启持久化、并发保存、无效输入及本机访问校验。

浏览器验证额外需要 Python Playwright 及 Chromium：

```bash
python -B scripts/test_serve_browser.py
```

浏览器脚本使用独立配置目录，覆盖鼠标和真实触屏拖动、键盘排序、筛选下排序、保存失败、过期列表、刷新恢复及桌面/手机布局，并将截图保存到 `.zig-cache/serve-sort-*.png`。
