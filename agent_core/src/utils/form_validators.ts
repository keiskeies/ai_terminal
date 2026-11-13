// FormValidators - 1:1 port of Dart ai_terminal/lib/utils/form_validators.dart
// (1764 bytes, Flutter UI dead code: no importer in lib/ as of r199).
//
// The host/port URL validation is NOT UI-only: the Node MCP config editor
// (mcp/manager.ts save path) and the SSH host form (rpc/server.ts startTask
// request validation) can reuse validateHost/validatePort for the same
// accept/reject decisions the Dart Flutter forms made, keeping both sides
// byte-identical on the literals (e.g. "请输入有效的 IP 地址或域名").
export interface ValidatorResult {
  ok: boolean;
  /** Dart: the error message; null when ok. */
  error: string | null;
}

function pass(): ValidatorResult {
  return {ok: true, error: null};
}
function fail(message: string): ValidatorResult {
  return {ok: false, error: message};
}

export const FormValidators = {
  /** Dart: required(value, [fieldName = '此字段']) */
  required(value: string | null, fieldName: string = "此字段"): ValidatorResult {
    if (value == null || value.trim().length === 0) return fail(fieldName + " 不能为空");
    return pass();
  },

  /** Dart: maxLength(value, max, [fieldName = '此字段']) */
  maxLength(value: string | null, max: number, fieldName: string = "此字段"): ValidatorResult {
    if (value != null && value.length > max) return fail(fieldName + " 不能超过 " + max + " 个字符");
    return pass();
  },

  /** Dart: host(value) - IPv4 dotted-quad or DNS domain, else error. */
  host(value: string | null): ValidatorResult {
    if (value == null || value.trim().length === 0) return fail("请输入主机地址");
    const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
    const domainRegex = /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/;
    if (!ipRegex.test(value) && !domainRegex.test(value)) return fail("请输入有效的 IP 地址或域名");
    return pass();
  },

  /** Dart: port(value) - optional; when present must be 1..65535. */
  port(value: string | null): ValidatorResult {
    // Dart: int.tryParse(value) - base-10 digits only, null when unparseable.
    if (value == null || value.trim().length === 0) return pass();
    const trimmed = value.trim();
    if (!/^-?\d+$/.test(trimmed)) return fail("端口号必须是 1-65535");
    const parsed = parseInt(trimmed, 10);
    if (parsed < 1 || parsed > 65535) return fail("端口号必须是 1-65535");
    return pass();
  },

  /** Dart: url(value) - must start with http:// or https://, no whitespace. */
  url(value: string | null): ValidatorResult {
    if (value == null || value.trim().length === 0) return fail("请输入 URL");
    if (!/^https?:\/\/[\S]+$/.test(value)) return fail("请输入有效的 URL");
    return pass();
  },

  /** Dart: combine - first error wins, null when all pass. */
  combine(validatorFns: Array<() => ValidatorResult>): ValidatorResult {
    for (const fn of validatorFns) {
      const result = fn();
      if (result.error !== null) return result;
    }
    return pass();
  },
};
