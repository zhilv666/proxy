# Proxy 使用示例

## 基础配置

```bash
# 初始化配置（首次使用）
proxy config set host 127.0.0.1
proxy config set port 7890
proxy config set proto http

# 查看当前配置
proxy config get
```

## 日常使用

### 1. 使用内置别名

```bash
# 列出文件
proxy ll        # ls -l
proxy la        # ls -la
proxy l         # ls -lah
```

### 2. 网络工具

```bash
# 下载文件
proxy curl https://example.com
proxy wget https://example.com/file.zip

# 查看 IP
proxy curl ifconfig.me
proxy curl ipinfo.io
```

### 3. 包管理器

```bash
# NPM
proxy npm install express
proxy npm update

# Python Pip
proxy pip install requests
proxy pip install --upgrade pip

# Go
proxy go get github.com/user/package
proxy go mod download

# Rust Cargo
proxy cargo install ripgrep
proxy cargo update
```

### 4. Git 操作

```bash
# 克隆仓库
proxy git clone https://github.com/user/repo.git

# 拉取更新
proxy git pull origin main

# 推送（如果使用 HTTPS）
proxy git push origin main
```

## 高级配置

### 添加认证

```bash
# 设置用户名和密码
proxy config set user myusername
proxy config set password mypassword

# 验证
proxy config get
# 输出会显示:
#   user: myusername
#   password: ******
```

### 自定义别名

```bash
# 添加通用别名
proxy alias add all gs "git status"
proxy alias add all gp "git pull"

# 添加平台特定别名
proxy alias add windows cmd "cmd.exe /c"
proxy alias add linux cat "cat -n"

# 多行别名：每行一条命令，按顺序执行，某行失败即停止（不经过 shell，不支持 && 或管道）
proxy alias add linux update $'sudo apt update\nsudo apt upgrade -y'
proxy alias add macos brew $'brew update\nbrew upgrade'

# 使用自定义别名
proxy gs       # 执行 git status
proxy update   # 先 sudo apt update，再 sudo apt upgrade -y
```

别名支持单、双引号参数，以及跨平台的 `export NAME=value` 行。环境变量会传给同一别名中后续的命令，例如：

```text
export CODEX_CA_CERTIFICATE='D:\reqable-ca.pem'
codex --dangerously-bypass-approvals-and-sandbox
```

将以上内容保存为 `cx` 后，执行 `proxy cx` 即可。变量只作用于本次执行，不修改父终端；单独执行只有 `export` 的别名也不会改变父终端。值不做变量或命令替换；双引号内支持 `\\` 和 `\"` 转义，Windows 路径可用单引号保留反斜杠。

### 管理别名

```bash
# 列出所有别名
proxy alias list

# 删除别名
proxy alias remove all gs
proxy alias remove windows cmd
```

### 无代理执行与别名模式

```bash
proxy -n cx                         # 本次无代理（--no-proxy）
proxy -p cx                         # 本次使用当前代理（--proxy）
proxy alias mode all sm direct      # 保存已有别名的无代理模式
proxy sm                            # 使用保存的模式执行快捷命令
proxy alias mode all sm proxy       # 恢复使用代理
proxy 2 sm                          # 本次使用指定节点，覆盖别名模式
proxy alias list                    # 名称旁显示 [direct] 或 [proxy]
```

现有别名默认使用代理。临时参数或显式节点优先于别名设置；`-n` 与 `-p`、节点序号冲突时会报错。参数必须放在命令前，命令后的参数原样传给最后一行。`proxy -n -- <别名>` 可运行与内置命令或选项同名的别名。模式参数仅用于执行外部命令和别名，不用于 `config`、`alias`、`on` 等子命令。

无代理模式在每条命令启动前清除 `http_proxy`、`https_proxy`、`all_proxy`、`ftp_proxy` 及其大写形式，包括别名通过 `export` 设置的值。证书等其他变量仍然有效；代理配置缺失或损坏也不会阻止无代理命令运行。它不修改父终端或系统代理，应用自身的代理配置及 VPN 不在控制范围内。

