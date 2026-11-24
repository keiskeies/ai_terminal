import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/ssh_config_import_service.dart';
import 'package:ai_terminal/utils/ssh_config_parser.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ssh_config_import_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String write(String rel, String content) {
    final f = File('${tmp.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f.path;
  }

  group('配置文件读取', () {
    test('缺失文件：exists=false 且无 readError', () async {
      final s = await SshConfigImportService.load(
          overridePath: '${tmp.path}/nope/config');
      expect(s.exists, isFalse);
      expect(s.isReadable, isFalse);
      expect(s.readError, isNull);
    });

    test('存在则返回内容', () async {
      final path = write('config', 'Host a\n  User u\n  HostName 1.2.3.4');
      final s = await SshConfigImportService.load(overridePath: path);
      expect(s.isReadable, isTrue);
      expect(s.content, contains('Host a'));
    });

    test('默认路径落在 ~/.ssh/config', () {
      final p = SshConfigImportService.defaultConfigPath();
      if (p == null) return; // 环境无 HOME/USERPROFILE
      expect(
          p,
          endsWith(
              '${Platform.pathSeparator}.ssh${Platform.pathSeparator}config'));
    });
  });

  group('Include 展开（真实文件系统）', () {
    test('Include 目录内文件按文件名排序读取', () {
      final cfg = write('cfg/config',
          'Include conf.d\n\nHost b\n  User bu\n  HostName 9.9.9.9');
      write('cfg/conf.d/2-b.conf', 'Host two\n  User t2\n  HostName 8.8.8.2');
      write('cfg/conf.d/1-a.conf', 'Host one\n  User t1\n  HostName 8.8.8.1');

      final result = SshConfigImportService.parse(
        File(cfg).readAsStringSync(),
        dirOfConfig: '${tmp.path}/cfg',
      );
      expect(result.entries.map((e) => e.alias).toSet(), {'one', 'two', 'b'});
    });

    test('Include 通配只取匹配项', () {
      final cfg = write('cfg/config', 'Include hosts/*.conf\n');
      write(
          'cfg/hosts/included.conf', 'Host yes\n  User u\n  HostName 1.1.1.1');
      write('cfg/hosts/skipped.txt', 'Host no\n  User u\n  HostName 2.2.2.2');

      final result = SshConfigImportService.parse(
        File(cfg).readAsStringSync(),
        dirOfConfig: '${tmp.path}/cfg',
      );
      expect(result.entries.map((e) => e.alias), ['yes']);
    });

    test('Include 指向不存在的模式时告警但不抛', () {
      final result = SshConfigImportService.parse(
        'Include missing/*.conf\n\nHost a\n  User u\n  HostName 3.3.3.3',
        dirOfConfig: tmp.path,
      );
      expect(result.entries.single.alias, 'a');
      expect(result.warnings.any((w) => w.contains('Include')), isTrue);
    });
  });

  group('重复判定', () {
    HostConfig existing(String host, int port) => HostConfig.create(
          id: 'x',
          name: host,
          host: host,
          username: 'u',
          authType: 'password',
          port: port,
        );

    SshConfigEntry entry(String host, int port) => SshConfigEntry(
          alias: 'a',
          host: host,
          port: port,
          username: 'u',
        );

    test('同 host:port 判重（大小写不敏感）', () {
      expect(
          SshConfigImportService.isDuplicate(entry('WEB1.Example.com', 22),
              [existing('web1.example.com', 22)]),
          isTrue);
    });

    test('端口不同不算重复', () {
      expect(
          SshConfigImportService.isDuplicate(
              entry('web1', 2222), [existing('web1', 22)]),
          isFalse);
    });

    test('空列表不判重', () {
      expect(SshConfigImportService.isDuplicate(entry('web1', 22), const []),
          isFalse);
    });
  });
}
