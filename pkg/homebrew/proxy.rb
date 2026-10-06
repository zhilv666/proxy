# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.6.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.6.0/proxy-v1.6.0-aarch64-macos.tar.gz"
      sha256 "95433d13f83cc93c8ef165fa5eb1e11b394b4e2918711a76e7311814db66b375"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.6.0/proxy-v1.6.0-x86_64-macos.tar.gz"
      sha256 "40879d799c59378eeafb6a61698099b8e5c32dfd4d2b4b8eaf00adaf9c334ccc"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.6.0/proxy-v1.6.0-aarch64-linux.tar.gz"
      sha256 "da35df62af4d20473c2287d1e78ac925a6304c6027d70ab8b13132e56d279f42"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.6.0/proxy-v1.6.0-x86_64-linux.tar.gz"
      sha256 "eee90961fb4e0bc159aa3f09516d1bae9c258b1dc2b8722a266cd6c4d6adde3f"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
