import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/theme_colors.dart';

/// 服务商官方 logo（`assets/provider_logos/<id>.svg`）。
///
/// 图标按 id 约定查找，不进 `ai_providers.json`：远程配置刷新会整体覆盖内存里的
/// provider 列表，任何存在 JSON 里的字段都可能被线上旧版本配置丢掉。
class ProviderLogo extends StatelessWidget {
  const ProviderLogo({
    super.key,
    required this.providerId,
    this.fallbackIcon = '🔗',
    this.size = 18,
  });

  final String providerId;

  /// 没有对应 logo 资源时退回的 emoji（来自配置的 `icon` 字段）
  final String fallbackIcon;
  final double size;

  /// 已下载 logo 里只有这些是单色标识（`fill="currentColor"`），必须按主题染色，
  /// 否则深色面板上会是一片黑；其余自带品牌配色，加滤镜反而丢掉多色/渐变标识。
  /// 新增或替换资源后需同步这个集合（`provider_logo_test.dart` 会校验）。
  static const Set<String> monoLogoIds = {
    'agnes',
    'anthropic',
    'baichuan',
    'groq',
    'mimo',
    'moonshot',
    'ollama',
    'openai',
    'qwen',
    'stepfun',
    'xai',
  };

  /// 有 logo 资源的 id（`custom` 等无 brand 的服务商不在其中，继续用 emoji）
  static const Set<String> logoIds = {
    ...monoLogoIds,
    'deepseek',
    'doubao',
    'gemini',
    'hunyuan',
    'minimax',
    'mistral',
    'openrouter',
    'siliconflow',
    'spark',
    'zhipu',
  };

  @override
  Widget build(BuildContext context) {
    if (!logoIds.contains(providerId)) {
      return Text(fallbackIcon, style: TextStyle(fontSize: size));
    }
    return SvgPicture.asset(
      'assets/provider_logos/$providerId.svg',
      width: size,
      height: size,
      colorFilter: monoLogoIds.contains(providerId)
          ? ColorFilter.mode(ThemeColors.of(context).textMain, BlendMode.srcIn)
          : null,
    );
  }
}
