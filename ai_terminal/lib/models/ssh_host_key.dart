enum SshHostKeyStatus { trusted, revoked }

enum SshHostKeySource { userConfirmed, imported }

class SshHostKey {
  const SshHostKey({
    required this.routeKey,
    required this.alias,
    required this.keyType,
    required this.fingerprintSha256,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.status,
    required this.source,
    required this.confirmedBy,
    this.publicKeyBase64,
  });

  final String routeKey;
  final String alias;
  final String keyType;
  final String fingerprintSha256;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final SshHostKeyStatus status;
  final SshHostKeySource source;
  final String confirmedBy;
  final String? publicKeyBase64;

  SshHostKey copyWith({
    String? fingerprintSha256,
    DateTime? lastSeenAt,
    SshHostKeyStatus? status,
    SshHostKeySource? source,
    String? confirmedBy,
    String? publicKeyBase64,
  }) =>
      SshHostKey(
        routeKey: routeKey,
        alias: alias,
        keyType: keyType,
        fingerprintSha256: fingerprintSha256 ?? this.fingerprintSha256,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        status: status ?? this.status,
        source: source ?? this.source,
        confirmedBy: confirmedBy ?? this.confirmedBy,
        publicKeyBase64: publicKeyBase64 ?? this.publicKeyBase64,
      );
}
