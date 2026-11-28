import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Termux 预编译的 busybox/bash 随 jniLibs 打进 APK，只有装在应用原生库目录
/// 里的文件可执行：Android 10+（targetSdk>=29）拒绝 execve 应用自己数据目录
/// 里的 ELF，随 APK 安装、标签为 apk_data_file 的库目录是唯一的例外。
/// 桌面平台不会碰到这条路径。
class AndroidUserland {
  const AndroidUserland({
    required this.libDir,
    required this.binDir,
    required this.bashPath,
    required this.busyboxPath,
    required this.symlinkExec,
  });

  /// ELF 真身所在目录（ApplicationInfo.nativeLibraryDir），只读、可执行。
  final String libDir;

  /// 应用数据目录里的符号链接农场，仅在 [symlinkExec] 为真时可用。
  final String binDir;

  final String bashPath;
  final String busyboxPath;

  /// 运行时探针的结论：execve 经过应用数据目录里的符号链接是否被放行。
  /// 为假时不进 PATH，命令名全靠 shell 函数垫片，不依赖这个结论。
  final bool symlinkExec;

  bool get hasBash => bashPath.isNotEmpty;
}

/// 要暴露给用户的 busybox applet。刻意不含 shell 内建（echo/printf/pwd/test
/// 之类）——它们定义成函数会遮蔽内建甚至直接语法报错，而内建本来就更快。
const List<String> kAndroidApplets = [
  'ls', 'cat', 'tac', 'head', 'tail', 'wc', 'sort', 'uniq', 'tr', 'cut',
  'paste', 'comm', 'nl', 'rev', 'od', 'hexdump', 'strings', 'split',
  'md5sum', 'sha1sum', 'sha256sum', 'base64', 'uuencode', 'uudecode',
  'find', 'grep', 'egrep', 'sed', 'awk', 'xargs', 'basename', 'dirname',
  'realpath', 'readlink', 'mkdir', 'rmdir', 'mktemp', 'touch', 'stat',
  'ln', 'mv', 'cp', 'rm', 'chmod', 'chown', 'chgrp', 'du', 'df', 'sync',
  'tar', 'gzip', 'gunzip', 'bzip2', 'xz', 'zip', 'unzip', 'ar',
  'ps', 'kill', 'pkill', 'top', 'killall', 'env', 'printenv', 'which',
  'nohup', 'timeout', 'yes', 'seq', 'expr', 'date', 'sleep', 'watch',
  'logger', 'id', 'whoami', 'users', 'uname', 'uptime', 'free', 'vmstat',
  'mount', 'umount', 'dd', 'tee',
  'vi', 'less', 'more',
];

/// 定义成 shell 函数会破坏语法或遮蔽内建的 applet。
const Set<String> kReservedAppletNames = {
  'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'while', 'until',
  'for', 'in', 'do', 'done', 'function', 'select', 'time', 'coproc',
  'test', 'local', 'declare', 'typeset', 'export', 'eval', 'exec', 'set',
  'unset', 'alias', 'ulimit', 'wait', 'jobs', 'fg', 'bg', 'getopts',
  'shift', 'read', 'echo', 'printf', 'pwd', 'true', 'false', 'command',
  'type', 'hash', 'trap', 'times', 'break', 'continue', 'return', 'source',
  '[', '[[', ':', '!',
};

/// 只保留能安全定义成函数的名字。
@visibleForTesting
List<String> shimmableApplets() {
  final seen = <String>{};
  for (final name in kAndroidApplets) {
    if (!_isSafeFunctionName(name)) continue;
    seen.add(name);
  }
  return seen.toList()..sort();
}

bool _isSafeFunctionName(String name) {
  if (kReservedAppletNames.contains(name)) return false;
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
}

