# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.7.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.7.0/proxy-v1.7.0-aarch64-macos.tar.gz"
      sha256 "269fe4ad7aecdb5eba38f4b9da52d7af4e2257c81c41856bbaff05493fe98f9e"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.7.0/proxy-v1.7.0-x86_64-macos.tar.gz"
      sha256 "193f41112df2dcfee9b345d0b03556248ec564672ea7adf317b8927a3264e46b"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.7.0/proxy-v1.7.0-aarch64-linux.tar.gz"
      sha256 "36fba0076785fd97777376f04e63a7606e1f3ed88644d0c65508c1bb9830cf15"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.7.0/proxy-v1.7.0-x86_64-linux.tar.gz"
      sha256 "15b08f98d2c8e9f42ed7f2bbf13629e9b9c3ed7c8e0a0a5d532cbd3320668ba9"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
