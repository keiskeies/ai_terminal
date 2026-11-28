# 内置 Android userland 出处与许可

<!-- generated: 由 tool/prepare_android_userland.py 覆写，勿手改 -->

- 归档时间：2026-11-28 08:53:34 UTC
- 来源仓库：https://packages.termux.dev/apt/termux-main（Termux 官方 apt 源，dists/stable/main）
- 目标 ABI：arm64-v8a
- 合计 4.03 MiB（解包后）

| 包 | 版本 | 随包文件名 | deb SHA256 | 许可 |
|---|---|---|---|---|
| busybox | 1.38.0-1 | `libbbmain.so`, `libbb.so` | `1bb7f1d4c00cadd0e1117b6dd7110311b8bf749ef00b486e96cfdc11c98f8fd9` | GPL-2.0 |
| libandroid-selinux | 14.0.0.11-2 | `libandroid-selinux.so` | `bd12262a7adbad8b827a9ac9d43576e9eb5ecf419abb5ba4cc4ba48a20b6b7b7` | Public Domain |
| pcre2 | 10.49 | `libpcre2-8.so` | `c27995e5f52b8ecc9b8b3e662eb08e49f82a18bfd3f34343936acc7b23964724` | BSD-3-Clause WITH PCRE2-exception |
| bash | 5.3.20 | `libbash.so` | `26b5b3ab5b0ac0e3b372ac1e7ddd89270519c1eb25b88fe4175485c2de8086b2` | GPL-3.0 |
| libandroid-support | 29-1 | `libandroid-support.so` | `f2f145d6135ad4843ac9670153be3e3944dc1e6f1736d46d2306c28f2b86f517` | MIT |
| readline | 8.3.6 | `libreadline8.so` | `616cc73009bc0223f61caed8dd09455714455aa5ea5e180126e2f69c4c775136` | GPL-3.0 |
| ncurses | 6.6.20260307+really6.5.20250830 | `libncursesw6.so` | `f44bbfdc3d42ec0217bffa978309390e59cea5a48a9a83226d4a496c42ad0b99` | MIT |
| libiconv | 1.19.1 | `libiconv.so` | `a1c6323eff4f660e16ae6f5832356444b3269c19a4f61146355a49e7c4be5ed1` | GPL-3.0 / LGPL-2.1 |

改写内容（见 tool/prepare_android_userland.py 文档字符串里的长度不变量）：

* `DT_RUNPATH` 指到 `$ORIGIN`，`DT_NEEDED`/`DT_SONAME` 换成 `lib*.so` 形式；
* bash 的 `.rodata` 里两个 Termux rc 路径改指向不存在的文件，
  否则每个提示符都会重复一行 `Permission denied`。

本文件按 ABI 分节，以上列出的就是随 APK 分发的全部 ABI。没打到的架构
（如 32 位 armeabi-v7a）探测不到可执行程序，运行时会回落到
`/system/bin/sh`；补一个 ABI 只要 `--arch arm`，代价是 universal APK 里
多约 4 MiB（CI 用 `flutter build apk`，不做 ABI 分包）。

## GPL 源码获取

busybox（GPL-2.0）、bash 与 readline（GPL-3.0）、libiconv（LGPL-2.1/GPL-3.0
双许可）以二进制形式随 APK 分发。对应源码按上表版本号从 Termux 构建链获取：

* 打包配方与补丁：<https://github.com/termux/termux-packages/tree/master/packages>
* 上游原始 tarball 版本与上表一致（busybox.net、gnu.org/software/bash 等）。

本仓库如需移除该目录，整棵 `jniLibs/` 连同本文件一起删掉即可；运行时会探测
失败并回落到 `/system/bin/sh`，终端功能不受影响。
