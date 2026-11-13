// ansi_stripper.ts - strips ANSI escape sequences from terminal output
//
// 1:1 port of Dart utils/ansi_stripper.dart (63 lines).
//
// Pipeline: 1) full ANSI sequences → 2) prompt prefixes → 3) residual
// OSC/CSI fragments → 4) control chars + trailing spaces → 5) collapse
// repeated blank lines → trim.

// 1. Full ANSI escape sequences (CSI, OSC, charset, 2-byte, BEL, CR)
const ANSI_RE = new RegExp(
  [
    String.raw`\x1b\[[\x20-\x3f]*[\x40-\x7e]`,
    String.raw`\x1b\][0-9]*;?[^\x07\x1b]*(?:\x07|\x1b\\)`,
    String.raw`\x1b\([A-Za-z]`,
    String.raw`\x1b\)[A-Za-z]`,
    String.raw`\x1b[A-Za-z]`,
    String.raw`\x07`,
    String.raw`\x0d`,
  ].join("|"),
  "g"
);

// 2. Line-start prompt residuals like [root@host ~]#
const PROMPT_PREFIX_RE = /^\[[\w@.\-~\s]+\][#$]\s*/gm;

// 3. Residual half-sequences (ESC byte lost)
const RESIDUAL_OSC_RE = /\][0-9]*;[^\n\r]*/g;
const RESIDUAL_CSI_RE = /\[[\x20-\x3f]*[\x40-\x7e]/g;

// 4. Control chars (except \n \t) + trailing spaces, one pass
const CONTROL_AND_TRAIL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f]| +$/gm;

// 5. Collapse 3+ consecutive newlines to 2
const REPEATED_BLANK_RE = /\n{3,}/g;

/**
 * Strip all ANSI escape sequences, prompt residuals, control characters,
 * and collapse repeated blank lines. Returns clean plain text.
 */
export function stripAnsi(input: string): string {
  let result = input;

  // 1. Remove full ANSI escape sequences
  result = result.replace(ANSI_RE, "");

  // 2. Prompt prefixes BEFORE residual CSI (order matters:
  //    `[root@host ~]#` would be eaten by the residual CSI regex)
  result = result.replace(PROMPT_PREFIX_RE, "");

  // 3. Residual half-sequences
  result = result.replace(RESIDUAL_OSC_RE, "");
  result = result.replace(RESIDUAL_CSI_RE, "");

  // 4. Control chars + trailing spaces
  result = result.replace(CONTROL_AND_TRAIL_RE, "");

  // 5. Collapse repeated blank lines
  result = result.replace(REPEATED_BLANK_RE, "\n\n");

  return result.trim();
}