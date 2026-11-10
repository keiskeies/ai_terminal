# 在 macOS 上本地构建 Flutter Windows 包（MinGW 交叉编译）

Flutter **不支持**在非 Windows 主机上构建 Windows 桌面包（
`build_windows.dart` 有 host 守卫，且 Windows 目标的 AOT 编译器只以
`gen_snapshot.exe` 形式发布）。本文记录一条在 macOS 上跑通的交叉构建路线：
CMake 用 MinGW-w64，AOT 用 Wine 执行 `gen_snapshot.exe`。

产物：`build/windows/x64/runner/Release/ai_terminal.exe`（+ 引擎 DLL、插件 DLL、
`data/flutter_assets`）。

> **功能差异**：本路线的 `local_auth_windows`（Windows Hello 生物识别锁）用桩替代，
> 详见下方「已知偏差」。需要全功能 exe 请用 CI 的
> `.github/workflows/build-release.yml`（`windows-latest`）。

## 一、前置条件

```bash
brew install mingw-w64            # x86_64-w64-mingw32-gcc 16.2 + 完整 Win32 导入库
flutter config --enable-windows-desktop
flutter precache --all-platforms   # 官方开关：非 Windows 主机也会下 windows-x64* 引擎
```

Wine（用于跑 `gen_snapshot.exe`，brew 的 `wine-stable` cask 已被 Gatekeeper 禁用，需直下）：

```bash
# 官方便携构建，解出 "Wine Stable.app"
curl -L -o /tmp/wine.tar.xz \
  https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz
mkdir -p ~/opt/wine-stable && tar xf /tmp/wine.tar.xz -C ~/opt/wine-stable
```

`gen_snapshot` 包装器（flutter 在非 Windows 主机按「宿主命名」`gen_snapshot` 查找，
而引擎里只有 `gen_snapshot.exe`）：

```bash
# 对每个 windows-x64* 引擎目录放置包装器（内容见下方附录）
```

## 二、构建命令

```bash
cd ai_terminal
export FLUTTER_CROSS_BUILD_WINDOWS=1
export FLUTTER_CROSS_TOOLCHAIN="$PWD/../tools/windows-cross/mingw-toolchain.cmake"
# flutter 的原生资产(native assets)路径会探测 Visual Studio；设一个占位目录即可
# 走到「VS 未安装 → 返回 null」的正常分支，无需真装 VS。
mkdir -p /tmp/pf_dummy
env 'PROGRAMFILES(X86)=/tmp/pf_dummy' flutter build windows --release
```

## 三、Flutter SDK 补丁（2 处，均带环境变量开关）

SDK 补丁在升级 Flutter 时会**丢失**，需重新应用。

### 1. `packages/flutter_tools/lib/src/commands/build_windows.dart`

原：`if (!globals.platform.isWindows) throwToolExit(...)`
改为：仅当未设 `FLUTTER_CROSS_BUILD_WINDOWS=1` 时才抛错。**默认行为不变。**

### 2. `packages/flutter_tools/lib/src/windows/build_windows.dart`

- 交叉模式下不再构造 `VisualStudio`，改用 `FLUTTER_CROSS_CMAKE`（默认 `cmake`）
  与 `FLUTTER_CROSS_CMAKE_GENERATOR`（默认 `Unix Makefiles`）；
- `_runCmakeGeneration` 在交叉模式下省略 `-A <arch>`（VS 生成器专有参数），
  改从 `FLUTTER_CROSS_TOOLCHAIN` 注入 `CMAKE_TOOLCHAIN_FILE`，并**显式传
  `-DCMAKE_BUILD_TYPE=<Release|Profile|Debug>`**；
- `_runBuild` 在交叉模式下把目标名 `INSTALL` 换成小写 `install`
  （非 VS 生成器没有 `INSTALL` 这个目标）。

> **`CMAKE_BUILD_TYPE` 是必须的，否则静默打出 Debug 包。** VS 是多配置
> 生成器，构建模式由 `cmake --build --config Release` 在编译期选；Unix
> Makefiles 是单配置，模式在 configure 阶段就定死了。项目模板里
> `set(CMAKE_BUILD_TYPE "Debug" ... FORCE)` 会在 configure 时把模式定成
> Debug，之后 `--config Release` 被完全忽略 —— 构建照样「✓ Built」成功，
> 但产物是 JIT 包：`data/flutter_assets/kernel_blob.bin`（~94MB）、
> 不调用 `gen_snapshot`、`data/app.so` 也不安装。
> 自检：`grep CMAKE_BUILD_TYPE:STRING build/windows/x64/CMakeCache.txt`
> 必须是 `Release`；产物里必须是 `app.so` 而不是 `kernel_blob.bin`。

