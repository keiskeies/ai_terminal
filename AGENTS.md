# AGENTS.md

## Project overview

Flutter (Dart) cross-platform terminal app with AI agent integration. AI assistant generates and executes shell commands over SSH or local PTY.

## Critical: project root

The Flutter project lives in `ai_terminal/`, **not** the repo root. All `flutter` and `dart` commands must run from `ai_terminal/`.

## Setup & build

```bash
cd ai_terminal
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # required: generates Hive adapters
flutter run
```

Generated files (`*.g.dart`, `*.freezed.dart`) are gitignored. After cloning, always run `build_runner` before building.

## Key commands

| Task | Command (from `ai_terminal/`) |
|---|---|
| Run | `flutter run` |
| Analyze | `flutter analyze` |
| Test | `flutter test` |
| Build (current platform) | `./build_all.sh current` |
| Build (all platforms) | `./build_all.sh all` |
| Regenerate Hive adapters | `dart run build_runner build --delete-conflicting-outputs` |
| Rebuild knowledge DB | `python3 tools/csv_to_knowledge.py ai_terminal/assets/knowledge/knowledge.csv ai_terminal/assets/knowledge/knowledge.db` (from repo root) |

## Architecture

- **State management**: Riverpod (`flutter_riverpod`)
- **Routing**: GoRouter
- **Local storage**: Hive (generated adapters) + flutter_secure_storage (credentials)
- **SSH**: dartssh2 with connection pooling (`ssh_connection_pool.dart`)
- **Local terminal**: flutter_pty
- **Terminal UI**: xterm.dart
- **AI**: OpenAI-compatible API via Dio
- **Knowledge base**: SQLite FTS5 full-text search (`knowledge_service.dart`)

Entry point: `ai_terminal/lib/main.dart`

## Platform build notes

- **Linux**: requires system packages: `libgtk-3-dev libblkid-dev liblzma-dev ninja-build libgcrypt20-dev libsecret-1-dev libjsoncpp-dev`
- **Android**: CI patches Flutter's `settings.gradle.kts` to add `gradlePluginPortal()` — local builds may need this manually
- **iOS**: requires macOS + valid developer certificate for release builds

## Knowledge base workflow

1. Edit CSV: `ai_terminal/assets/knowledge/knowledge.csv`
2. Convert to SQLite: `python3 tools/csv_to_knowledge.py <csv> <db>`
3. The `.db` file is bundled as a Flutter asset

## CI

GitHub Actions (`.github/workflows/build-release.yml`) triggers on `v*` tags. Builds for macOS, iOS, Android, Windows, Linux and creates a GitHub Release with artifacts.

## Conventions

- Dark theme only (for now)
- Dart analysis uses `flutter_lints` (default rules, no custom overrides)
- Comments and UI text are primarily in Chinese

## Engineering rules (derived from past bugs)

The following rules are distilled from real bugs found in code review. Each rule is mandatory; violating it has historically caused data corruption, deadlocks, or state machine corruption.

### R1. Async cancellation & generation checks

- **Every `await` that may cross a task boundary MUST be followed by a generation check.** `await` yields control; a new task or `cancelTask` can run during that gap. After the `await` resumes, verify `myGeneration == _currentTaskGeneration` before touching `_currentTask` or `_conversationHistory`. Missing this has caused old-task state to overwrite new-task state.
- **`StreamSubscription.cancel()` does NOT trigger `onDone`.** When you cancel a stream subscription from outside the listen callback (e.g. in `cancelTask` or a watchdog timer), you MUST also manually `complete()` any `Completer<void>` that was waiting on the stream's `onDone`. Otherwise the awaiter hangs forever. This is the #1 cause of `_callAI` permanent hangs.
- **Every `.then()` on an async future MUST have an `onError` handler** (or be wrapped in try/catch). An unhandled rejection leaves any linked `Completer` forever incomplete, deadlocking the ReAct loop.
- **Do not swallow exceptions in `catch` blocks.** A caught error must either be rethrown, logged with context, or translated into a failed task state. Bare `break`/`return` after `onError?.call(...)` leaves the task in a wrong terminal state.

