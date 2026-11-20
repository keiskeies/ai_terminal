#!/usr/bin/env python3
"""终态写入点棘轮检查（R5 终态一致性的过渡性护栏）。

背景
----
深度分析报告 §7 要求「除 TerminationGuard 外禁止直接给
AgentStatus.completed|failed|cancelled 赋值」。

TerminationGuard 已落地（阶段 A/B/C）：engine 7 条裸写终态路径与
provider 2 处 UI 终态写入均已收口。本脚本由「棘轮」切换为**硬禁令**：
基线 0，lib/ 下任何绕过 Guard 的裸写终态赋值都会令 CI 失败。

合法收口入口（不计入裸写）：
- engine: `_terminationGuard.terminate(status: ...)`
- provider UI 态: `_uiTerminationGuard.resolveUiStatus(...)`

计数口径：lib/ 下形如 `status: ... AgentStatus.(completed|failed|cancelled)` 的
写入（copyWith / 构造器），排除 `==`、`case`、`?.status` 等只读比较。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# 硬禁令：TerminationGuard 阶段 C 完成后裸写终态必须为 0
# 2026-11-20 演进：10 → 8（阶段A）→ 2（阶段B engine 收口）→ 0（阶段C provider 收口）
BASELINE = 0

# 匹配终态写入：status: <expr>AgentStatus.<terminal>
WRITE_RE = re.compile(
    r"status:\s*[^,\n)]*?AgentStatus\.(completed|failed|cancelled)\b"
)
# 明显是读/比较的行，排除
READ_HINTS = ("==", "!=", "case ", "?.")


def count_writes(lib_dir: Path) -> list[str]:
    hits: list[str] = []
    for path in sorted(lib_dir.rglob("*.dart")):
        lines = path.read_text(encoding="utf-8").splitlines()
        # 跟踪 TerminationGuard.terminate(...) 的多行调用块：块内的 status: 是收口参数
        in_terminate = False
        terminate_depth = 0
        for lineno, line in enumerate(lines, 1):
            stripped = line.strip()
            if ".terminate(" in stripped and not in_terminate:
                in_terminate = True
                terminate_depth = line.count("(") - line.count(")")
            elif in_terminate:
                terminate_depth += line.count("(") - line.count(")")
                if terminate_depth <= 0:
                    in_terminate = False

            # 经 TerminationGuard 收口的写入（engine terminate / UI resolveUiStatus）不算裸写
            via_guard = in_terminate or ".resolveUiStatus(" in stripped
            if WRITE_RE.search(line) and not via_guard:
                # 排除以比较/switch 形式出现的误命中
                if any(hint in stripped for hint in READ_HINTS) and "status:" not in stripped:
                    continue
                hits.append(f"{path.as_posix()}:{lineno}: {stripped}")
    return hits


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    lib = repo / "ai_terminal" / "lib"
    if not lib.is_dir():
        print(f"::error::找不到 lib 目录: {lib}")
        return 2

    hits = count_writes(lib)
    n = len(hits)
    print(f"终态写入点: {n}（基线 {BASELINE}）")
    for h in hits:
        print(f"  {h}")

    if n > BASELINE:
        print(
            "::error::发现绕过 TerminationGuard 的裸写终态赋值。"
            "请改用 _terminationGuard.terminate(...)（engine）或 "
            "_uiTerminationGuard.resolveUiStatus(...)（provider UI 态）。"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