> **单配置生成器没有 `Release/` 子目录。** 产物直接落在
> `build/windows/x64/runner/`（`CMAKE_INSTALL_PREFIX` 是
> `$<TARGET_FILE_DIR:ai_terminal>`）。`flutter build` 末尾那句
> `✓ Built build/windows/x64/runner/Release` 是它按 VS 布局硬编码打印的，
> **该目录并不存在** —— 别照它写打包脚本。CI 走 VS 生成器仍然有
> `Release/`，所以 `build_all.sh` / workflow 里的路径要按生成器分支。

> **改过构建模式后必须 `rm -rf build`。** Debug 与 Release 的产物落在
> 同一目录，切模式不会清场：`data/flutter_assets/kernel_blob.bin`（Debug
> 遗留）会和 Release 的 `data/app.so` 并存，打出的 zip 白搭 94MB，
> 而且没法靠目录内容判断这次到底编了哪种模式。


> **重要**：Flutter 只在 `git rev-parse HEAD` 变化时重建 `flutter_tools.snapshot`
> （`bin/internal/shared.sh` 的 `compilekey`）。改完 SDK 源码后必须手动失效：
> ```bash
> rm -f $FLUTTER_ROOT/bin/cache/flutter_tools.snapshot $FLUTTER_ROOT/bin/cache/flutter_tools.stamp
> ```
>
> 如果这时**没有网络**，重建会卡在 `dart pub upgrade`（`shared.sh` 里写死联网
> 且失败重试，没有 offline 分支）。依赖本来就在 pub cache 里的话，可以跳过
> 那一步直接编译快照 —— 和 `shared.sh` 跑的是同一条命令：
> ```bash
> cd $FLUTTER_ROOT/packages/flutter_tools
> dart pub upgrade --offline --suppress-analytics
> D=$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart
> REV=$(cd $FLUTTER_ROOT && git rev-parse HEAD)
> $D --verbosity=error --snapshot=$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot \
>    --snapshot-kind=app-jit \
>    --packages=$PWD/.dart_tool/package_config.json \
>    --no-enable-mirrors bin/flutter_tools.dart >/dev/null
> echo "$REV:" > $FLUTTER_ROOT/bin/cache/flutter_tools.stamp   # 默认 FLUTTER_TOOL_ARGS 为空
> ```


## 四、项目侧改动（本仓库，随代码提交）

| 文件 | 改动 | 原因 |
|---|---|---|
| `tools/windows-cross/mingw-toolchain.cmake` | 新增 | mingw 工具链 + C++17 + 兼容头目录 |
| `ai_terminal/windows/CMakeLists.txt` | `APPLY_STANDARD_SETTINGS` 按 `MSVC` 分支 | `/W4 /WX /EHsc` 是 MSVC 专属写法，gcc 报 unknown option |
| `ai_terminal/windows/flutter/CMakeLists.txt` | 按宿主选 `tool_backend.sh` / `tool_backend.bat` | Windows 模板硬编码 `.bat`，非 Windows 主机无法执行 |
| `ai_terminal/windows/runner/Runner.rc` | icon 路径反斜杠 → 正斜杠 | `windres` 在 POSIX 主机上把 `\` 当字面量 |
| `ai_terminal/windows/runner/Runner.rc` | 版本号改走 `AI_TERMINAL_RC_STRINGIFY` 数值拼接分支 | `windres` 调 cpp 时会再吃掉一层引号，`-DFLUTTER_VERSION=\"1.4.0+14\"` 展开成裸 token `1.4.0+14` → `RC:96: syntax error`。`rc.exe` 是单进程、没有这层，所以原生 Windows 构建不受影响 |
| `ai_terminal/windows/runner/CMakeLists.txt` | `if(MINGW)`：定义 `AI_TERMINAL_RC_STRINGIFY`、加 `target_link_options(-municode)` | Flutter runner 入口是 `wWinMain`（`main.cpp`），而 mingw 的 `-mwindows` 默认入口 `WinMainCRTStartup` 只找 `WinMain` → `undefined reference to WinMain`。`-municode` 切到 `wWinMainCRTStartup`，与 MSVC 一致 |
| `ai_terminal/windows/runner/security_util.cpp` | `ifstream/ofstream` 路径包 `std::filesystem::path` | `fstream(std::wstring)` 是 MSVC 扩展，libstdc++ 需要 `path` |
| `ai_terminal/pubspec.yaml` | 移除臆造的 `manualBuild` define | sqlite3 包只接受 `source`/`system` 等键；Windows 侧本来就有预编译的 `sqlite3mc.x64.windows.dll`，**不需要**从源码编译 |