### R2. Resource lifecycle

- **Whoever creates a resource owns its cleanup.** If you create a `Service`/`Engine`/`Subscription`/`Timer` inside a method, that method (or its `finally` block) is responsible for disposing it on all paths (success, error, cancel, timeout). Leaked SSH connections and orphaned subscriptions have historically caused resource exhaustion.
- **Clear callbacks BEFORE calling `cancel()`.** `cancelTask()` synchronously fires `onTaskUpdated`, which invokes still-bound callbacks. If you clear callbacks after `cancel()`, the cancel-triggered callback writes stale state. Order: null all callbacks → `cancelTask()` → remove from registry.
- **Flush in-flight state BEFORE nulling callbacks that carry it.** Clearing a callback silently cuts its implicit responsibilities. `cancelTask` relies on `onCompleted` to flush in-flight streaming content to `content` and persistence; `onEvent`/`onTaskUpdated` carry state writes. If you null `onCompleted` before `cancelTask` (e.g. to prevent cross-host state writes during `switchTab`/`init` model switch), the flush never fires, and the subsequent `_reducer.reset()` or the new engine's `onThinking` silently drops the streaming content the user was just reading. Order: flush streaming → null callbacks → `cancelTask()` → reset reducers. This applies to `switchTab`, `init` (model switch), `removeTab`, and any path that nulls callbacks before cancel.
- **Guard `StreamController.add` with `isClosed`.** Calling `add` on a closed controller throws `StateError`. Any `onDone`/`onError` callback that writes to a controller MUST check `!controller.isClosed` first. This commonly fires when `dispose()` closes the controller while a session `onDone` microtask is pending.

### R3. Multi-host / session isolation

- **Never substitute `activeHostId` for the task's owning host.** A long-running task captures its host at start; by the time it finishes, the user may have switched tabs. `_maybeAutoCompact`, `compact`, and any post-task cleanup MUST use the captured host id, not `_registry.activeHostId`. Using the wrong host has caused the wrong conversation to be summarized and the active host's state to be overwritten.
- **Switching session/tab MUST cancel the running task and reset the reducer first.** Before loading new session state, call `cancelTask()` + `_reducer.cancelTimer()` + `_reducer.reset()`. Otherwise in-flight events and streaming chunks from the old task pollute the new session's UI.
- **Update non-active host state via `_updateHostState(hostId, ...)`, never via direct `state = ...`.** Direct `state =` always writes to the active host. Writing to a non-active host's data via `state =` overwrites the active host — a silent, unrecoverable data corruption.

### R4. Event IDs & deduplication

- **Deduplicate events by `stableId` (content hash), never by `finalId` (sequence).** `finalId` changes every call; using it for dedup means every emission looks unique and duplicates fire. Capture the `stableId` BEFORE calling `assignFinalId` (which mutates `e.id`).
- **When multiple commands exist, associate each result with its OWN command id.** Do not use a single `_lastCommandEventId` for all results — it gets overwritten to the last command, mis-linking every result card to the wrong command.
- **Hash functions for dedup must have low collision.** `h * 31 + b` over int32 collides on short, similar content. If correctness depends on uniqueness, use a cryptographic hash (sha1/sha256) or a wider digest.

### R5. State machine consistency

