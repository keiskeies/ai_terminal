#!/usr/bin/env python3
"""终态写入点棘轮检查（R5 终态一致性的过渡性护栏）。

背景
----
深度分析报告 §7 要求「除 TerminationGuard 外禁止直接给
AgentStatus.completed|failed|cancelled 赋值」。但 TerminationGuard 尚未实现，
当前引擎/ provider 内有若干**合法**的直接终态写入。此刻就上硬性禁令会全红。

本脚本采用「棘轮（ratchet）」策略：把当前终态写入点数量记为基线，
CI 中若发现**新增**写入点即失败，防止在 TerminationGuard 落地前写入点继续扩散。
等 TerminationGuard 收口后，把基线逐步降到 0 并切换为硬禁令即可。

计数口径：lib/ 下形如 `status: ... AgentStatus.(completed|failed|cancelled)` 的
写入（copyWith / 构造器），排除 `==`、`case`、`?.status` 等只读比较。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# 当前合法基线（2026-11-20 实测：engine 8 + provider 2）
BASELINE = 10

# 匹配终态写入：status: <expr>AgentStatus.<terminal>
WRITE_RE = re.compile(
    r"status:\s*[^,\n)]*?AgentStatus\.(completed|failed|cancelled)\b"
)
# 明显是读/比较的行，排除
READ_HINTS = ("==", "!=", "case ", "?.")


def count_writes(lib_dir: Path) -> list[str]:
    hits: list[str] = []
    for path in sorted(lib_dir.rglob("*.dart")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if WRITE_RE.search(line):
                # 排除以比较/switch 形式出现的误命中
                stripped = line.strip()
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
            "::error::终态写入点超过基线。TerminationGuard 收口前请复用现有终态路径；"
            "如确需新增，先更新 BASELINE 并说明理由。"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
