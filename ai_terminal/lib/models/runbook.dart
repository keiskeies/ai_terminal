import 'package:hive/hive.dart';
import '../core/l10n_holder.dart';

part 'runbook.g.dart';

/// 工作流类型
@HiveType(typeId: 40)
enum RunbookType {
  /// AI 执行：自然语言描述任务，AI 按 ReAct 框架执行
  @HiveField(0)
  agent,
  /// 直接执行：变量替换后在终端直接执行命令
  @HiveField(1)
  command,
}

/// 工作流分类
@HiveType(typeId: 41)
enum RunbookCategory {
  @HiveField(0)
  inspection,    // 巡检
  @HiveField(1)
  security,      // 安全
  @HiveField(2)
  deployment,    // 部署
  @HiveField(3)
  troubleshooting, // 故障排查
  @HiveField(4)
  maintenance,   // 日常维护
  @HiveField(5)
  custom,        // 自定义
}

/// 运维工作流 — 用户可沉淀的运维操作模板
/// 支持两种类型：agent（AI 执行）和 command（直接执行）
/// 支持参数化变量 {{var}}
@HiveType(typeId: 42)
class Runbook extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late String name;

  @HiveField(2)
  late String icon;

  @HiveField(3)
  String? description;

  @HiveField(4)
  late RunbookType type;

  @HiveField(5)
  late RunbookCategory category;

  /// 内容：agent 类型是自然语言 prompt，command 类型是 shell 命令
  @HiveField(6)
  late String content;

  /// 是否内置模板（内置不可删除，可克隆修改）
  @HiveField(7)
  bool isBuiltin = false;

  @HiveField(8)
  late DateTime createdAt;

  @HiveField(9)
  late DateTime updatedAt;

  /// 执行次数（用户可查看哪些工作流最常用）
  @HiveField(10)
  int runCount = 0;

  /// 最近执行时间
  @HiveField(11)
  DateTime? lastRunAt;

  Runbook();

  Runbook.create({
    required this.id,
    required this.name,
    required this.icon,
    required this.type,
    required this.category,
    required this.content,
    this.description,
    this.isBuiltin = false,
  })  : createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  /// 获取内容中的所有变量名 {{var}}
  List<String> getAllVariables() {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    return regex.allMatches(content).map((m) => m.group(1)!).toSet().toList();
  }

  /// 替换变量后的内容
  String resolveContent(Map<String, String> values) {
    var resolved = content;
    values.forEach((key, value) {
      resolved = resolved.replaceAll('{{$key}}', value);
    });
    return resolved;
  }

  /// 检查是否有未填充的变量
  bool hasUnfilledVariables(Map<String, String> values) {
    final vars = getAllVariables();
    for (final v in vars) {
      if (!values.containsKey(v) || values[v]!.isEmpty) {
        return true;
      }
    }
    return false;
  }

  Runbook clone() {
    return Runbook.create(
      id: '', // 调用方分配新 id
      name: L10n.str.runbookCopy(name),
      icon: icon,
      type: type,
      category: RunbookCategory.custom,
      content: content,
      description: description,
      isBuiltin: false,
    );
  }
}