在网页「命令别名」中编辑「执行模式」也能保存设置。重命名、移动平台或修改命令会保留模式；单次覆盖不写入配置。

## 场景示例

### 场景 1: 开发环境配置

```bash
# 安装 Node.js 依赖
cd /path/to/project
proxy npm install

# 安装 Python 依赖
cd /path/to/python-project
proxy pip install -r requirements.txt

# 克隆依赖仓库
proxy git clone https://github.com/vendor/library.git
```

### 场景 2: 系统更新（Linux）

```bash
# 添加更新别名（多行，按顺序执行）
proxy alias add linux update $'apt update\napt upgrade -y'

# 使用别名更新系统
proxy update
```

### 场景 3: 切换代理服务器

```bash
# 公司代理
proxy config set host proxy.company.com
proxy config set port 8080
proxy config set user employee123
proxy config set password companypass

# 家庭代理
proxy config set host 127.0.0.1
proxy config set port 7890
proxy config set user ""
proxy config set password ""
```

### 场景 4: 调试代理设置

```bash
# 检查环境变量
proxy sh -c 'echo $http_proxy'
proxy sh -c 'env | grep -i proxy'

# 测试连接
proxy curl -v https://google.com

# 查看配置
proxy config get
```

## 常见问题

### Q: 如何临时禁用代理？

A: 直接运行命令而不使用 `proxy` 前缀：

```bash
# 使用代理
proxy curl https://google.com

# 不使用代理
curl https://google.com
```

### Q: 如何验证代理是否生效？

A: 查看环境变量或测试 IP：

```bash
# 查看环境变量
proxy sh -c 'echo $http_proxy'

# 查看 IP（应该显示代理服务器的 IP）
proxy curl ifconfig.me
```

### Q: 别名不生效怎么办？

A: 检查别名配置和平台匹配：

```bash
# 列出别名
proxy alias list

# 确保平台正确
# Windows 用户确保别名是 "all" 或 "windows"
# Linux 用户确保别名是 "all" 或 "linux"
```

### Q: 配置文件在哪里？

A: 默认位置：

- Linux/macOS: `~/.proxy/config.json`
- Windows: `C:\Users\YourName\.proxy\config.json`

自定义位置（设置 `PROXY_HOME` 环境变量）：

```bash
# Linux/macOS
export PROXY_HOME=/custom/path

# Windows
set PROXY_HOME=C:\custom\path
```

### Q: 如何备份配置？

A: 复制配置文件：

```bash
# Linux/macOS
cp ~/.proxy/config.json ~/.proxy/config.json.backup

# Windows
copy %USERPROFILE%\.proxy\config.json %USERPROFILE%\.proxy\config.json.backup
```

### Q: 如何重置配置？

A: 删除配置文件并重新初始化：

```bash
# Linux/macOS
rm ~/.proxy/config.json

# Windows
del %USERPROFILE%\.proxy\config.json

# 重新初始化
proxy config set host 127.0.0.1
proxy config set port 7890
```

## 性能提示

1. **使用 Release 模式编译** 以获得最佳性能：
   ```bash
   zig build -Doptimize=ReleaseFast
   ```

2. **使用别名** 减少输入：
   ```bash
   proxy alias add all d "docker"
   proxy d ps    # 代替 proxy docker ps
   ```

3. **批量操作** 使用脚本：
   ```bash
   #!/bin/bash
   proxy npm install
   proxy npm test
   proxy npm build
   ```

## 与其他工具集成

### Shell 别名

添加到 `~/.bashrc` 或 `~/.zshrc`：

```bash
alias p='proxy'
alias pll='proxy ll'
alias pcurl='proxy curl'
alias pgit='proxy git'
```

使用：
```bash
p ll
pcurl https://google.com
pgit clone https://github.com/user/repo.git
```

### 环境变量

在脚本中使用：

```bash
#!/bin/bash
export PROXY_HOME=/custom/config
proxy curl https://api.example.com
```

## 更多示例

查看完整文档：[README.md](README.md)