- **AI/async errors → `failed`, never `completed`.** An exception in `_callAI` or command execution means the task did not succeed. Marking it `completed` lies to the UI and the user. The only terminal states for a normally-ended task are `completed` (AI said finish) or `failed` (error/cancel).
- **All terminal paths MUST behave consistently.** Whether the task ends by AI `finish`, max-steps exhaustion, no-command retry exhaustion, or error — every path must: (1) set a terminal status, (2) emit a `finish` event, (3) call `onCompleted` to flush streaming content. Divergent paths cause UI to get stuck in "running" or lose the last streaming chunk.
- **Retry/step counters MUST reset on success.** A "no-command retry count" that only increments and never resets will eventually trigger false termination on long tasks where intermittent no-command responses are normal. Reset to 0 after every successful command execution.
- **Do not mutate shared history before the generation check.** Adding an AI response to `_conversationHistory` before checking `myGeneration` pollutes the new session's history with the old task's response. Always: generation check → cancel check → then mutate history.
- **Whitelist over blacklist for terminal-state gating.** `!isCancelled` is a blacklist — it silently admits `failed` and any future terminal state. Use `status == completed` (whitelist) when gating "should record/side-effect" (e.g. recording a learning entry to the knowledge base). `cancelTask`, `_finishTask(success:false)`, and `maxSteps` exhaustion ALL invoke `onCompleted` to flush streaming content; a blacklist gate like `if (!isCancelled) recordLearning()` lets `failed` paths pollute the knowledge base with incomplete tasks. When a new terminal state is added later, whitelist gates automatically skip it; blacklist gates silently admit it.
- **When fixing a side-effect on one path, enumerate ALL paths that invoke the same callback.** `onCompleted` is called from `cancelTask`, `_finishTask(success:true)`, `_finishTask(success:false)`, and `maxSteps` exhaustion. A side-effect fix that only considers `cancelTask` (e.g. adding `if (!isCancelled)` to block knowledge-base pollution) leaves `failed` paths still polluting. Before merging any side-effect fix, grep every caller of the callback/method and verify each terminal path's behavior against the fix. Side-effects to check: knowledge-base writes, persistence, notifications, audit logs, telemetry.

### R6. Cross-platform compatibility

- **Shell command wrappers MUST branch by shell type.** PowerShell uses `;` as separator and `$LASTEXITCODE` for exit codes; cmd.exe uses `&` and `%errorlevel%`; bash uses `;` and `$?`. Using one shell's syntax on another causes `executeAndWait` to hang forever (marker never matches). Detect the shell at startup and branch in `wrappedCommand`.
- **Timeouts must fit the command.** A 5s timeout for `systeminfo` (10-30s typical) guarantees failure. A 60s hard timeout for `apt install` on a slow link guarantees false-failure loops. Choose per-command-class timeouts, or surface a configurable default.
- **Do not hardcode locale-specific text matching.** `findstr /C:"OS Name"` returns nothing on a Chinese Windows (`操作系统名称`). Use locale-neutral commands (PowerShell `Get-CimInstance` + property names) or match by structure, not by localized label.
- **Use `p.posix.join`/`p.posix.dirname` for REMOTE paths, `p.join`/`p.basename` for LOCAL paths.** SFTP paths are always POSIX regardless of the client OS. Mixing them on Windows produces backslash-separated remote paths that break.

### R7. Security

- **IVs must be cryptographically random, never time-derived.** `DateTime.now().microsecondsSinceEpoch` is predictable and, when combined with bit-truncation (`>> (i % 8)`), produces only 8 unique bytes in a 16-byte IV. Use `IV.fromSecureRandom(16)`.
- **Never store plaintext credentials.** The credentials store must always go through `flutter_secure_storage` first, with an AES-encrypted Hive fallback (random IV per record) for platforms where Keychain is unavailable.
- **Avoid `keychain-access-groups` in entitlements unless a shared keychain is required.** A mismatch between entitlements `keychain-access-groups` and `MacOsOptions.groupId` silently breaks secure storage on macOS.

### R8. Defensive coding

