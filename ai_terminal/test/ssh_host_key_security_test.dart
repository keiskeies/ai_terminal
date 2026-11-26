import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_terminal/core/db_init.dart';
import 'package:ai_terminal/core/security/ssh_host_key_policy.dart';
import 'package:ai_terminal/core/security/ssh_host_key_store.dart';
import 'package:ai_terminal/core/security/ssh_host_key_verifier.dart';
import 'package:ai_terminal/models/ssh_host_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _fingerprint(int value) {
  final bytes = Uint8List(32)..fillRange(0, 32, value);
  return 'SHA256:${base64.encode(bytes).replaceAll('=', '')}';
}

SshHostKey _key({
  String fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  SshHostKeyStatus status = SshHostKeyStatus.trusted,
}) =>
    SshHostKeyPolicy.newTrust(
      routeKey: 'direct',
      alias: 'server.example.com',
      keyType: 'ssh-ed25519',
      fingerprintSha256: fingerprint,
      source: SshHostKeySource.userConfirmed,
      now: DateTime.utc(2026, 1, 1),
    ).copyWith(status: status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late SshHostKeyStore store;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await db.execute(sshHostKeysCreateSql);
    store = SshHostKeyStore(databaseOverride: db);
  });

  tearDown(() async {
    SshHostKeyPromptService.setHandler(null);
    await db.close();
  });

  test('地址规范化包含非默认端口并隔离 IPv6 与跳板路由', () {
    expect(SshHostKeyPolicy.alias('EXAMPLE.com.', 22), 'example.com');
    expect(SshHostKeyPolicy.alias('example.com', 2222), 'example.com:2222');
    expect(SshHostKeyPolicy.alias('2001:DB8::1', 22), '[2001:db8::1]:22');
    expect(
      SshHostKeyPolicy.jumpRoute(
          username: 'ops', host: 'Jump.Example.com', port: 2222),
      'jump[ops@jump.example.com:2222]',
    );
  });

  test('拒绝 SHA-1、未知算法与畸形指纹', () {
    expect(
      () => SshHostKeyPolicy.validateKeyType('ssh-rsa'),
      throwsA(isA<SshHostKeyPolicyException>()),
    );
    expect(
      () => SshHostKeyPolicy.normalizeFingerprint('SHA256:short'),
      throwsA(isA<SshHostKeyPolicyException>()),
    );
    expect(SshHostKeyPolicy.normalizeFingerprint('${_fingerprint(1)}='),
        _fingerprint(1));
    expect(
      SshHostKeyPolicy.normalizeFingerprintBytes(utf8.encode(_fingerprint(2))),
      _fingerprint(2),
    );
    expect(
      () => SshHostKeyPolicy.normalizeFingerprintBytes([0xff]),
      throwsA(isA<SshHostKeyPolicyException>()),
    );
  });

  test('信任记录落库后可由新 store 读取', () async {
    expect(await store.trustFirstUse(_key()), isTrue);
    final reopened = SshHostKeyStore(databaseOverride: db);
    final saved = await reopened.find(
      routeKey: 'direct',
      alias: 'server.example.com',
      keyType: 'ssh-ed25519',
    );
    expect(saved?.fingerprintSha256, _key().fingerprintSha256);
    expect(saved?.status, SshHostKeyStatus.trusted);
    expect(saved?.confirmedBy, 'local-user');
  });

  test('首次信任为原子插入，不覆盖并发或已有记录', () async {
    final results = await Future.wait([
      store.trustFirstUse(_key(fingerprint: _fingerprint(1))),
      store.trustFirstUse(_key(fingerprint: _fingerprint(2))),
    ]);
    expect(results.where((value) => value).length, 1);
    final rows = await db.query('ssh_host_keys');
    expect(rows, hasLength(1));
  });

  test('替换信任校验旧指纹并保留首次发现时间', () async {
    await store.trustFirstUse(_key(fingerprint: _fingerprint(1)));
    final replacement = _key(fingerprint: _fingerprint(2));
    expect(
      await store.replaceTrusted(
        routeKey: 'direct',
        alias: 'server.example.com',
        keyType: 'ssh-ed25519',
        expectedFingerprint: _fingerprint(9),
        replacement: replacement,
      ),
      isFalse,
    );
    expect(
      await store.replaceTrusted(
        routeKey: 'direct',
        alias: 'server.example.com',
        keyType: 'ssh-ed25519',
        expectedFingerprint: _fingerprint(1),
        replacement: replacement,
      ),
      isTrue,
    );
    final saved = await store.find(
        routeKey: 'direct',
        alias: 'server.example.com',
        keyType: 'ssh-ed25519');
    expect(saved?.fingerprintSha256, _fingerprint(2));
    expect(saved?.firstSeenAt.toUtc(), DateTime.utc(2026, 1, 1));
  });

  test('撤销后拒绝信任且不能被隐式替换', () async {
    await store.trustFirstUse(_key());
    final saved = (await store.getAll()).single;
    await store.revoke(saved);
    expect(await store.touch(saved), isFalse);
    expect(
      await store.replaceTrusted(
        routeKey: 'direct',
        alias: 'server.example.com',
        keyType: 'ssh-ed25519',
        expectedFingerprint: saved.fingerprintSha256,
        replacement: _key(fingerprint: _fingerprint(2)),
      ),
      isFalse,
    );
  });

  test('v11 迁移保留主机信任并为完整公钥增加可空列', () async {
    await db.execute('DROP TABLE ssh_host_keys');
    await db.execute('''
      CREATE TABLE audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        hostId TEXT NOT NULL,
        command TEXT NOT NULL,
        safetyLevel TEXT NOT NULL,
        output TEXT,
        executed INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE ssh_host_keys (
        route_key TEXT NOT NULL,
        alias TEXT NOT NULL,
        key_type TEXT NOT NULL,
        fingerprint_sha256 TEXT NOT NULL,
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        source TEXT NOT NULL,
        confirmed_by TEXT NOT NULL,
        PRIMARY KEY (route_key, alias, key_type)
      )
    ''');
    final legacy = _key(fingerprint: _fingerprint(3));
    await db.insert('ssh_host_keys', {
      'route_key': legacy.routeKey,
      'alias': legacy.alias,
      'key_type': legacy.keyType,
      'fingerprint_sha256': legacy.fingerprintSha256,
      'first_seen_at': legacy.firstSeenAt.millisecondsSinceEpoch,
      'last_seen_at': legacy.lastSeenAt.millisecondsSinceEpoch,
      'status': legacy.status.name,
      'source': legacy.source.name,
      'confirmed_by': legacy.confirmedBy,
    });

    await DbInit.migrateSchemaForTesting(db, 11, 12);

    final columns = await db.rawQuery('PRAGMA table_info(ssh_host_keys)');
    expect(columns.map((row) => row['name']), contains('public_key_base64'));
    final saved = await store.find(
      routeKey: legacy.routeKey,
      alias: legacy.alias,
      keyType: legacy.keyType,
    );
    expect(saved?.fingerprintSha256, legacy.fingerprintSha256);
    expect(saved?.status, SshHostKeyStatus.trusted);
    expect(saved?.publicKeyBase64, isNull);
  });

  group('SshHostKeyVerifier', () {
    Future<bool> verify(SshHostKeyVerifier verifier, {String? fingerprint}) =>
        verifier.verify(
          alias: 'server.example.com',
          routeKey: 'direct',
          routeLabel: 'server.example.com:22',
          keyType: 'ssh-ed25519',
          fingerprint: fingerprint ?? _fingerprint(1),
          isJumpHost: false,
        );

    test('已信任密钥直接通过且不弹确认', () async {
      await store.trustFirstUse(_key(fingerprint: _fingerprint(1)));
      var prompts = 0;
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async {
          prompts++;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      expect(await verify(verifier), isTrue);
      expect(prompts, 0);
    });

    test('首次使用必须人工确认后才信任', () async {
      SshHostKeyRequest? seen;
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (request) async {
          seen = request;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      expect(await verify(verifier), isTrue);
      expect(seen?.fingerprintSha256, _fingerprint(1));
      expect(seen?.existing, isNull);
      expect(await store.getAll(), hasLength(1));
    });

    test('用户拒绝不写信任记录', () async {
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async => const SshHostKeyPromptResponse.reject(),
      );
      await expectLater(
          verify(verifier), throwsA(isA<SshHostKeyVerificationException>()));
      expect(await store.getAll(), isEmpty);
    });

    test('密钥变更默认拒绝，显式替换后通过', () async {
      await store.trustFirstUse(_key(fingerprint: _fingerprint(1)));
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async => const SshHostKeyPromptResponse.accept(),
      );
      await expectLater(
        verify(verifier, fingerprint: _fingerprint(2)),
        throwsA(isA<SshHostKeyVerificationException>()),
      );
      final replaceVerifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async =>
            const SshHostKeyPromptResponse.accept(replaceExisting: true),
      );
      expect(
          await verify(replaceVerifier, fingerprint: _fingerprint(2)), isTrue);
    });

    test('撤销密钥直接拒绝且不弹窗', () async {
      await store.trustFirstUse(_key(status: SshHostKeyStatus.revoked));
      var prompts = 0;
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async {
          prompts++;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      await expectLater(
          verify(verifier), throwsA(isA<SshHostKeyVerificationException>()));
      expect(prompts, 0);
    });

    test('并发首次连接只发起一次确认', () async {
      final promptStarted = Completer<void>();
      final releasePrompt = Completer<void>();
      var prompts = 0;
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async {
          prompts++;
          promptStarted.complete();
          await releasePrompt.future;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      final first = verify(verifier);
      final second = verify(verifier);
      await promptStarted.future;
      expect(prompts, 1);
      releasePrompt.complete();
      expect(await Future.wait([first, second]), [true, true]);
      expect(await store.getAll(), hasLength(1));
    });

    test('并发出现不同指纹时拒绝第二次连接且不重复弹窗', () async {
      final promptStarted = Completer<void>();
      final releasePrompt = Completer<void>();
      var prompts = 0;
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async {
          prompts++;
          promptStarted.complete();
          await releasePrompt.future;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      final first = verify(verifier, fingerprint: _fingerprint(1));
      await promptStarted.future;
      final second = verify(verifier, fingerprint: _fingerprint(2));
      await expectLater(
          second, throwsA(isA<SshHostKeyVerificationException>()));
      expect(prompts, 1);
      releasePrompt.complete();
      expect(await first, isTrue);
      expect((await store.getAll()).single.fingerprintSha256, _fingerprint(1));
    });

    test('确认期间出现不同密钥时失败关闭', () async {
      final promptStarted = Completer<void>();
      final releasePrompt = Completer<void>();
      final verifier = SshHostKeyVerifier(
        store: store,
        prompt: (_) async {
          promptStarted.complete();
          await releasePrompt.future;
          return const SshHostKeyPromptResponse.accept();
        },
      );
      final pending = verify(verifier, fingerprint: _fingerprint(1));
      await promptStarted.future;
      await store.trustFirstUse(_key(fingerprint: _fingerprint(2)));
      releasePrompt.complete();
      await expectLater(
          pending, throwsA(isA<SshHostKeyVerificationException>()));
      final saved = await store.getAll();
      expect(saved.single.fingerprintSha256, _fingerprint(2));
    });

    test('确认超时失败关闭且不写信任', () async {
      final verifier = SshHostKeyVerifier(
        store: store,
        promptTimeout: const Duration(milliseconds: 10),
        prompt: (_) => Completer<SshHostKeyPromptResponse>().future,
      );
      await expectLater(
          verify(verifier), throwsA(isA<SshHostKeyVerificationException>()));
      expect(await store.getAll(), isEmpty);
    });
  });
}
