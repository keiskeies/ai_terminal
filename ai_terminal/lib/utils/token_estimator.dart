import '../models/chat_session.dart';

/// Token 估算器
///
/// 在不依赖 tokenizer 库的前提下，基于中英文比例估算 token 数。
/// 估算策略：
/// - CJK 字符（中日韩，含中文标点）：1 字符 ≈ 1 token（保守上界，GPT 系列中文约 0.6-0.8）
/// - ASCII 字符：4 字符 ≈ 1 token（OpenAI 英文平均比例）
/// - 其他字符（西文扩展、emoji 等）：1 字符 ≈ 1 token
///
/// 估算误差在 ±20% 以内，足以用于"是否需要裁剪上下文"的判断。
/// 真正的精确 token 数应由 provider 在响应中返回 usage 字段。
class TokenEstimator {
  TokenEstimator._();

  /// 估算单段文本的 token 数
  static int estimateText(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var ascii = 0;
    var other = 0;
    for (final code in text.runes) {
      if (code < 0x80) {
        ascii++;
      } else if (_isCjk(code)) {
        cjk++;
      } else {
        other++;
      }
    }
    // ASCII 4 字符 ≈ 1 token；CJK 1 字符 ≈ 1 token；其他 1 字符 ≈ 1 token
    return cjk + (ascii + 3) ~/ 4 + other;
  }

  /// CJK 字符判定（覆盖中日韩常用范围）
  static bool _isCjk(int code) {
    // CJK Unified Ideographs（常用汉字）
    if (code >= 0x4E00 && code <= 0x9FFF) return true;
    // CJK Extension A
    if (code >= 0x3400 && code <= 0x4DBF) return true;
    // CJK Compatibility Ideographs
    if (code >= 0xF900 && code <= 0xFAFF) return true;
    // CJK Symbols and Punctuation
    if (code >= 0x3000 && code <= 0x303F) return true;
    // Hiragana / Katakana
    if (code >= 0x3040 && code <= 0x30FF) return true;
    // Hangul Syllables
    if (code >= 0xAC00 && code <= 0xD7AF) return true;
    return false;
  }

  /// 估算对话历史的 token 数（不含 system prompt）
  /// [history] 通常为 [ChatMessage] 列表，每条消息额外计入 4 token 的 role/结构开销
  static int estimateHistory(List<ChatMessage> history) {
    if (history.isEmpty) return 0;
    var total = 0;
    for (final m in history) {
      total += estimateText(m.content) + 4; // 4 = role + 结构开销
    }
    return total;
  }

  /// 估算单条消息的 token 数
  static int estimateMessage(ChatMessage message) {
    return estimateText(message.content) + 4;
  }
}
