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
/// - **含无冒号的非空行时整块判为不可解析**（模型把值写成跨行正文的形状，
///   逐行跳过后会静默丢内容）；返回 null 让 engine 记 warn，工具因缺必填参数报错
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
        // 没有冒号的非空行 = 模型把值写跨了行（典型是 content 的多行正文）。
        // 静默跳过会丢掉后半段内容却仍报成功，实测真机上写出过 12 字节的半截文件
        // （三行中文/emoji 只剩第一行）。整个参数块判为不可解析，让工具拿到空参数、
        // 由必填校验抛出明确错误，模型才会改写成一行的 \n 转义形式。
        return null;
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
  /// - String 值 → 按逗号切分（并剥掉 AI 误写的 JSON 方括号）
  /// - 缺失 → [defaultValue]
  static List<String> getStringList(Map<String, dynamic> args, String key, {List<String> defaultValue = const []}) {
    final v = args[key];
    if (v == null) return defaultValue;
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    if (v is String) {
      return _splitListText(v);
    }
    // bool/int 等其他类型 — 不应是列表字段，回退为单元素列表
    final s = v.toString();
    return s.isEmpty ? defaultValue : [s];
  }

  /// 把 "a, b" / "[a, b]" 这类文本切成列表。
  /// 方括号必须剥掉：AI 偶尔会把列表写成 JSON 数组字面量，早期实现直接 split(',')
  /// 会得到 `['[web1', ' web2]']`，导致每个批量调用都打到不存在的主机名。
  static List<String> _splitListText(String value) {
    var text = value.trim();
    if (text.startsWith('[') && text.endsWith(']') && text.length >= 2) {
      text = text.substring(1, text.length - 1);
    }
    // 同时兼容中文逗号（AI 在中文语境下会写 "web1，web2"）
    return text
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
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

/// 工具参数缺失 — 由 [ToolArgs.requireString] 抛出，engine 捕获后转成失败观测
class ToolArgException implements Exception {
  final String key;
  const ToolArgException(this.key);

  @override
  String toString() => '缺少必填参数: $key';
}

/// 工具入参的唯一访问入口。
///
/// 工具实现**不得**直接 `raw['key']?.toString()` 或自己做 `is List || is String` 兼容：
/// 类型兼容规则只在 [ToolArgsParser] 里实现一份，这里提供实例语法糖。
/// 这样新增调用方不可能"忘记转型"——裸 Map 不再是 execute 的参数类型。
class ToolArgs {
  final Map<String, dynamic> _raw;

  const ToolArgs(this._raw);

  static const ToolArgs empty = ToolArgs({});

  /// 原始 Map — 只用于台账描述、审计与日志，不用于取业务参数
  Map<String, dynamic> get asMap => Map.unmodifiable(_raw);

  bool get isEmpty => _raw.isEmpty;

  Iterable<String> get keys => _raw.keys;

  bool has(String key) {
    final v = _raw[key];
    if (v == null) return false;
    if (v is String) return v.isNotEmpty;
    if (v is List) return v.isNotEmpty;
    return true;
  }

  /// 键是否存在（哪怕值为空字符串）
  ///
  /// 与 [has] 的区别是有意保留的：file_write 需要区分"AI 没写 content"和
  /// "AI 写了 content: 但值是空的（多行内容没转义）"，后者要给出专门的纠错提示。
  bool containsKey(String key) => _raw.containsKey(key);

  String getString(String key, {String defaultValue = ''}) =>
      ToolArgsParser.getString(_raw, key, defaultValue: defaultValue);

  /// 必填字符串：缺失或全空白时抛 [ToolArgException]
  String requireString(String key) {
    final v = getString(key).trim();
    if (v.isEmpty) throw ToolArgException(key);
    return v;
  }

  /// 按顺序取第一个非空字符串键（如 remote / remoteDir 两种写法）
  String firstOf(List<String> keyNames, {String defaultValue = ''}) {
    for (final k in keyNames) {
      final v = getString(k).trim();
      if (v.isNotEmpty) return v;
    }
    return defaultValue;
  }

  List<String> getStringList(String key, {List<String> defaultValue = const []}) =>
      ToolArgsParser.getStringList(_raw, key, defaultValue: defaultValue);

  bool getBool(String key, {bool defaultValue = false}) =>
      ToolArgsParser.getBool(_raw, key, defaultValue: defaultValue);

  int getInt(String key, {int defaultValue = 0}) =>
      ToolArgsParser.getInt(_raw, key, defaultValue: defaultValue);

  /// 参数摘要（日志/观测用）：值截断，避免把整个文件内容打进日志
  String describe({int maxValueChars = 80}) {
    if (_raw.isEmpty) return '(无参数)';
    return _raw.entries.map((e) {
      var v = e.value is List ? (e.value as List).join(',') : e.value.toString();
      if (v.length > maxValueChars) {
        v = '${v.substring(0, maxValueChars)}…(${v.length} 字符)';
      }
      return '${e.key}=$v';
    }).join(', ');
  }
}
