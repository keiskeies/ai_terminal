/// 工具参数解析器 — 把 ReAct "参数:" 后的多行 key:value 文本解析为 Map<String, dynamic>
///
/// 格式示例：
/// ```
/// 参数:
///   local: /Users/x/proj/dist
///   remote: /var/www/myapp
///   recursive: true
///   exclude: node_modules,.git
/// ```
///
/// 规则：
/// - 缩进用 2 空格或 Tab 均可
/// - 值是第一个冒号后的整行（trim 后），支持路径含空格
/// - "true"/"false" 自动转 bool
/// - 纯数字自动转 int
/// - hostIds/exclude 字段含逗号时转 List<String>
///
/// 工具实现访问参数时，**必须使用 [getString] / [getStringList] / [getBool] / [getInt]
/// 这四个类型 helper**，不要直接 `args['key']` 然后自己做 `is List || is String` 兼容。
/// 早期改造出现过工具直接 `args['hostIds']?.toString()` 导致 List 被序列化成
/// `[web1, web2]` 再 split(',') 得到带方括号的脏数据。helper 层集中处理类型兼容，
/// 工具实现只关心"取值 + 默认值"。
class ToolArgsParser {
  /// 解析参数文本。
  /// [argsText] 已经去掉 "参数:" 前缀的原始内容（可能含换行）
  /// 返回 null 表示无法解析为有效 Map
  ///
  /// 注意：JSON 格式（以 { 开头）已被弃用，直接返回 null。
  /// 这样设计是为了强制 AI 使用多行 key:value 格式，
  /// 当 AI 误用 JSON 时 parser 返回 null，engine 会记录 warn 日志提示格式错误。
  static Map<String, dynamic>? parse(String argsText) {
    final trimmed = argsText.trim();
    if (trimmed.isEmpty) return null;

    // 显式拒绝 JSON 格式（以 { 开头）— 强制 AI 使用多行 key:value
    // 返回 null 让 engine 记录 warn，AI 收到错误反馈后会改用多行格式
    if (trimmed.startsWith('{')) {
      return null;
    }

    final result = <String, dynamic>{};
    final lines = trimmed.split('\n');
    bool hasAny = false;

    for (final rawLine in lines) {
      // 跳过空行
      if (rawLine.trim().isEmpty) continue;

      // 去掉行首缩进（2 空格或 Tab 均可）
      final line = rawLine.replaceFirst(RegExp(r'^\s*'), '');

      // 找第一个冒号（值可能含冒号，如路径 C:\path 或 time 12:00）
      final colonIdx = line.indexOf(':');
      if (colonIdx < 0) {
        // 没有冒号 — 不是合法的 key:value 行，跳过
        continue;
      }

      final key = line.substring(0, colonIdx).trim();
      final rawValue = line.substring(colonIdx + 1).trim();

      if (key.isEmpty) continue;

      // 值类型转换
      final value = _convertValue(key, rawValue);
      result[key] = value;
      hasAny = true;
    }

    return hasAny ? result : null;
  }

  /// 值类型转换（内部使用，工具实现请用 getString/getStringList/getBool/getInt）
  /// - "true"/"false" → bool
  /// - 纯数字 → int
  /// - hostIds/exclude 等列表字段 → List<String>（逗号分隔）
  /// - 其他 → String
  static dynamic _convertValue(String key, String rawValue) {
    // 布尔转换
    if (rawValue == 'true') return true;
    if (rawValue == 'false') return false;

    // 整数转换（如 timeout、port）
    if (RegExp(r'^-?\d+$').hasMatch(rawValue)) {
      return int.parse(rawValue);
    }

    // 已知列表字段：逗号分隔转 List<String>
    const listKeys = {'hostIds', 'exclude'};
    if (listKeys.contains(key) && rawValue.contains(',')) {
      return rawValue
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    return rawValue;
  }

  // ──────────────────────────────────────────────────────────
  // 类型 helper：工具实现必须用这些方法访问参数，不要直接 args['key']
  // 集中处理 List/String/bool/int 兼容，避免每个工具重复 is List 判断
  // ──────────────────────────────────────────────────────────

  /// 取 String 参数。缺失或类型不匹配返回 [defaultValue]。
  static String getString(Map<String, dynamic> args, String key, {String defaultValue = ''}) {
    final v = args[key];
    if (v == null) return defaultValue;
    if (v is String) return v;
    if (v is List) return v.join(','); // List<String> → 逗号拼接
    return v.toString();
  }

  /// 取 List<String> 参数。
  /// - List 值 → map toString
  /// - String 值 → 按逗号切分
  /// - 缺失 → [defaultValue]
  static List<String> getStringList(Map<String, dynamic> args, String key, {List<String> defaultValue = const []}) {
    final v = args[key];
    if (v == null) return defaultValue;
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    if (v is String) {
      return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    // bool/int 等其他类型 — 不应是列表字段，回退为单元素列表
    final s = v.toString();
    return s.isEmpty ? defaultValue : [s];
  }

  /// 取 bool 参数。
  /// - bool 值 → 直接返回
  /// - String "true"/"false" → 解析
  /// - 其他 → [defaultValue]
  static bool getBool(Map<String, dynamic> args, String key, {bool defaultValue = false}) {
    final v = args[key];
    if (v == null) return defaultValue;
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return defaultValue;
  }

  /// 取 int 参数。
  /// - int 值 → 直接返回
  /// - String → int.tryParse，失败返回 [defaultValue]
  /// - 其他 → [defaultValue]
  static int getInt(Map<String, dynamic> args, String key, {int defaultValue = 0}) {
    final v = args[key];
    if (v == null) return defaultValue;
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? defaultValue;
    if (v is num) return v.toInt();
    return defaultValue;
  }
}
