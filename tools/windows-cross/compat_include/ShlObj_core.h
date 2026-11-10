// Windows SDK 的 ShlObj_core.h 在 mingw-w64 里没有独立文件 —— 相关接口
// 已并入 shlobj.h。此转发头仅解决「文件名大小写/拆分方式不同」的编译差异。
#ifndef AI_TERMINAL_COMPAT_SHLOBJ_CORE_H_
#define AI_TERMINAL_COMPAT_SHLOBJ_CORE_H_
#include <shlobj.h>
#endif
