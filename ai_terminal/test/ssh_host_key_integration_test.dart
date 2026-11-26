import 'dart:convert';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/core/security/ssh_client_security.dart';
import 'package:ai_terminal/core/security/ssh_host_key_policy.dart';
import 'package:ai_terminal/core/security/ssh_host_key_verifier.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/ssh_host_key.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/widgets/ssh_host_key_dialog.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSftpClient implements SftpClient {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient implements SSHClient {
  int sftpCalls = 0;

  @override
  Future<SftpClient> sftp() async {
    sftpCalls++;
    return _FakeSftpClient();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _fingerprint(int value) =>
    'SHA256:${base64.encode(List<int>.filled(32, value)).replaceAll('=', '')}';

SshHostKeyRequest _request({SshHostKey? existing}) => SshHostKeyRequest(
      id: 'dialog-test',
      alias: 'server.example.com',
      routeKey: SshHostKeyPolicy.directRoute,
      routeLabel: 'server.example.com:22',
      keyType: 'ssh-ed25519',
      fingerprintSha256: _fingerprint(2),
      isJumpHost: false,
      existing: existing,
    );

void main() {
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  test('SFTP 复用拒绝未验证 client，验证后才打开子系统', () async {
    final client = _FakeSshClient();
    final service = SftpService();
    await expectLater(service.attachToClient(client), throwsStateError);
    expect(client.sftpCalls, 0);

    SshClientSecurity.markVerified(client);
    await service.attachToClient(client);
    expect(client.sftpCalls, 1);

    SshClientSecurity.clearVerified(client);
    await expectLater(service.attachToClient(client), throwsStateError);
    expect(client.sftpCalls, 1);
    service.closeSftpOnly();
  });

  testWidgets('首次确认展示地址和完整指纹，接受后返回信任', (tester) async {
    SshHostKeyPromptResponse? response;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              response = await showSshHostKeyDialog(context, _request());
            },
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('首次连接需要确认主机身份'), findsOneWidget);
    expect(find.text('server.example.com'), findsOneWidget);
    expect(find.text(_fingerprint(2)), findsOneWidget);
    expect(find.text('我已核对，信任主机'), findsOneWidget);
    await tester.tap(find.text('我已核对，信任主机'));
    await tester.pumpAndSettle();
    expect(response?.accepted, isTrue);
    expect(response?.replaceExisting, isTrue);
  });

  testWidgets('密钥变更同时展示新旧指纹，并要求显式替换', (tester) async {
    final existing = SshHostKeyPolicy.newTrust(
      routeKey: SshHostKeyPolicy.directRoute,
      alias: 'server.example.com',
      keyType: 'ssh-ed25519',
      fingerprintSha256: _fingerprint(1),
      source: SshHostKeySource.userConfirmed,
      now: DateTime.utc(2026, 1, 1),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () =>
                showSshHostKeyDialog(context, _request(existing: existing)),
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('该主机的密钥已变化'), findsOneWidget);
    expect(find.text(_fingerprint(1)), findsOneWidget);
    expect(find.text(_fingerprint(2)), findsOneWidget);
    expect(find.text('我已核对，信任主机'), findsNothing);
    expect(find.text('我已核对，替换密钥'), findsOneWidget);
  });

  testWidgets('确认超时取消只关闭当前弹窗并返回拒绝', (tester) async {
    SshHostKeyPromptResponse? response;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              response = await showSshHostKeyDialog(context, _request());
            },
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    SshHostKeyPromptService.cancel('dialog-test');
    await tester.pumpAndSettle();

    expect(response?.accepted, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
