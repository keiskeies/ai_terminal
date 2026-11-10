# MinGW-w64 交叉工具链 —— 在 macOS 上构建 Flutter Windows 桌面包
#
# 用法（配合 flutter_tools 的交叉构建开关）：
#   export FLUTTER_CROSS_BUILD_WINDOWS=1
#   export FLUTTER_CROSS_TOOLCHAIN=<repo>/tools/windows-cross/mingw-toolchain.cmake
#   flutter build windows --release
#
# 前置：
#   brew install mingw-w64          # 提供 x86_64-w64-mingw32-gcc / 完整 Win32 导入库
#   flutter precache --all-platforms # 拉取 windows-x64* 引擎（含 gen_snapshot.exe）
#   安装 Wine（见 tools/windows-cross/README.md）
#
# 注意：sysroot 不在这里显式指定 —— brew 的 mingw-w64 用相对路径
# (../../../../x86_64-w64-mingw32/include) 定位头文件与库，编译器自定位即可。

cmake_minimum_required(VERSION 3.14)

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

# Intel mac 在 /usr/local，Apple Silicon 在 /opt/homebrew
if(NOT DEFINED MINGW_ROOT)
  if(EXISTS "/usr/local/opt/mingw-w64/bin")
    set(MINGW_ROOT "/usr/local/opt/mingw-w64")
  elseif(EXISTS "/opt/homebrew/opt/mingw-w64/bin")
    set(MINGW_ROOT "/opt/homebrew/opt/mingw-w64")
  else()
    message(FATAL_ERROR "找不到 brew mingw-w64（需 brew install mingw-w64）")
  endif()
endif()

set(CMAKE_C_COMPILER   "${MINGW_ROOT}/bin/x86_64-w64-mingw32-gcc")
set(CMAKE_CXX_COMPILER "${MINGW_ROOT}/bin/x86_64-w64-mingw32-g++")
set(CMAKE_RC_COMPILER  "${MINGW_ROOT}/bin/x86_64-w64-mingw32-windres")

# 只在 Windows 侧找库/头/包；程序仍在宿主机上跑（cmake/make 是 mac 的）
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM   NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY   ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE   ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE   ONLY)

# 静态链接 C++ 运行时，避免产物还要带 libgcc/libstdc++-6.dll（CI 上的 Windows
# 包自带的 runner 不会拷这两个 DLL，缺了会直接起不来）。
#
# 不加会踩这个坑：宽字符版 fstream::open 的实现只在静态库里（DLL 不导出），
# 于是 flutter_secure_storage_windows 链接报
#   undefined reference to `std::__basic_file<char>::open(wchar_t const*, std::_Ios_Openmode)'
#
# 必须走 *_LINKER_FLAGS_INIT，**不要**去 set(CMAKE_CXX_STANDARD_LIBRARIES)：
# 后者是编译器探测阶段写进 cache 的（默认 -lkernel32 … -luuid … 那一串），
# 工具链文件解析时它还是空值 —— 普通 set() 会被 cache 盖掉（静态标志丢失），
# 改成 CACHE ... FORCE 又会把默认那串整体覆盖掉（丢 -luuid → 下一个错变成
# undefined reference to `FOLDERID_RoamingAppData'）。
# *_LINKER_FLAGS_INIT 是官方给工具链文件用的初始化钩子：只播种
# CMAKE_<TYPE>_LINKER_FLAGS，与标准库列表互不干扰。
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-static-libgcc -static-libstdc++")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")

# 显式锁 C++17：GCC 16 默认标准已是 gnu++20，会启用 libstdc++ 的
# std::variant <=> _Synth3way/concepts 路径，而 Flutter 的 EncodableValue
# 的比较运算符在那条路径下被判定为约束自依赖（"constraint depends on
# itself"）→ 编译失败。C++17 下 variant 比较走另一套实现，问题不触发。
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Windows SDK 与 mingw-w64 的头文件拆分/命名差异（如 SDK 的 ShlObj_core.h
# 在 mingw 里并入了 shlobj.h）。转发头统一放在这里，遇到新的就补一个。
get_filename_component(_CROSS_ROOT "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
set(_CROSS_COMPAT "${_CROSS_ROOT}/compat_include")
set(CMAKE_C_STANDARD_INCLUDE_DIRECTORIES   "${_CROSS_COMPAT}")
set(CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES "${_CROSS_COMPAT}")