- **Marker/delimiter detection must use the full expected pattern, not a bare substring.** A bare `EXITCODE_N:` substring matches the PTY command echo (where `$?` is literal) and fires completion before the command runs. Match `EXITCODE_N:\d+` (marker + actual exit code digits) so the literal echo is rejected.
- **All unbounded buffers MUST have a cap.** `_accumulatedMessage`, output buffers, and conversation history grow without bound on long tasks. Enforce a character/line cap and retain the TAIL (most recent), not the head. When truncating, check the boundary condition where length equals the cap exactly (off-by-one retains head instead of tail).
- **Double-cleaning output removes real content.** If `executeAndWait` already strips the command echo and prompt, do NOT call `stripCommandEcho` again in the caller — the second pass may match and delete actual output whose first line resembles the command. Clean once, at one layer.
- **`isQueryCommand` must not grant unlimited output.** "Query" commands like `cat huge_file` or `journalctl` can produce MBs. Even for query commands, enforce a large but finite cap (e.g. 20000 chars) before adding to history or emitting to UI.
- **Every new Hive-storable class/enum MUST have its adapter registered in `HiveInit.init()`, in dependency order.** A model that references another custom type (e.g. `ConvMessage.events: List<AgentEvent>?`) requires both adapters registered, with the dependency first. An unregistered adapter throws `HiveError: Cannot write, unknown type` at serialization time. If the failing write is wrapped in `try/catch` (as persistence calls usually are), the error is silently swallowed and data is lost with no UI symptom. After adding any `@HiveType` class or enum, immediately: (1) run `dart run build_runner build --delete-conflicting-outputs` to generate the adapter, (2) add `Hive.registerAdapter(XxxAdapter())` to `hive_init.dart` in dependency order, (3) run the app and verify a round-trip write/read.
- **Persistence failures MUST surface, not be silently swallowed.** A bare `catch (e) { debugPrint(...) }` around a storage write hides data loss behind a log line nobody reads. Persistence calls must either rethrow, set an error state visible to the UI, or at minimum log at `error`/`warn` level with enough context (hostId, conversationId, operation) to diagnose. The only acceptable silent catch is for truly idempotent re-tries.

### R9. API contract changes & end-to-end testing

- **Changing an API contract MUST grep every caller and verify each one.** When a utility/parser returns `Map<String, dynamic>` and you change the value types it produces (e.g. `String "web1,web2"` → `List<String> ['web1','web2']`), every caller that does `args['key']?.toString()` or `is List || is String` is now a potential bug. Rule: `grep -rn "args\['key'\]"` for every changed key, and confirm each caller handles the new type. This is the same principle as R5's "enumerate all paths that invoke the same callback" — applied to data contracts instead of control flow. Historical bug: `exec_batch` used `args['hostIds']?.toString()` which serialized `List` to `[web1, web2]`, then `split(',')` produced `['[web1', ' web2]']` with brackets — every batch execution failed.
- **Provide typed accessors when the contract returns `dynamic`.** A parser returning `Map<String, dynamic>` forces every caller to do its own `is List || is String` coercion. Inevitably one caller forgets, producing silent data corruption. Always provide typed helpers (`getString`, `getStringList`, `getBool`, `getInt`) and make them the only sanctioned way to access values. Ban direct `args['key']` access in tool implementations.
- **Unit tests are not enough for stream/format changes — add end-to-end tests.** Each component (parser, accumulator, formatter) can pass its own unit tests while the assembled pipeline is broken. Historical bugs:
  - `toReActText` produced correct multi-line output, but when concatenated with a prior thought chunk (`fullResponse += chunk`) it became `"好的，我来执行工具动作: tool\n..."` — no standalone `动作:` line, so `_parseReActResponse` silently dropped the tool call.
  - `_parseReActResponse` had `工具:` in its break condition, making the `工具:` parsing branch dead code — `toolName` was always null. Parser unit tests passed; the integration was broken.
  - Rule: any change to streaming text format, parser output, or the `ReAct text → parse → tool call` pipeline MUST add an end-to-end test that exercises: real input shape → text generation → concatenation → parsing → expected `toolName`/`toolArgs`. See `test/react_parse_e2e_test.dart` for the pattern.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **ai_terminal** (4289 symbols, 9370 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/ai_terminal/context` | Codebase overview, check index freshness |
| `gitnexus://repo/ai_terminal/clusters` | All functional areas |
| `gitnexus://repo/ai_terminal/processes` | All execution flows |
| `gitnexus://repo/ai_terminal/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
