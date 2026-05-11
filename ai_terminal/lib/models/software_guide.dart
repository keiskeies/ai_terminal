/// 软件安装知识条目模型
class SoftwareGuide {
  final int? id;
  final String softwareName;
  final String aliases; // 逗号分隔别名
  final String opType; // install, uninstall, update, configure
  final String platform; // linux, macos, windows, all
  final String packageManager; // npm, pip, apt 等
  final String summary; // 一句话说明
  final String steps; // 详细步骤描述（给 LLM 参考）
  final String commands; // 可直接执行的命令，换行分隔
  final String preRequirements; // 前置依赖说明
  final String notes; // 备注
  final String mode; // strict / suggest

  SoftwareGuide({
    this.id,
    required this.softwareName,
    this.aliases = '',
    required this.opType,
    this.platform = 'linux',
    this.packageManager = '',
    this.summary = '',
    this.steps = '',
    this.commands = '',
    this.preRequirements = '',
    this.notes = '',
    this.mode = 'strict',
  });

  factory SoftwareGuide.fromMap(Map<String, dynamic> map) {
    return SoftwareGuide(
      id: map['id'] as int?,
      softwareName: map['software_name'] as String? ?? '',
      aliases: map['aliases'] as String? ?? '',
      opType: map['op_type'] as String? ?? 'install',
      platform: map['platform'] as String? ?? 'linux',
      packageManager: map['package_manager'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
      steps: map['steps'] as String? ?? '',
      commands: map['commands'] as String? ?? '',
      preRequirements: map['pre_requirements'] as String? ?? '',
      notes: map['notes'] as String? ?? '',
      mode: map['mode'] as String? ?? 'strict',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'software_name': softwareName,
      'aliases': aliases,
      'op_type': opType,
      'platform': platform,
      'package_manager': packageManager,
      'summary': summary,
      'steps': steps,
      'commands': commands,
      'pre_requirements': preRequirements,
      'notes': notes,
      'mode': mode,
    };
  }

  /// 构建 LLM 注入文本
  String buildInjectionText() {
    final buffer = StringBuffer();
    buffer.writeln('软件: $softwareName');
    buffer.writeln('操作: ${opTypeLabel(opType)}');
    buffer.writeln('平台: $platform');
    if (packageManager.isNotEmpty) {
      buffer.writeln('包管理器: $packageManager');
    }
    if (summary.isNotEmpty) {
      buffer.writeln('说明: $summary');
    }
    if (preRequirements.isNotEmpty) {
      buffer.writeln('前置依赖: $preRequirements');
    }
    if (commands.isNotEmpty) {
      buffer.writeln('命令:');
      for (final cmd in commands.split('\n')) {
        if (cmd.trim().isNotEmpty) {
          buffer.writeln('  $cmd');
        }
      }
    }
    if (steps.isNotEmpty) {
      buffer.writeln('步骤: $steps');
    }
    if (notes.isNotEmpty) {
      buffer.writeln('备注: $notes');
    }
    buffer.writeln('模式: ${mode == "strict" ? "强制执行" : "推荐参考"}');
    return buffer.toString();
  }

  static String opTypeLabel(String opType) {
    switch (opType) {
      case 'install':
        return '安装';
      case 'uninstall':
        return '卸载';
      case 'update':
        return '更新';
      case 'configure':
        return '配置';
      default:
        return opType;
    }
  }
}

/// 知识库检索结果
class KnowledgeSearchResult {
  final SoftwareGuide guide;
  final double score; // FTS5 相关性分数

  KnowledgeSearchResult({required this.guide, required this.score});
}
