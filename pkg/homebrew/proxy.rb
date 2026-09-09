# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.5.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.5.0/proxy-v1.5.0-aarch64-macos.tar.gz"
      sha256 "8fbf0911bac67e1dbc3917d69d871d5a2f84844812dca722127bc1860d866c4c"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.5.0/proxy-v1.5.0-x86_64-macos.tar.gz"
      sha256 "3c8544e6f6867411585e86d2363690f8168fb0060be2fea6acc922e1b2ee4deb"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.5.0/proxy-v1.5.0-aarch64-linux.tar.gz"
      sha256 "f1955d180a4d4e9b1ec130744c1c00bddf054d403cac41f16f53ff689a9c1633"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.5.0/proxy-v1.5.0-x86_64-linux.tar.gz"
      sha256 "3c1f457b7c07db4783010ceebb1ceff18722ca64119ef5429aa64c9abf24e5cd"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
