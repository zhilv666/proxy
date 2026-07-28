# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.4.1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.1/proxy-v1.4.1-aarch64-macos.tar.gz"
      sha256 "3bd25a2c594dc00fff82cafbed176d5033c4f37ea8e526a8490cfc6e293de11c"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.1/proxy-v1.4.1-x86_64-macos.tar.gz"
      sha256 "2f6adcc63114eec7fb67913efeee28f27911b835ab5c4055e85d69d9de56b909"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.1/proxy-v1.4.1-aarch64-linux.tar.gz"
      sha256 "536d7b5a777eb702885a794ec0dbc7f14996a23d470af2d8d6e3ffcf867bbf35"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.1/proxy-v1.4.1-x86_64-linux.tar.gz"
      sha256 "4b6b247c872f39c4c8e313bfaba0bc2103bedde0b6863da6f4b22c36f7455413"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