/// 生成 bash/mksh 通用的 rc 片段：把 applet 定义成转调 busybox 的函数。
///
/// busybox 路径直接写进文件而不是靠环境变量传：少一环传递就少一处可能
/// 失配的地方，而且 rc 内容因此完全可预测、可单测。
///
/// 为什么不用 PATH：PATH 要能命中可执行文件，而应用数据目录里的符号链接
/// （甚至 `#!` 包装脚本）本身就要过内核的 file:execute 检查——Android 10+
/// 只放行 apk_data_file。函数走的是 shell 已解析出的绝对路径，execve 的
/// 目标就是 nativeLibraryDir 里的真身，落在被放行的标签上。
String buildAndroidRc({
  required String home,
  required AndroidUserland? userland,
  String? sourceFirst,
}) {
  final buf = StringBuffer('# 由 AI Terminal 生成，勿手改\n');
  if (sourceFirst != null) {
    // 取代系统 rc 时必须先把它加载回来，否则连提示符都会丢。用 `.` 而不是
    // 直接执行：读取应用数据目录允许，execve 才受限。用可读性判断而不是
    // 把 `.` 的 stderr 丢掉——那会连被 source 脚本自己的报错一起吞掉。
    final q = _shQuote(sourceFirst);
    buf.writeln('[ -r $q ] && . $q');
  }
  final bb = userland?.busyboxPath ?? '';
  if (bb.isNotEmpty) {
    for (final name in shimmableApplets()) {
      // busybox 是 multi-call：靠 argv[0] 选 applet，实测给它传 applet 名
      // 参数只会回 "applet not found"。exec -a 在 mksh 和 bash 里都可用。
      //
      // 必须套一层子 shell。函数里不加 exec 的话，busybox 的绝对路径会占掉
      // $0 传给 applet；加了 exec 又不套子 shell，替换掉的就是 shell 自己：
      // 输出一条 ls 之后 shell 进程就没了，终端表现为「随便敲个命令就断连」。
      // 子 shell 里 exec 只替换那一层，退出码照常往上传，marker 协议不受影响。
      buf.writeln('$name() { ( exec -a $name ${_shQuote(bb)} "\$@" ); }');
    }
    buf.writeln(r"alias ll='ls -l'");
    buf.writeln(r"alias la='ls -a'");
  }
  // 只用 bash/mksh 都认的写法：反斜杠转义（\u \w）是 bash 扩展，落到 mksh
  // 回退路径上会原样印出 "\u@ai-terminal:\w\$"，比系统提示符还差。
  // 单引号里的 $VAR 两个 shell 都在每次绘制提示符时展开。$USER 在应用进程
  // 的环境里通常不存在，HOSTNAME 由 start() 兜底写入，所以只依赖后者。
  buf.writeln(r"export PS1='$HOSTNAME:$PWD $ '");
  buf.writeln('cd ${_shQuote(home)} 2>/dev/null || true');
  return buf.toString();
}

/// 一次性命令（runOnce）用的 POSIX shell。
///
/// Android 上没有 `/bin/sh`——真机实测那里不存在，系统的 mksh 在
/// `/system/bin/sh`。原先写死 `/bin/sh`，spawn 直接抛 ProcessException，
/// 上层按「失败返回空串」吞掉，监控面板于是永远拿不到数据：错误被翻译成了
/// 一个看起来只是「还没数据」的界面，这才是它难查的原因。
///
/// 桌面端保留 `/bin/sh`，探测不到时退回裸 `sh` 让 PATH 去解析。
String posixShForRunOnce({required bool isAndroid}) {
  if (isAndroid) return '/system/bin/sh';
  return File('/bin/sh').existsSync() ? '/bin/sh' : 'sh';
}

/// 系统命令目录，按可用优先级排。
const List<String> kAndroidSystemBinDirs = [
  '/system/bin',
  '/system/xbin',
  '/system_ext/bin',
  '/product/bin',
  '/vendor/bin',
];

/// 把系统命令目录补进现有 PATH（缺啥补啥，保留原有条目与顺序）。
String androidSystemBinPath(String existingPath) {
  final parts = existingPath
      .split(':')
      .where((p) => p.trim().isNotEmpty)
      .toList(growable: true);
  for (final dir in kAndroidSystemBinDirs) {
    if (!parts.contains(dir)) parts.add(dir);
  }
  return parts.join(':');
}

String _shQuote(String value) {
  if (value.isEmpty) return "''";
  final safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value);
  return safe ? value : "'${value.replaceAll("'", r"'\''")}'";
}

