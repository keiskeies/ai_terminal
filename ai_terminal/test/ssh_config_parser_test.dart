import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/ssh_config_parser.dart';

void main() {
  group('基础解析', () {
    test('最小 Host 块：别名即地址，默认端口 22', () {
      final r = parseSshConfig('Host web1\n  HostName 10.0.0.1\n  User deploy',
          homeDir: '/home/u');
      expect(r.entries, hasLength(1));
      final e = r.entries.single;
      expect(e.alias, 'web1');
      expect(e.host, '10.0.0.1');
      expect(e.port, 22);
      expect(e.username, 'deploy');
      expect(e.hasPrivateKey, isFalse);
      expect(r.warnings, isEmpty);
    });

    test('缺 HostName 时用别名作为地址', () {
      final r = parseSshConfig('Host 192.168.1.5\n  User root', homeDir: '/h');
      expect(r.entries.single.host, '192.168.1.5');
    });

    test('等号写法与引号值', () {
      final r = parseSshConfig(
        'Host=a\n  User="my user"\n  Port = 2222',
        homeDir: '/h',
      );
      expect(r.entries.single.alias, 'a');
      expect(r.entries.single.username, 'my user');
      expect(r.entries.single.port, 2222);
    });

    test('注释与空行忽略；值里的 # 不当注释', () {
      final r = parseSshConfig(
        '# comment\n\nHost a\n  User root  # 行尾注释\n  HostName h#1.example.com\n',
        homeDir: '/h',
      );
      expect(r.entries.single.username, 'root');
      expect(r.entries.single.host, 'h#1.example.com');
    });

    test('一行多个别名共享字段', () {
      final r = parseSshConfig(
        'Host web1 web2 web3\n  User deploy\n  HostName 10.0.0.%',
        homeDir: '/h',
      );
      expect(r.entries.map((e) => e.alias), ['web1', 'web2', 'web3']);
      expect(r.entries.every((e) => e.username == 'deploy'), isTrue);
    });
  });

  group('Host * 与合并语义', () {
    test('Host * 在前时其值对全部别名生效（OpenSSH 取先出现者）', () {
      final r = parseSshConfig(
        'Host *\n  User git\n  Port 2222\n\n'
        'Host web1\n  HostName 10.0.0.1\n\n'
        'Host web2\n  User admin\n  HostName 10.0.0.2',
        homeDir: '/h',
      );
      final web1 = r.entries.firstWhere((e) => e.alias == 'web1');
      expect(web1.username, 'git');
      expect(web1.port, 2222);
      // web2 自己写的 User 被更早的 Host * 遮蔽——这正是 OpenSSH 的实际行为
      final web2 = r.entries.firstWhere((e) => e.alias == 'web2');
      expect(web2.username, 'git');
      expect(
          r.warnings.any((w) => w.contains('web2') && w.contains('未生效')), isTrue);
    });

    test('Host * 在后时不覆盖具体块', () {
      final r = parseSshConfig(
        'Host web2\n  User admin\n  HostName 10.0.0.2\n\n'
        'Host *\n  User git',
        homeDir: '/h',
      );
      expect(r.entries.single.username, 'admin');
    });

    test('先出现者生效（OpenSSH 语义，非后者覆盖）', () {
      final r = parseSshConfig(
        'Host a\n  HostName first.example.com\n  User u1\n\n'
        'Host a\n  HostName second.example.com\n  User u2',
        homeDir: '/h',
      );
      final e = r.entries.firstWhere((e) => e.alias == 'a');
      expect(e.host, 'first.example.com');
      expect(e.username, 'u1');
      expect(r.warnings.any((w) => w.contains('未生效')), isTrue);
    });

    test('首个 Host 之前的全局指令作为所有主机缺省', () {
      final r = parseSshConfig(
        'User shared\nPort 2020\n\nHost a\n  HostName 1.2.3.4',
        homeDir: '/h',
      );
      expect(r.entries.single.username, 'shared');
      expect(r.entries.single.port, 2020);
    });

    test('通配模式不产出条目', () {
      final r = parseSshConfig('Host *.example.com\n  User x\n  HostName y',
          homeDir: '/h');
      expect(r.entries, isEmpty);
    });
  });

  group('ProxyJump / IdentityFile', () {
    test('ProxyJump 取首跳并去掉 user@', () {
      final r = parseSshConfig(
        'Host jump\n  HostName 1.1.1.1\n  User jumpuser\n\n'
        'Host inner\n  HostName 10.0.0.9\n  User app\n  ProxyJump deploy@jump',
        homeDir: '/h',
      );
      expect(r.entries.firstWhere((e) => e.alias == 'inner').proxyJump, 'jump');
    });

    test('IdentityFile 存在则判定为私钥认证', () {
      final r = parseSshConfig(
        'Host a\n  User u\n  IdentityFile ~/.ssh/id_ed25519',
        homeDir: '/home/u',
      );
      final e = r.entries.single;
      expect(e.hasPrivateKey, isTrue);
      expect(e.identityFile, '~/.ssh/id_ed25519');
    });

    test('多行 IdentityFile 保留首条', () {
      final r = parseSshConfig(
        'Host a\n  User u\n  IdentityFile ~/.ssh/first\n  IdentityFile ~/.ssh/second',
        homeDir: '/home/u',
      );
      expect(r.entries.single.identityFile, '~/.ssh/first');
    });
  });

  group('Include', () {
    test('展开被包含文件并保持先出现者生效', () {
      const main = 'Include conf.d/*\n\nHost a\n  HostName main.example.com\n  User u';
      final r = parseSshConfig(main, homeDir: '/home/u', includeResolver: (p, h) {
        expect(p, 'conf.d/*');
        return [
          const SshConfigIncludedFile(
              '/home/u/.ssh/conf.d/x.conf', 'Host a\n  HostName included.example.com\n  User iu')
        ];
      });
      final a = r.entries.firstWhere((e) => e.alias == 'a');
      expect(a.host, 'included.example.com');
      expect(a.username, 'iu');
    });

    test('未提供读取能力时只告警，不崩', () {
      final r = parseSshConfig('Include other\nHost a\n  User u', homeDir: '/h');
      expect(r.entries.single.alias, 'a');
      expect(r.warnings.any((w) => w.contains('Include')), isTrue);
    });

    test('未匹配到文件时告警', () {
      final r = parseSshConfig('Include missing/*\nHost a\n User u',
          homeDir: '/h', includeResolver: (p, h) => const []);
      expect(r.warnings.any((w) => w.contains('未匹配到文件')), isTrue);
    });
  });

  group('容错', () {
    test('缺 User 的主机跳过并告警', () {
      final r = parseSshConfig('Host a\n  HostName 1.2.3.4', homeDir: '/h');
      expect(r.entries, isEmpty);
      expect(r.warnings.any((w) => w.contains('User')), isTrue);
    });

    test('非法端口回退 22 并告警', () {
      final r = parseSshConfig('Host a\n  User u\n  Port abc', homeDir: '/h');
      expect(r.entries.single.port, 22);
      expect(r.warnings.any((w) => w.contains('Port')), isTrue);
    });

    test('Match 块之后的条件指令不归属到主机', () {
      final r = parseSshConfig(
        'Host a\n  User u\n  HostName 1.2.3.4\n\n'
        'Match host *.example.com exec"true"\n  User wrong',
        homeDir: '/h',
      );
      expect(r.entries.single.username, 'u');
      expect(r.warnings.any((w) => w.contains('Match')), isTrue);
    });

    test('无法解析的行只告警', () {
      final r = parseSshConfig('123 broken\nHost a\n  User u', homeDir: '/h');
      expect(r.entries.single.alias, 'a');
      expect(r.warnings.any((w) => w.contains('无法解析')), isTrue);
    });

    test('不支持的指令记入 ignoredKeys', () {
      final r = parseSshConfig(
        'Host a\n  User u\n  ServerAliveInterval 30\n  SetEnv FOO=bar',
        homeDir: '/h',
      );
      expect(r.entries.single.ignoredKeys, containsAll(['serveraliveinterval', 'setenv']));
    });

    test('空内容不报错', () {
      final r = parseSshConfig('', homeDir: '/h');
      expect(r.entries, isEmpty);
      expect(r.warnings, isEmpty);
    });
  });

  group('HostConfig 构造', () {
    test('私钥主机 authType=privateKey，其余 password', () {
      final r = parseSshConfig(
        'Host a\n  User u\n  IdentityFile ~/.ssh/id\n\nHost b\n  User u',
        homeDir: '/home/u',
      );
      final a = buildHostConfig(
          entry: r.entries.firstWhere((e) => e.alias == 'a'), id: 'id-a');
      expect(a.authType, 'privateKey');
      expect(a.name, 'a');
      expect(a.group, sshConfigImportGroup);
      final b = buildHostConfig(
          entry: r.entries.firstWhere((e) => e.alias == 'b'), id: 'id-b');
      expect(b.authType, 'password');
    });

    test('ProxyJump 落成 jumpHost，指向自身时不落', () {
      final r = parseSshConfig(
        'Host jump\n  HostName 1.1.1.1\n  User j\n\n'
        'Host inner\n  HostName 10.0.0.9\n  User app\n  ProxyJump jump\n\n'
        'Host self\n  HostName 2.2.2.2\n  User s\n  ProxyJump self',
        homeDir: '/h',
      );
      final inner = buildHostConfig(
          entry: r.entries.firstWhere((e) => e.alias == 'inner'), id: 'i');
      expect(inner.jumpHost, 'jump');
      expect(inner.hasJumpHost, isTrue);
      final self = buildHostConfig(
          entry: r.entries.firstWhere((e) => e.alias == 'self'), id: 's');
      expect(self.hasJumpHost, isFalse);
    });
  });

  group('真实配置文件形状', () {
    test('典型多主机配置全部解析', () {
      const text = '''
# 全局
Host *
  ServerAliveInterval 30
  StrictHostKeyChecking no
  IdentityFile ~/.ssh/id_ed25519

Host github
  HostName github.com
  User git

Host prod-*
  User deploy
  ProxyJump bastion

Host bastion
  HostName 203.0.113.10
  User admin
  Port 2200

Host prod-web1
  HostName 10.10.0.11

Host prod-web2
  HostName 10.10.0.12
  IdentityFile ~/.ssh/prod_rsa
''';
      final r = parseSshConfig(text, homeDir: '/home/u');
      expect(r.entries.map((e) => e.alias).toSet(),
          {'github', 'bastion', 'prod-web1', 'prod-web2'});
      final web1 = r.entries.firstWhere((e) => e.alias == 'prod-web1');
      expect(web1.username, 'deploy');
      expect(web1.proxyJump, 'bastion');
      expect(web1.identityFile, '~/.ssh/id_ed25519');
      expect(web1.hasPrivateKey, isTrue);
      // prod-web2 自己写的 IdentityFile 被更靠前的 Host * 遮蔽（OpenSSH 取先出现者）
      expect(r.entries.firstWhere((e) => e.alias == 'prod-web2').identityFile,
          '~/.ssh/id_ed25519');
      expect(
          r.warnings
              .any((w) => w.contains('prod-web2') && w.contains('未生效')),
          isTrue);
      expect(r.entries.firstWhere((e) => e.alias == 'bastion').port, 2200);
    });
  });
}
