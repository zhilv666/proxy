# 由 scripts/gen-manifests.sh 自动生成，随 Release 更新
class Proxy < Formula
  desc "跨平台代理命令行工具 (Zig): 带代理执行、TUI、多节点切换、连通性检测"
  homepage "https://github.com/zhilv666/proxy"
  version "1.3.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.0/proxy-v1.3.0-aarch64-macos.tar.gz"
      sha256 "3bffdc430f6c2e485baaf59e7fdebf18725e952861ae8285b54a26f3f1e4f623"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.0/proxy-v1.3.0-x86_64-macos.tar.gz"
      sha256 "98149cb19ab1794f4fe35257190686b52492433b982158db27266e63b9e0cdb4"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.0/proxy-v1.3.0-aarch64-linux.tar.gz"
      sha256 "0f512850d2505844a1eee300f203a13f00dca9ede8b7bda3af9cf53a44fa8a70"
    else
      url "https://github.com/zhilv666/proxy/releases/download/v1.3.0/proxy-v1.3.0-x86_64-linux.tar.gz"
      sha256 "b33907093adef80b4a76c33d4aef46626ebb9a5f78f0130f6de40be0326c19b8"
    end
  end

  def install
    bin.install "proxy"
  end

  test do
    system "#{bin}/proxy", "-v"
  end
end
