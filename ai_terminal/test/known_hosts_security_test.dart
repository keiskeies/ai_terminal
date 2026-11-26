import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_terminal/core/security/known_hosts_service.dart';
import 'package:ai_terminal/core/security/ssh_host_key_policy.dart';
import 'package:ai_terminal/core/security/ssh_host_key_store.dart';
import 'package:ai_terminal/core/security/ssh_host_key_verifier.dart';
import 'package:ai_terminal/models/ssh_host_key.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _publicKey(String type, {int fill = 1}) {
  final typeBytes = utf8.encode(type);
  final bytes = <int>[
    ...(ByteData(4)..setUint32(0, typeBytes.length)).buffer.asUint8List(),
    ...typeBytes,
    ...List<int>.filled(32, fill),
  ];
  return base64.encode(bytes);
}

String _hashedAlias(String host, {int fill = 2}) {
  final salt = List<int>.filled(20, fill);
  final hash = Hmac(sha1, salt).convert(utf8.encode(host)).bytes;
  String encode(List<int> value) => base64.encode(value).replaceAll('=', '');
  return '|1|${encode(salt)}|${encode(hash)}';
}

SshHostKey _manual({String? publicKey}) => SshHostKeyPolicy.newTrust(
      routeKey: SshHostKeyPolicy.directRoute,
      alias: 'manual.example.com',
      keyType: 'ssh-ed25519',
      fingerprintSha256:
          'SHA256:${base64.encode(List<int>.filled(32, 9)).replaceAll('=', '')}',
      source: SshHostKeySource.userConfirmed,
    ).copyWith(publicKeyBase64: publicKey);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SshHostKeyStore store;
  late KnownHostsService service;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await db.execute(sshHostKeysCreateSql);
    store = SshHostKeyStore(databaseOverride: db);
    service = KnownHostsService(store);
  });

  tearDown(() async {
    SshHostKeyPromptService.setHandler(null);
    await db.close();
  });

  test('解析普通地址、非默认端口、多地址与 RSA SHA-2', () {
    final rsa = _publicKey('ssh-rsa');
    final parsed = service.parse(
      'Example.com,[example.com]:2222 ssh-ed25519 ${_publicKey('ssh-ed25519')}\n'
      'rsa.example.com ssh-rsa $rsa # comment\n'
      'broken line\n',
    );
    expect(parsed.entries, hasLength(4));
    expect(parsed.entries.map((entry) => entry.alias), [
      'example.com',
      'example.com:2222',
      'rsa.example.com',
      'rsa.example.com'
    ]);
    expect(parsed.entries.last.keyType, 'rsa-sha2-512');
    expect(parsed.entries.every((entry) => !entry.isHashed), isTrue);
    expect(parsed.issues.single.line, 3);
  });

  test('hashed known_hosts 匹配明文地址并支持无 padding 编码', () async {
    final alias = _hashedAlias('server.example.com');
    final content = '$alias ssh-ed25519 ${_publicKey('ssh-ed25519')}\n';
    final preview =
        await service.preview(content, routeKey: SshHostKeyPolicy.directRoute);
    expect(preview.items.single.action, KnownHostsAction.add);
    expect(preview.items.single.entry.isHashed, isTrue);

    final result = await service.import(content,
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {preview.items.single.entry.id});
    expect(result.added, 1);
    final prompts = <SshHostKeyRequest>[];
    final verifier = SshHostKeyVerifier(
      store: store,
      prompt: (request) async {
        prompts.add(request);
        return const SshHostKeyPromptResponse.reject();
      },
    );
    final publicKey = base64.decode(_publicKey('ssh-ed25519'));
    final fingerprint =
        'SHA256:${base64.encode(sha256.convert(publicKey).bytes).replaceAll('=', '')}';
    expect(
      await verifier.verify(
        alias: 'server.example.com',
        routeKey: SshHostKeyPolicy.directRoute,
        routeLabel: 'server.example.com:22',
        keyType: 'ssh-ed25519',
        fingerprint: fingerprint,
        isJumpHost: false,
      ),
      isTrue,
    );
    expect(prompts, isEmpty);
  });

  test('导入预览区分新增、一致与冲突，只写入选中的新增记录', () async {
    final first =
        'one.example.com ssh-ed25519 ${_publicKey('ssh-ed25519', fill: 1)}';
    final same =
        'same.example.com ssh-ed25519 ${_publicKey('ssh-ed25519', fill: 2)}';
    final conflict =
        'same.example.com ssh-ed25519 ${_publicKey('ssh-ed25519', fill: 3)}';
    final initial = await service.preview('$same\n',
        routeKey: SshHostKeyPolicy.directRoute);
    await service.import('$same\n',
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {initial.items.single.entry.id});

    final preview = await service.preview('$first\n$same\n$conflict\n',
        routeKey: SshHostKeyPolicy.directRoute);
    expect(preview.items.map((item) => item.action), [
      KnownHostsAction.add,
      KnownHostsAction.unchanged,
      KnownHostsAction.conflict,
    ]);
    final result = await service.import('$first\n$same\n$conflict\n',
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {for (final item in preview.items) item.entry.id});
    expect(result.added, 1);
    expect(result.skipped, 0, reason: '未选中的 unchanged/conflict 不进入写入集合');
    expect(await store.getAll(), hasLength(2));
  });

  test('@revoked 导入后直接拒绝，普通信任可被同指纹撤销但不能被冲突覆盖', () async {
    final key = _publicKey('ssh-ed25519', fill: 4);
    final trusted = 'revoke.example.com ssh-ed25519 $key';
    final initial = await service.preview('$trusted\n',
        routeKey: SshHostKeyPolicy.directRoute);
    await service.import('$trusted\n',
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {initial.items.single.entry.id});

    final revoked = '@revoked revoke.example.com ssh-ed25519 $key';
    final preview = await service.preview('$revoked\n',
        routeKey: SshHostKeyPolicy.directRoute);
    expect(preview.items.single.action, KnownHostsAction.revoke);
    await service.import('$revoked\n',
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {preview.items.single.entry.id});
    final saved = (await store.getAll()).single;
    expect(saved.status, SshHostKeyStatus.revoked);

    var prompts = 0;
    final verifier = SshHostKeyVerifier(
      store: store,
      prompt: (_) async {
        prompts++;
        return const SshHostKeyPromptResponse.accept(replaceExisting: true);
      },
    );
    final fingerprint = saved.fingerprintSha256;
    await expectLater(
      verifier.verify(
        alias: saved.alias,
        routeKey: saved.routeKey,
        routeLabel: saved.alias,
        keyType: saved.keyType,
        fingerprint: fingerprint,
        isJumpHost: false,
      ),
      throwsA(isA<SshHostKeyVerificationException>()),
    );
    expect(prompts, 0);
  });

  test('导出只包含所选直连完整公钥，且可重新解析', () async {
    final content =
        'export.example.com ssh-ed25519 ${_publicKey('ssh-ed25519', fill: 5)}';
    final preview = await service.preview('$content\n',
        routeKey: SshHostKeyPolicy.directRoute);
    await service.import('$content\n',
        routeKey: SshHostKeyPolicy.directRoute,
        acceptedIds: {preview.items.single.entry.id});
    final imported = (await store.getAll()).single;
    final manual = _manual();
    final jump = SshHostKey(
      routeKey: 'jump[ops@jump:22]',
      alias: imported.alias,
      keyType: imported.keyType,
      fingerprintSha256: imported.fingerprintSha256,
      firstSeenAt: imported.firstSeenAt,
      lastSeenAt: imported.lastSeenAt,
      status: imported.status,
      source: imported.source,
      confirmedBy: imported.confirmedBy,
      publicKeyBase64: imported.publicKeyBase64,
    );
    await store.trustFirstUse(manual);
    await store.trustFirstUse(jump);

    final exported = service.export([imported, manual, jump]);
    expect(exported.content, contains('export.example.com ssh-ed25519'));
    expect(exported.content, isNot(contains('jump[')));
    expect(exported.content, isNot(contains('manual.example.com')));
    expect(exported.skipped, hasLength(2));
    final reparsed = service.parse(exported.content);
    expect(
        reparsed.entries.single.fingerprintSha256, imported.fingerprintSha256);
  });

  test('无效公钥、通配符和未知算法逐行报告，不静默导入', () async {
    final parsed = service.parse(
      '*.example.com ssh-ed25519 ${_publicKey('ssh-ed25519')}\n'
      'bad.example.com ssh-ed25519 !!!\n'
      'old.example.com ssh-dss AAAA\n',
    );
    expect(parsed.entries, isEmpty);
    expect(parsed.issues, hasLength(3));
  });
}
