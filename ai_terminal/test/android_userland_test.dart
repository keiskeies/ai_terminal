import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/android_userland.dart';

void main() {
  AndroidUserland userland({bool symlinkExec = false, bool bash = true}) =>
      AndroidUserland(
        libDir: '/data/app/x/lib/arm64',
        binDir: '/data/user/0/top.keiskei.ai_terminal/files/bin',
        bashPath: bash ? '/data/app/x/lib/arm64/libbash.so' : '',
        busyboxPath: '/data/app/x/lib/arm64/libbbmain.so',
        symlinkExec: symlinkExec,
      );

  group('shimmableApplets', () {
    test('排除会破坏语法或遮蔽内建的名字', () {
      final names = shimmableApplets();
      expect(names, isNot(contains('test')));
      expect(names, isNot(contains('time')));
      expect(names, isNot(contains('echo')));
      expect(names, isNot(contains('[')));
      for (final n in names) {
        expect(RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n), isTrue,
            reason: '$n 不是合法函数名');
      }
    });

    test('常用 applet 在列且不重复', () {
      final names = shimmableApplets();
      expect(names, containsAll(['ls', 'grep', 'sed', 'awk', 'tar', 'vi']));
      expect(names, equals(names.toSet().toList()..sort()));
    });
  });

  group('buildAndroidRc', () {
    test('每个 applet 生成 exec -a 转调 busybox 绝对路径的函数', () {
      final rc = buildAndroidRc(
        home: '/data/user/0/x/files',
        userland: userland(),
      );
      // busybox 按 argv[0] 选 applet，所以名字必须走 exec -a，不能当第一个参数。
      expect(
        rc,
        contains(r'''ls() { exec -a ls /data/app/x/lib/arm64/libbbmain.so "$@"; }'''),
      );
      // 不依赖环境变量：路径必须写在文件里。
      expect(rc, isNot(contains(r'$AI_BB')));
    });

    test('无 userland 时只剩提示符与 cd，不生成任何函数', () {
      final rc = buildAndroidRc(home: '/data/user/0/x/files', userland: null);
      expect(rc, isNot(contains('()')));
      expect(rc, contains('cd /data/user/0/x/files'));
    });

    test('sourceFirst 用 . 加载系统 rc，且吞掉其不存在的情况', () {
      final rc = buildAndroidRc(
        home: '/h',
        userland: userland(),
        sourceFirst: '/system/etc/mkshrc',
      );
      expect(rc, contains('[ -r /system/etc/mkshrc ] && . /system/etc/mkshrc'));
      expect(rc.indexOf('[ -r'), lessThan(rc.indexOf('ls()')));
    });

    test('提示符只用 bash/mksh 通用的展开形式', () {
      final rc = buildAndroidRc(home: '/h', userland: userland());
      final ps1 = rc.split('\n').firstWhere((l) => l.startsWith('export PS1'));
      // 反斜杠转义是 bash 扩展，mksh 会原样打印。
      expect(ps1, isNot(contains(r'\')));
      // 应用进程环境里通常没有 USER，会让提示符退化成 "@... $"。
      expect(ps1, isNot(contains(r'$USER')));
      expect(ps1, contains(r'$HOSTNAME'));
    });

    test('路径含单引号时被安全引用', () {
      final rc = buildAndroidRc(home: "/data/o'brien", userland: null);
      expect(rc, contains(r"cd '/data/o'\''brien'"));
    });
  });

  group('androidUserlandEnv', () {
    test('未探测到 userland 时什么都不加', () {
      expect(androidUserlandEnv(userland: null), isEmpty);
    });

    test('bin 目录只在符号链接可执行时进 PATH', () {
      expect(
        androidUserlandEnv(userland: userland())['PATH'],
        isNot(contains('/files/bin')),
      );
      final withLinks = androidUserlandEnv(userland: userland(symlinkExec: true));
      expect(withLinks['PATH'], startsWith('/data/user/0'));
      expect(withLinks['PATH'], contains('/system/bin'));
      expect(withLinks['LD_LIBRARY_PATH'], '/data/app/x/lib/arm64');
    });
  });

  group('AndroidUserland.hasBash', () {
    test('bash 探针缺失时不谎报可用', () {
      expect(userland().hasBash, isTrue);
      expect(userland(bash: false).hasBash, isFalse);
    });
  });

  group('androidShellLaunch', () {
    test('有 bash 时用 --rcfile 且不带 --login', () {
      // 登录 shell 会忽略 --rcfile，两者同时给等于静默丢掉 applet 函数。
      final launch = androidShellLaunch(
        userland: userland(),
        bashRcPath: '/h/.ai_terminal_bashrc',
      );
      expect(launch.shell, '/data/app/x/lib/arm64/libbash.so');
      expect(launch.args, ['--rcfile', '/h/.ai_terminal_bashrc']);
    });

    test('没有 bash 时回落 mksh', () {
      for (final u in [null, userland(bash: false)]) {
        final launch = androidShellLaunch(
          userland: u,
          bashRcPath: '/h/.ai_terminal_bashrc',
        );
        expect(launch.shell, '/system/bin/sh');
        expect(launch.args, ['-l']);
      }
    });

    test('rc 路径未就绪时不启动 bash', () {
      final launch = androidShellLaunch(
        userland: userland(),
        bashRcPath: null,
      );
      expect(launch.shell, '/system/bin/sh');
    });
  });

  group('provision 探针参数', () {
    test('busybox 探针必须伪装 argv[0]，不能把 applet 名当参数传', () async {
      // busybox 只按 argv[0] 派发。探针若写成 (bb, ['true'])，得到的是
      // "applet not found" rc=127 —— 看着像 exec 被拒，实际整条 userland
      // 被永久关掉，而且只在真机上暴露。
      final dir = Directory.systemTemp.createTempSync('userland_probe');
      final bb = '${dir.path}/libbbmain.so';
      File(bb).writeAsStringSync('stub');
      final calls = <List<String>>[];
      final prov = AndroidUserlandProvisioner(
        nativeLibraryDirProvider: () async => dir.path,
        execProbe: (path, args) async {
          calls.add([path, ...args]);
          return const ProbeResult(0, '');
        },
      );
      final res = await prov.provision(home: dir.path);
      expect(res, isNotNull);
      final busyboxCall = calls.firstWhere((c) => c.first.contains('libbbmain')
          || c.last.contains('libbbmain'));
      expect(busyboxCall.first, '/system/bin/sh');
      expect(busyboxCall, contains('exec -a true "\$0"'));
      expect(busyboxCall.last, bb);
      dir.deleteSync(recursive: true);
    });

    test('exec 被拒时返回 null，调用方回落 mksh', () async {
      final dir = Directory.systemTemp.createTempSync('userland_denied');
      File('${dir.path}/libbbmain.so').writeAsStringSync('stub');
      final prov = AndroidUserlandProvisioner(
        nativeLibraryDirProvider: () async => dir.path,
        execProbe: (path, args) async =>
            const ProbeResult(126, 'spawn: 13 Permission denied'),
      );
      expect(await prov.provision(home: dir.path), isNull);
      dir.deleteSync(recursive: true);
    });
  });
}
