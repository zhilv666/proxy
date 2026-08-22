# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.4.2"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.2/proxy-v1.4.2-aarch64-macos.tar.gz"
      sha256 "2744f112504450f428f8bd35a10ee253d925d84e6122da67585e2ff92618edad"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.2/proxy-v1.4.2-x86_64-macos.tar.gz"
      sha256 "2501308865a5b78548c299f7958e023a417f073ba3be9d60b6c5a780a9c833da"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.2/proxy-v1.4.2-aarch64-linux.tar.gz"
      sha256 "4a1fa66786bf236e8d24f8fc78040fc81d39271412bf8129d4327edca9ae404e"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.4.2/proxy-v1.4.2-x86_64-linux.tar.gz"
      sha256 "da736ba6f60862a5554c89199ae07034f4fbb6c5e50029b6d817af6cecbe6f37"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
