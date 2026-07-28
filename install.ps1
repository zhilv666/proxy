# proxy 一键安装脚本 (Windows)
#   irm https://zhilv666.github.io/proxy/install.ps1 | iex
$ErrorActionPreference = "Stop"

$repo = "zhilv666/proxy"
$tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
$url = "https://github.com/$repo/releases/download/$tag/proxy-$tag-x86_64-windows.zip"
$dir = "$env:LOCALAPPDATA\Programs\proxy"

Write-Host "下载 $url"
New-Item -ItemType Directory -Force $dir | Out-Null
$zip = Join-Path $env:TEMP "proxy-install.zip"
Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip $dir -Force
Remove-Item $zip

# 加入用户 PATH (已存在则跳过)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
    Write-Host "已添加 $dir 到用户 PATH，新开终端生效"
}

Write-Host "✓ proxy $tag 已安装到 $dir\proxy.exe"
& "$dir\proxy.exe" -v
