#!/bin/bash
# ============================================================
#  AI Terminal - 全平台构建脚本
#  用法: ./build_all.sh [platform]
#  platform: macos | windows | linux | android | ios | web | all | current
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
VERSION=$(grep 'version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d'+' -f1)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 创建输出目录
mkdir -p "$BUILD_DIR"

# 检查 Flutter 环境
check_flutter() {
    if ! command -v flutter &> /dev/null; then
        log_error "Flutter 未安装，请先安装 Flutter SDK"
        exit 1
    fi
    log_info "Flutter 版本: $(flutter --version | head -1)"
}

# 生成 Hive Adapter
generate_adapters() {
    log_info "生成 Hive Adapter..."
    dart run build_runner build --delete-conflicting-outputs
}

# ============================================================
#  macOS 构建
# ============================================================
build_macos() {
    log_info "开始构建 macOS..."
    
    if [[ "$(uname)" != "Darwin" ]]; then
        log_warn "macOS 构建需要在 macOS 系统上执行"
        return 1
    fi
    
    flutter build macos --release
    
    # 创建 DMG (可选，需要安装 create-dmg)
    local APP_PATH="build/macos/Build/Products/Release/ai_terminal.app"
    if [ -d "$APP_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-macOS-v${VERSION}.zip"
        cd build/macos/Build/Products/Release/
        zip -r "$OUTPUT" "ai_terminal.app"
        cd "$PROJECT_DIR"
        log_ok "macOS 构建完成: $OUTPUT"
    else
        log_error "macOS 构建失败，未找到 .app 文件"
        return 1
    fi
}

# ============================================================
#  Windows 构建
# ============================================================
build_windows() {
    log_info "开始构建 Windows..."
    
    flutter build windows --release
    
    local EXE_PATH="build/windows/x64/runner/Release"
    if [ -d "$EXE_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-Windows-v${VERSION}.zip"
        cd "$EXE_PATH"
        zip -r "$OUTPUT" .
        cd "$PROJECT_DIR"
        log_ok "Windows 构建完成: $OUTPUT"
    else
        log_error "Windows 构建失败"
        return 1
    fi
}

# ============================================================
#  Linux 构建
# ============================================================
build_linux() {
    log_info "开始构建 Linux..."
    
    flutter build linux --release
    
    local LINUX_PATH="build/linux/x64/release/bundle"
    if [ -d "$LINUX_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-Linux-v${VERSION}.tar.gz"
        cd "$LINUX_PATH"
        tar czf "$OUTPUT" .
        cd "$PROJECT_DIR"
        log_ok "Linux 构建完成: $OUTPUT"
    else
        log_error "Linux 构建失败"
        return 1
    fi
}

# ============================================================
#  Android 构建
# ============================================================
build_android() {
    log_info "开始构建 Android APK..."
    
    flutter build apk --release
    
    local APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$APK_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-Android-v${VERSION}.apk"
        cp "$APK_PATH" "$OUTPUT"
        log_ok "Android APK 构建完成: $OUTPUT"
    else
        log_error "Android APK 构建失败"
        return 1
    fi
    
    # 可选: 构建 App Bundle (用于 Google Play)
    log_info "开始构建 Android App Bundle (AAB)..."
    flutter build appbundle --release
    
    local AAB_PATH="build/app/outputs/bundle/release/app-release.aab"
    if [ -f "$AAB_PATH" ]; then
        local OUTPUT_AAB="$BUILD_DIR/AI-Terminal-Android-v${VERSION}.aab"
        cp "$AAB_PATH" "$OUTPUT_AAB"
        log_ok "Android AAB 构建完成: $OUTPUT_AAB"
    fi
}

# ============================================================
#  iOS 构建 (需要 macOS + 开发者证书)
# ============================================================
build_ios() {
    log_info "开始构建 iOS..."
    
    if [[ "$(uname)" != "Darwin" ]]; then
        log_warn "iOS 构建需要在 macOS 系统上执行"
        return 1
    fi
    
    # IPA 构建需要开发者证书，这里只做 archive
    flutter build ipa --release
    
    local IPA_PATH="build/ios/ipa"
    if [ -d "$IPA_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-iOS-v${VERSION}.ipa"
        cp "$IPA_PATH"/*.ipa "$OUTPUT" 2>/dev/null || true
        log_ok "iOS IPA 构建完成: $OUTPUT"
    else
        log_warn "iOS IPA 构建需要有效的开发者证书"
        log_info "可使用 'flutter build ios --release' 生成 .app，再手动打包 IPA"
    fi
}

# ============================================================
#  Web 构建
# ============================================================
build_web() {
    log_info "开始构建 Web..."
    
    flutter build web --release
    
    local WEB_PATH="build/web"
    if [ -d "$WEB_PATH" ]; then
        local OUTPUT="$BUILD_DIR/AI-Terminal-Web-v${VERSION}.tar.gz"
        cd "$WEB_PATH"
        tar czf "$OUTPUT" .
        cd "$PROJECT_DIR"
        log_ok "Web 构建完成: $OUTPUT"
    else
        log_error "Web 构建失败"
        return 1
    fi
}

# ============================================================
#  主入口
# ============================================================
main() {
    check_flutter
    
    local platform="${1:-current}"
    
    case "$platform" in
        macos)
            build_macos
            ;;
        windows)
            build_windows
            ;;
        linux)
            build_linux
            ;;
        android)
            build_android
            ;;
        ios)
            build_ios
            ;;
        web)
            build_web
            ;;
        all)
            log_info "=========================================="
            log_info "  AI Terminal v${VERSION} - 全平台构建"
            log_info "=========================================="
            
            local failed=()
            
            build_macos    || failed+=("macOS")
            build_windows  || failed+=("Windows")
            build_linux    || failed+=("Linux")
            build_android  || failed+=("Android")
            build_ios      || failed+=("iOS")
            build_web      || failed+=("Web")
            
            echo ""
            log_info "=========================================="
            log_info "  构建结果汇总"
            log_info "=========================================="
            
            if [ ${#failed[@]} -eq 0 ]; then
                log_ok "所有平台构建成功！"
            else
                log_warn "以下平台构建失败: ${failed[*]}"
                log_info "注意：跨平台构建可能需要在对应系统上执行"
            fi
            
            log_info "构建产物位于: $BUILD_DIR"
            ls -lh "$BUILD_DIR/" 2>/dev/null || true
            ;;
        current)
            # 根据当前系统构建
            local os="$(uname -s)"
            case "$os" in
                Darwin)
                    build_macos
                    ;;
                Linux)
                    build_linux
                    ;;
                MINGW*|MSYS*|CYGWIN*)
                    build_windows
                    ;;
                *)
                    log_error "不支持的系统: $os"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "用法: $0 [macos|windows|linux|android|ios|web|all|current]"
            echo ""
            echo "  macos    - 构建 macOS 应用"
            echo "  windows  - 构建 Windows 应用"
            echo "  linux    - 构建 Linux 应用"
            echo "  android  - 构建 Android APK + AAB"
            echo "  ios      - 构建 iOS IPA (需要开发者证书)"
            echo "  web      - 构建 Web 应用"
            echo "  all      - 构建所有平台"
            echo "  current  - 构建当前平台 (默认)"
            exit 1
            ;;
    esac
}

main "$@"
