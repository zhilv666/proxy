.PHONY: all build release debug clean install uninstall test help

# 默认目标
all: release

# 编译（Debug 模式）
debug:
	@echo "Building in Debug mode..."
	zig build

# 编译（Release 模式）
build release:
	@echo "Building in Release mode..."
	zig build -Doptimize=ReleaseFast

# 编译（Release Safe 模式）
safe:
	@echo "Building in ReleaseSafe mode..."
	zig build -Doptimize=ReleaseSafe

# 编译（Release Small 模式）
small:
	@echo "Building in ReleaseSmall mode..."
	zig build -Doptimize=ReleaseSmall

# 清理构建产物
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-out zig-cache .zig-cache

# 安装到系统（Linux/macOS）
install:
	@echo "Installing proxy..."
	@if [ "$(shell uname)" = "Linux" ] || [ "$(shell uname)" = "Darwin" ]; then \
		cp zig-out/bin/proxy /usr/local/bin/proxy; \
		chmod +x /usr/local/bin/proxy; \
		echo "Installed to /usr/local/bin/proxy"; \
	else \
		echo "Install target only works on Linux/macOS"; \
		echo "On Windows, add zig-out/bin to your PATH"; \
		exit 1; \
	fi

# 卸载（Linux/macOS）
uninstall:
	@echo "Uninstalling proxy..."
	@if [ -f /usr/local/bin/proxy ]; then \
		rm /usr/local/bin/proxy; \
		echo "Uninstalled from /usr/local/bin/proxy"; \
	else \
		echo "proxy not found in /usr/local/bin"; \
	fi

# 运行测试
test: build
	@echo "Running tests..."
	@./zig-out/bin/proxy config get || echo "Config not initialized"
	@./zig-out/bin/proxy alias list
	@echo ""
	@echo "Test: Setting config..."
	@./zig-out/bin/proxy config set host 127.0.0.1
	@./zig-out/bin/proxy config set port 7890
	@./zig-out/bin/proxy config set proto http
	@echo ""
	@echo "Test: Getting config..."
	@./zig-out/bin/proxy config get
	@echo ""
	@echo "Test: Alias expansion..."
	@./zig-out/bin/proxy sh -c 'echo $$http_proxy'

# 显示帮助
help:
	@echo "Proxy CLI Tool - Makefile"
	@echo ""
	@echo "Usage:"
	@echo "  make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Build in release mode (default)"
	@echo "  build       - Build in release mode"
	@echo "  release     - Build in release mode (ReleaseFast)"
	@echo "  debug       - Build in debug mode"
	@echo "  safe        - Build in ReleaseSafe mode"
	@echo "  small       - Build in ReleaseSmall mode"
	@echo "  clean       - Remove build artifacts"
	@echo "  install     - Install to /usr/local/bin (Linux/macOS only)"
	@echo "  uninstall   - Uninstall from /usr/local/bin"
	@echo "  test        - Run basic functionality tests"
	@echo "  help        - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make              # Build in release mode"
	@echo "  make debug        # Build in debug mode"
	@echo "  make clean build  # Clean then build"
	@echo "  make test         # Build and run tests"
	@echo "  sudo make install # Install to system (requires sudo)"