/// 供 [ProcessStartInfo] 用的环境变量补丁。
///
/// LD_LIBRARY_PATH 只是加一层保险：库本身已靠 RUNPATH=$ORIGIN 定位，这正是
/// 打包脚本改写 RUNPATH 的原因——不依赖任何环境变量也能加载。
Map<String, String> androidUserlandEnv({
  required AndroidUserland? userland,
}) {
  if (userland == null) return const {};
  final path = <String>[
    if (userland.symlinkExec) userland.binDir,
    '/system/bin',
    '/system/xbin',
    '/system_ext/bin',
    '/product/bin',
    '/vendor/bin',
  ];
  return {
    'PATH': path.join(':'),
    'LD_LIBRARY_PATH': userland.libDir,
  };
}

/// Android 上交互终端要起的 shell。
///
/// 系统里只有 `/system/bin/sh`（mksh），没有 `/bin/bash`/`/bin/zsh`，所以
/// 桌面端那套 `existsSync` 探测在这里全为 false，必须单独决定。
///
/// 有 userland 时用随 APK 打进 nativeLibraryDir 的 bash，rc 走
/// [androidBashRcPath]（那里定义 busybox applet 的转调函数）；否则回落
/// `/system/bin/sh -l`，登录模式读系统 profile。
///
/// 刻意不带 `--login`：bash 的登录 shell 只读 profile 系列文件，`--rcfile`
/// 会被忽略；而 stdin 是 PTY 时它本来就是交互 shell，正好读 rcfile。
AndroidShellLaunch androidShellLaunch({
  required AndroidUserland? userland,
  required String? bashRcPath,
}) {
  if (userland != null && userland.hasBash && bashRcPath != null) {
    return AndroidShellLaunch(
        shell: userland.bashPath, args: ['--rcfile', bashRcPath]);
  }
  return const AndroidShellLaunch(shell: '/system/bin/sh', args: ['-l']);
}

class AndroidShellLaunch {
  const AndroidShellLaunch({required this.shell, required this.args});

  final String shell;
  final List<String> args;
}

/// bash 的 rc。放 HOME 下：只有应用自己能读写，且 shell 读文件不受
/// file:execute 限制（受限的是 execve）。
String androidBashRcPath(String home) => '$home/.ai_terminal_bashrc';

String androidMkshRcPath(String home) => '$home/.ai_terminal_mkshrc';

/// 探测 + 组装。全部失败时返回 null，调用方回落到 /system/bin/sh。
class AndroidUserlandProvisioner {
  AndroidUserlandProvisioner({
    Future<String?> Function()? nativeLibraryDirProvider,
    Future<ProbeResult> Function(String path, List<String> args)? execProbe,
  })  : _nativeLibraryDirProvider =
            nativeLibraryDirProvider ?? _queryNativeLibraryDir,
        _execProbe = execProbe ?? _runProbe;

  final Future<String?> Function() _nativeLibraryDirProvider;
  final Future<ProbeResult> Function(String, List<String>) _execProbe;

  static const _paths = MethodChannel('com.keiskei.aiterminal/paths');

