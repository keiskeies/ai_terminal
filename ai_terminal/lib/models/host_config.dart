import 'package:hive/hive.dart';

part 'host_config.g.dart';

@HiveType(typeId: 0)
class HostConfig extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late String name;

  @HiveField(2)
  late String host;

  @HiveField(3)
  int port = 22;

  @HiveField(4)
  late String username;

  // 认证方式（不含明文密码）
  @HiveField(10)
  late String authType; // 'password' | 'privateKey'

  // 分组
  @HiveField(20)
  String group = "默认";

  @HiveField(21)
  String? tagColor;

  // 跳板机/堡垒机配置（内联，和主服务器在一条连接信息里）
  @HiveField(22)
  String? jumpHost; // 跳板机地址（IP或域名）

  @HiveField(25)
  int jumpPort = 22; // 跳板机端口

  @HiveField(26)
  String? jumpUsername; // 跳板机用户名

  @HiveField(27)
  String? jumpAuthType; // 跳板机认证方式: 'password' | 'privateKey'

  // 连接超时（秒）
  @HiveField(23)
  int timeout = 30;

  // 字符编码
  @HiveField(24)
  String encoding = "utf-8";

  // 元数据
  @HiveField(30)
  late DateTime createdAt;

  @HiveField(31)
  DateTime? lastConnectedAt;

  @HiveField(32)
  String? lastStatus; // 'success' | 'failed' | 'timeout'

  HostConfig();

  HostConfig.create({
    required this.id,
    required this.name,
    required this.host,
    required this.username,
    required this.authType,
    this.port = 22,
    this.group = "默认",
    this.tagColor,
    this.jumpHost,
    this.jumpPort = 22,
    this.jumpUsername,
    this.jumpAuthType,
    this.timeout = 30,
    this.encoding = "utf-8",
  }) : createdAt = DateTime.now();

  /// 生成凭据 key
  String get credKey => 'cred:$id';

  /// 是否使用密码认证
  bool get isPasswordAuth => authType == 'password';

  /// 是否使用私钥认证
  bool get isKeyAuth => authType == 'privateKey';

  /// 是否配置了跳板机
  bool get hasJumpHost => jumpHost != null && jumpHost!.isNotEmpty;

  /// 跳板机是否使用密码认证
  bool get isJumpPasswordAuth => jumpAuthType == null || jumpAuthType == 'password';

  /// 跳板机是否使用私钥认证
  bool get isJumpKeyAuth => jumpAuthType == 'privateKey';

  /// 显示信息
  String get displayAddress => '$host:$port';

  /// 复制配置
  HostConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? authType,
    String? group,
    String? tagColor,
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? jumpAuthType,
    int? timeout,
    String? encoding,
    DateTime? createdAt,
    DateTime? lastConnectedAt,
    String? lastStatus,
  }) {
    final copy = HostConfig()
      ..id = id ?? this.id
      ..name = name ?? this.name
      ..host = host ?? this.host
      ..port = port ?? this.port
      ..username = username ?? this.username
      ..authType = authType ?? this.authType
      ..group = group ?? this.group
      ..tagColor = tagColor ?? this.tagColor
      ..jumpHost = jumpHost ?? this.jumpHost
      ..jumpPort = jumpPort ?? this.jumpPort
      ..jumpUsername = jumpUsername ?? this.jumpUsername
      ..jumpAuthType = jumpAuthType ?? this.jumpAuthType
      ..timeout = timeout ?? this.timeout
      ..encoding = encoding ?? this.encoding
      ..createdAt = createdAt ?? this.createdAt
      ..lastConnectedAt = lastConnectedAt ?? this.lastConnectedAt
      ..lastStatus = lastStatus ?? this.lastStatus;
    return copy;
  }
}
