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
proxy alias add all update "apt update && apt upgrade -y"

# 添加平台特定别名
proxy alias add windows cmd "cmd.exe /c"
proxy alias add linux cat "cat -n"
proxy alias add macos brew "brew update && brew upgrade"

# 使用自定义别名
proxy gs       # 执行 git status
proxy update   # 执行 apt update && apt upgrade -y
```

### 管理别名

```bash
# 列出所有别名
proxy alias list

# 删除别名
proxy alias remove all gs
proxy alias remove windows cmd
```

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
# 添加更新别名
proxy alias add linux update "apt update && apt upgrade -y"

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