  static Future<String?> _queryNativeLibraryDir() async {
    try {
      return await _paths.invokeMethod<String>('nativeLibraryDir');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<ProbeResult> _runProbe(String path, List<String> args) async {
    try {
      final res = await Process.run(path, args);
      // 退出码非 0 与 execve 被拒是两件不同的事，光看 bool 分不出来：
      // 前者是跑起来了但行为不对（缺库、argv[0] 不认），后者是压根没跑。
      return ProbeResult(res.exitCode, res.stderr.toString().trim());
    } on ProcessException catch (e) {
      // execve 被 SELinux 拒了会走到这里（EACCES），是预期分支不是崩溃。
      return ProbeResult(126, 'spawn: ${e.errorCode} ${e.message}');
    }
  }

  /// 探测这台设备上的 userland 是否可用；返回 null 时调用方回落到
  /// /system/bin/sh。rc 文件由调用方写：它才知道 bash 和 mksh 各要什么。
  Future<AndroidUserland?> provision({required String home}) async {
    final libDir = await _nativeLibraryDirProvider();
    if (libDir == null || libDir.isEmpty) {
      debugPrint('[AndroidUserland] 拿不到 nativeLibraryDir，回落到 /system/bin/sh');
      return null;
    }
    final bb = '$libDir/libbbmain.so';
    if (!File(bb).existsSync()) {
      // useLegacyPackaging 没生效时库留在 APK 内，这里就会看不见。
      debugPrint('[AndroidUserland] $bb 不在磁盘上（未解包？）');
      return null;
    }

    // 探针跑真正的目标：launcher 加它自己的依赖解析。argv[0] 必须伪装成
    // applet 名——busybox 只按 argv[0] 派发，直接 exec 时它叫 libbbmain.so，
    // 回的是 "applet not found"（rc=127），那是查找失败不是 exec 被拒。
    // 借 mksh 的 `exec -a`：$0 就是路径，不经字符串插值，无引号可注入。
    final probe = await _execProbe('/system/bin/sh', ['-c', r'exec -a true "$0"', bb]);
    if (!probe.ok) {
      debugPrint('[AndroidUserland] busybox 探针 rc=${probe.exitCode} '
          '${probe.detail} —— 回落到 /system/bin/sh');
      return null;
    }

    final bash = '$libDir/libbash.so';
    final bashProbe = File(bash).existsSync()
        ? await _execProbe(bash, ['--noediting', '-c', 'true'])
        : const ProbeResult(-1, '文件不存在');
    if (!bashProbe.ok) {
      debugPrint('[AndroidUserland] bash 探针 rc=${bashProbe.exitCode} '
          '${bashProbe.detail}');
    }

    final binDir = '$home/bin';
    final linkProbe = await _linkFarm(binDir: binDir, busybox: bb);
    // 真机判定全靠这一行 logcat：bash 能否 exec、符号链接能否 exec 都只有
    // 设备知道，桌面侧无法验证。
    debugPrint('[AndroidUserland] $libDir bash=${bashProbe.ok} '
        'symlink=${linkProbe.result}(${linkProbe.exitCode}) '
        '${linkProbe.result ? '' : linkProbe.detail}');
    final userland = AndroidUserland(
      libDir: libDir,
      binDir: binDir,
      bashPath: bashProbe.ok ? bash : '',
      busyboxPath: bb,
      symlinkExec: linkProbe.result,
    );
    return userland;
  }

  /// 铺 `$HOME/bin` 符号链接，并用其中一个自证 execve 是否放行。
  /// 内核沿符号链接解析后按**目标 inode** 的标签判定，目标在
  /// nativeLibraryDir，所以有可能放行；未放行时返回 false，函数垫片接管。
  ///
  /// 链接名即 applet 名，argv[0] 的 basename 正好是 busybox 要的 applet，
  /// 所以这条路比函数垫片更干净（少一层 shell 函数、少一份进程）。
  Future<_LinkProbe> _linkFarm({
    required String binDir,
    required String busybox,
  }) async {
    // 探针必须用真 applet 名：链接叫 `bbtest` 时 busybox 回
    // "bbtest: applet not found"，那是 applet 查找失败，不是 exec 被拒。
    const probeName = 'true';
    final probeLink = '$binDir/$probeName';
    try {
      await Directory(binDir).create(recursive: true);
      final link = Link(probeLink);
      if (link.existsSync()) await link.delete();
      await link.create(busybox);
      final via = await _execProbe(probeLink, const []);
      if (!via.ok) return _LinkProbe(false, via.exitCode, via.detail);
      for (final name in shimmableApplets()) {
        final l = Link('$binDir/$name');
        try {
          if (l.existsSync()) await l.delete();
          await l.create(busybox);
        } on FileSystemException {
          // 个别名字在某些文件系统上不被允许，函数垫片仍然覆盖它们。
        }
      }
      return const _LinkProbe(true, 0, '');
    } on FileSystemException catch (e) {
      return _LinkProbe(false, -1, 'link: ${e.osError}');
    } finally {
      try {
        final l = Link(probeLink);
        if (l.existsSync()) await l.delete();
      } on FileSystemException {
        // 探针链接没删掉不影响功能，下次 provision 会先删再建。
      }
    }
  }
}

/// 一次 exec 探测的结果。
class ProbeResult {
  const ProbeResult(this.exitCode, this.detail);
  final int exitCode;
  final String detail;
  bool get ok => exitCode == 0;
}

class _LinkProbe {
  const _LinkProbe(this.result, this.exitCode, this.detail);
  final bool result;
  final int exitCode;
  final String detail;
}
