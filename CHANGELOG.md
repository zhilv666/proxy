# Changelog

## [1.4.2] - 2026-08-22

### 新增
- ✨ feat(node): 支持按序号指定节点，proxy 1 <命令> 临时执行 (f19e8d7)

### 修复
- 🐛 fix(core): 修复节点写透误伤、Windows 代理变量大小写与别名内存泄漏 (b00ae8a)

### 其他
- chore: 更新 v1.4.1 包管理器清单 (2e434d8)

## [1.4.1] - 2026-07-28

### 新增
- ✨ feat(pkg): Scoop bucket 化 + 安装脚本走 Pages 短链接 (36ac139)

### 其他
- Delete CNAME (5e36e1c)
- Create CNAME (3726e2f)
- Delete CNAME (62b87d0)
- Create CNAME (8cb56d6)
- chore: 更新 v1.4.0 包管理器清单 (a4674a4)

## [1.4.0] - 2026-07-28

### 新增
- ✨ feat(screen): 带代理的会话管理，包装 screen/tmux (066ea26)

### 修复
- 🐛 fix(ci): 加固 Homebrew Tap 同步，新增手动补跑工作流 (f57260a)

### 其他
- 🔧 chore: 移除误提交的调试文件 (e7457f1)
- chore: 更新 v1.3.1 包管理器清单 (bf20435)

## [1.3.1] - 2026-07-26

### 新增
- ✨ feat(pkg): 集成 Scoop / Homebrew / 一键安装脚本 (32f2cac)

### 修复
- 🐛 fix(changelog): 排除 CI 更新日志回写提交 (eec8165)

## [1.3.0] - 2026-07-26

### 新增
- ✨ feat(tui): 行内编辑支持光标左右移动 (29b2468)
- ✨ feat(node): 节点重命名 + config set 写透同步到激活节点 (b131bb2)
- ✨ feat(tui): 重构为主-从布局，右侧详情面板逐字段编辑 (fcfb6c7)
- ✨ feat(tui): 节点面板集成到 TUI (2db14fb)
- ✨ feat(node): 多代理节点保存与一键切换 (68d0d98)

### 文档
- docs: 更新 v1.2.0 更新日志 (08e6048)

## [1.2.0] - 2026-07-26

### 新增
- ✨ feat(protocol): 协议选项扩展为 http/https/socks5/socks4 (009cb30)
- ✨ feat(check): 新增 proxy status/check 代理连通性与延迟检测 (2441caa)
- ✨ feat(version): proxy -v 显示构建信息，版本号跟随 git tag (7ced615)

### 修复
- 🐛 fix(tui): 选项行宽度自适应 + 窗口缩放实时重绘 (9bccdac)
- 🐛 fix(tui): 协议选项紧凑排列，修复窄面板显示不全 (5ddd117)

### 文档
- 📝 docs(readme): 重写 README，折叠式结构 + 同步当前功能 (0eb5165)

## [1.1.0] - 2026-07-26

### 变更
- ✅ `proxy tui` 重写为全屏交互式界面 (基于 src/term.zig 终端层)
  - 原始模式 + 备用屏幕，退出后完整恢复终端内容
  - 方向键/jk 导航、Tab 切换面板，不再需要"输数字 + 回车"
  - 配置项行内编辑 (Enter 编辑，Esc 取消，留空恢复默认，端口自动校验)
  - Protocol 改为 http / socks5 二选一 (←→ 切换，Enter 保存)，不再自由输入
  - 别名面板: a 添加 (平台复选框可多选，空格勾选，一次保存到多个平台)、Enter 编辑命令、d + y 确认删除、列表滚动
  - 列表按 (名称, 命令) 跨平台合并显示，如 `[linux+macos] gs → git status`；
    编辑/删除按整组操作；勾选 all 或三系统全选时自动归并为一条 all 记录
  - 整屏双缓冲渲染，无闪烁；中文按双列宽对齐，窗口缩放自适应
  - 界面撑满整个终端: 宽屏 (≥90 列) 自动切换左右双栏布局
    (左栏配置 + 快捷键说明，右栏别名列表)，弹窗居中悬浮；窄屏保持上下堆叠
  - 非交互终端 (重定向) 下自动回退为错误提示

### 新增
- ✅ `alias.getAll()` / `freeEntries()` 程序化读取别名 API
- ✅ `zig build test` 单元测试步骤 (term.zig 宽度计算 + TUI 布局不变量)

---

## [1.0.2] - 2026-07-24

### 新增
- ✅ 添加 `proxy list` 快捷命令
  - 现在可以直接使用 `proxy list` 代替 `proxy alias list`
  - 更简洁的命令体验

### 修复
- ✅ 修复 `proxy list` 导致的 FileNotFound 错误
  - 之前会尝试执行 `list` 命令而不是列出别名
  - 现在正确识别为内置命令

---

## [1.0.1] - 2026-07-24

### 修复
- ✅ 修复 Windows 控制台中文乱码问题
  - 在程序启动时自动设置控制台为 UTF-8 模式 (CP65001)
  - 现在所有中文提示信息都能正常显示
  - 使用 `SetConsoleOutputCP(65001)` API 实现

### 技术细节
```zig
// 在 main 函数开头添加
if (builtin.os.tag == .windows) {
    _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
}
```

### 测试
- ✅ Windows 10/11 Git Bash - 中文正常
- ✅ Windows CMD - 中文正常
- ✅ Windows PowerShell - 中文正常
- ✅ 所有功能测试通过 (7/7)

---

## [1.0.0] - 2026-07-24

### 新增
- ✅ 配置管理系统
  - `proxy config set <key> <value>` - 设置配置
  - `proxy config get [key]` - 查看配置
  - JSON 持久化存储
  - 密码保护显示

- ✅ 别名管理系统
  - `proxy alias add <platform> <name> <command>` - 添加别名
  - `proxy alias remove <platform> <name>` - 删除别名
  - `proxy alias list` - 列出所有别名
  - 支持平台特定别名 (all/windows/linux/macos)
  - 内置默认别名 (ll/la/l)

- ✅ 代理执行系统
  - 自动环境变量注入
  - 别名自动展开
  - URL 编码认证
  - 跨平台支持

### 特性
- ✅ 零外部依赖
- ✅ 单个可执行文件
- ✅ 跨平台支持 (Windows/Linux/macOS)
- ✅ 完整的错误处理
- ✅ 内存安全保证
- ✅ 10x 启动速度提升 (相比 Bash 脚本)
- ✅ 4x 内存占用减少

### 文档
- ✅ README.md - 完整使用文档
- ✅ USAGE.md - 实用示例集
- ✅ SUMMARY.md - 项目技术总结
- ✅ PROJECT_STATUS.md - 项目完成状态
- ✅ Makefile - 构建工具
- ✅ test.sh - 自动化测试脚本
