// react/regex.ts - regex patterns for the ReAct parser
// Kept in a separate module so parser.ts imports them.

export const XML_FENCED = new RegExp("---\\s*\\n<function=(\\w+)>\\s*\\n<parameter=command>([\\s[\\S]*?)</parameter>\\s*\\n</function>\\s*\\n---", "g");
export const XML_BARE = new RegExp("<function=(\\w+)>\\s*\\n<parameter=command>([\\s[\\S]*?)</parameter>\\s*\\n</function>", "g");
export const RESIDUAL_SEP = new RegExp("^---\\s*$", "gm");
export const CODE_FENCE_PREFIX = new RegExp("^```\\w*\\s*\\n?", "g");
export const CODE_FENCE_SUFFIX = new RegExp("\\n?```\\s*$");
export const PLAN_BULLET = new RegExp("^(?:[-*•]|\\d+[.)、])\\s+");
export const PLAN_STATUS_BOX = new RegExp("^[\\[【(（]\\s*([^\\]】)）]+)\\s*[\\]】)）]\\s*");
export const PLAN_TITLE_PREFIX = new RegExp("^[-–—:：]\\s*");
