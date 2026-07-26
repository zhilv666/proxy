# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.3.1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.1/proxy-v1.3.1-aarch64-macos.tar.gz"
      sha256 "0b5f11d7202aa042c224c8cc87a204582c21bd0226af002f86ca5aa656554a92"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.1/proxy-v1.3.1-x86_64-macos.tar.gz"
      sha256 "10ea07a4114ec44dc48891764bd82761a2cafb5a79c39bcefe3200271da4e11e"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.1/proxy-v1.3.1-aarch64-linux.tar.gz"
      sha256 "18185561111f2d0ad0ba06bbc23394727945d59ff0a6e82c0c6d1f8bafcba116"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.1/proxy-v1.3.1-x86_64-linux.tar.gz"
      sha256 "462e6e7b96e2978feca2c648fb9e2383c83f5bdac0d357740d9c723fee288702"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
