class FormValidators {
  static String? required(String? value, [String fieldName = '此字段']) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName 不能为空';
    }
    return null;
  }

  static String? maxLength(String? value, int max, [String fieldName = '此字段']) {
    if (value != null && value.length > max) {
      return '$fieldName 不能超过 $max 个字符';
    }
    return null;
  }

  static String? host(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '请输入主机地址';
    }
    // 简单的 IP 或域名验证
    final ipRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    final domainRegex = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$');
    if (!ipRegex.hasMatch(value) && !domainRegex.hasMatch(value)) {
      return '请输入有效的 IP 地址或域名';
    }
    return null;
  }

  static String? port(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null; // 端口可选
    }
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      return '端口号必须是 1-65535';
    }
    return null;
  }

  static String? url(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '请输入 URL';
    }
    final urlRegex = RegExp(r'^https?://[^\s]+$');
    if (!urlRegex.hasMatch(value)) {
      return '请输入有效的 URL';
    }
    return null;
  }

  static String? combine(List<String? Function()> validators) {
    for (final validator in validators) {
      final result = validator();
      if (result != null) return result;
    }
    return null;
  }
}
