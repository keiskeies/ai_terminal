import 'package:dio/dio.dart';

/// GitHub Releases 更新检查。
///
/// 数据源就是本仓库的 `releases/latest`（CI 打 tag 时自动发布），没有自建
/// 服务端。接口只返回公开信息，无需鉴权；未认证限额 60 次/小时/IP，对
/// 「用户手动点一下」的场景绰绰有余。
class UpdateCheckService {
  UpdateCheckService._();
  static final instance = UpdateCheckService._();

  static const githubRepo = 'keiskeies/ai_terminal';

  /// 拉取最新版本。失败时抛 [UpdateCheckException]（原因用人话，UI 直接显示）。
  Future<UpdateInfo> fetchLatest() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'ai-terminal',
      },
    ));
    try {
      final resp = await dio.get<dynamic>('https://api.github.com/repos/$githubRepo/releases/latest');
      final data = resp.data;
      if (data is! Map) throw const UpdateCheckException('返回格式不认识');
      final tag = (data['tag_name'] as String?)?.trim() ?? '';
      if (tag.isEmpty) throw const UpdateCheckException('最新版本号是空的');
      return UpdateInfo(
        version: normalizeVersion(tag),
        url: (data['html_url'] as String?) ??
            'https://github.com/$githubRepo/releases',
        name: (data['name'] as String?)?.trim(),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        throw const UpdateCheckException('GitHub 接口暂时限流，稍后再试');
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw const UpdateCheckException('连接 GitHub 超时');
      }
      throw const UpdateCheckException('连不上 GitHub');
    } catch (_) {
      throw const UpdateCheckException('检查更新失败');
    }
  }
}

class UpdateInfo {
  const UpdateInfo({required this.version, required this.url, this.name});

  /// 归一化后的版本号，如 `1.4.0`（tag 的 `v` 前缀已去掉）。
  final String version;

  /// Release 页面，供「去下载」打开浏览器。
  final String url;

  /// Release 标题（可选，展示用）。
  final String? name;
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 去掉 tag 的 `v` 前缀与 `+build` 元数据，只留比较用的版本号主体。
String normalizeVersion(String tag) {
  var v = tag.trim();
  if (v.toLowerCase().startsWith('v')) v = v.substring(1);
  final plus = v.indexOf('+');
  if (plus >= 0) v = v.substring(0, plus);
  return v;
}

/// 语义化版本比较：`a > b` 返回正数，相等返回 0，小于返回负数。
///
/// 只按数字段逐位比（1.10.0 > 1.9.9），段数不等时缺位按 0；非数字段
/// （如 `-beta` 预发布后缀）按 0 处理 —— 终端用户拿到的 release 永远是
/// 正式版，不值得为预发布排序写一整套 semver。
int compareVersions(String a, String b) {
  final pa = _segments(a);
  final pb = _segments(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

List<int> _segments(String version) {
  return normalizeVersion(version)
      .split(RegExp(r'[.\-]'))
      .map((s) => int.tryParse(s) ?? 0)
      .toList(growable: false);
}