## 五、pub cache 插件改动（`pub get` 后不会自动恢复）

| 文件 | 改动 |
|---|---|
| `local_auth_windows/windows/local_auth_stub.cpp`（新增） | 无 WinRT 桩实现，保留导出符号与 pigeon 协议 |
| `local_auth_windows/windows/CMakeLists.txt` | `if(NOT MSVC)` 分支编译上述桩并 `return()` |
| `flutter_secure_storage_windows/..._plugin.cpp` | ① `switch (static_cast<HRESULT>(...))` 修窄化 ② NTSTATUS case 标签显式转换 ③ `fstream` 路径包 `path` ④ 类内声明去掉多余类名限定 |
| `flutter_secure_storage_windows/windows/CMakeLists.txt` | 补 `version bcrypt`（源码只用 `#pragma comment(lib,...)`，GCC 忽略） |

**compat 转发头**（`tools/windows-cross/compat_include/`）—— 遇到新的 SDK/mingw
头名差异就往这里加一个：

- `ShlObj_core.h` → `#include <shlobj.h>`（mingw 未拆出独立文件）
- `atlstr.h` → `CA2W` / `CW2A` 等价实现（ATL 是 MSVC 专有，mingw 不带）

## 六、已知偏差

0. **`libwinpthread-1.dll` 必须随包发布。** exe 与 3 个插件 DLL 都动态引用
   它（libstdc++.a 内部就引用该 import lib，`-Wl,-Bstatic -lwinpthread
   -Wl,-Bdynamic` 实测压不住，产物照样 import）。CI 的 MSVC 包没有这个
   依赖，所以打包脚本要按构建方式分支：
   ```bash
   cp /usr/local/opt/mingw-w64/x86_64-w64-mingw32/bin/libwinpthread-1.dll \
      build/windows/x64/runner/
   ```
   漏了它 = exe 双击没反应直接起不来。
1. **`icudtl.dat`**：GCS 上 Windows 构建没有这个文件（`unpack_windows` 期望
   `artifacts/engine/windows-x64/icudtl.dat`）。已用同一 `engineRevision` 的
   `darwin-x64/icudtl.dat` 顶替（纯 ICU 数据文件，与目标架构无关）：
   ```bash
   cp $FLUTTER_ROOT/bin/cache/artifacts/engine/darwin-x64/icudtl.dat \
      $FLUTTER_ROOT/bin/cache/artifacts/engine/windows-x64/
   ```

2. **`local_auth_windows`（Windows Hello）**：其正式实现依赖 C++/WinRT、WIL、
   MSVC PPL（`ppltasks.h`）与 `UserConsentVerifierInterop.h`，mingw 一样都没有。
   交叉构建用桩替代，`IsDeviceSupported` 固定回 `false`，`app_lock.dart` 因此
   走「不支持 → 放行」分支，**应用锁功能在此 exe 上不可用**。
   交付前建议用 `--dart-define` 禁掉锁定入口的启用项，避免出现「可开启但不生效」。
3. **C++ 标准锁 17**：GCC 16 默认已是 gnu++20，会启用 libstdc++ 的
   `std::variant <=>` concepts 路径，而 Flutter 的 `EncodableValue` 比较运算符
   在那条路径下被判为约束自依赖 → 编译失败。

## 附录：`gen_snapshot` 包装器

存为 `flutter/bin/cache/artifacts/engine/windows-x64[-release|-profile]/gen_snapshot`
并 `chmod +x`：

```bash
#!/bin/bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
WINE="${FLUTTER_CROSS_WINE:-$HOME/opt/wine-stable/Wine Stable.app/Contents/Resources/wine/bin/wine}"
export WINEPREFIX="${FLUTTER_CROSS_WINEPREFIX:-$HOME/.wine-flutter}"
export WINEDEBUG=-all
export MVK_CONFIG_LOG_LEVEL=0
exec "$WINE" "$DIR/gen_snapshot.exe" "$@"
```

`MVK_CONFIG_LOG_LEVEL=0` / `WINEDEBUG=-all` 必须设：它们的日志会混进 flutter
的流式输出；而 `gen_snapshot` 自身的诊断（stderr）必须原样透传。
