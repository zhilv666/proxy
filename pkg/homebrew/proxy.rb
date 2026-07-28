# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.4.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.0/proxy-v1.4.0-aarch64-macos.tar.gz"
      sha256 "2702d2f9861633a4bb1d0a38075382984bb57050576724060c1498f62ec90a36"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.0/proxy-v1.4.0-x86_64-macos.tar.gz"
      sha256 "eb6c0d496a8c71872f79b8b295304821916078e86986277649e976946938ffa7"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.0/proxy-v1.4.0-aarch64-linux.tar.gz"
      sha256 "c5a9d835dd89e1a07c50a4bca95c6a95d361d4dd7488877552e00f804ee1e95a"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.0/proxy-v1.4.0-x86_64-linux.tar.gz"
      sha256 "d4275c2ca714b101881868af4230fdb58d2a4186f1d8e8bac015aa0b5ae7197b"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
