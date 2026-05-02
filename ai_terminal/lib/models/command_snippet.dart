import 'package:hive/hive.dart';

part 'command_snippet.g.dart';

@HiveType(typeId: 3)
class CommandSnippet extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late String name;

  @HiveField(2)
  late String command;

  @HiveField(3)
  String? description;

  @HiveField(4)
  List<String> variables = [];

  @HiveField(5)
  late DateTime createdAt;

  CommandSnippet();

  CommandSnippet.create({
    required this.id,
    required this.name,
    required this.command,
    this.description,
    List<String>? variables,
  })  : variables = variables ?? [],
        createdAt = DateTime.now();

  /// 替换变量后的命令
  String resolveCommand(Map<String, String> values) {
    var resolved = command;
    values.forEach((key, value) {
      resolved = resolved.replaceAll('{{$key}}', value);
    });
    return resolved;
  }

  /// 检查是否有未填充的变量
  bool hasUnfilledVariables(Map<String, String> values) {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(command);
    for (final match in matches) {
      final varName = match.group(1)!;
      if (!values.containsKey(varName) || values[varName]!.isEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 获取所有变量名
  List<String> getAllVariables() {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    return regex.allMatches(command).map((m) => m.group(1)!).toSet().toList();
  }
}
