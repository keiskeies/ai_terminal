import '../models/runbook.dart';
import 'ui_text.dart';

/// English copy for built-in runbooks.
///
/// Built-ins are seeded into the database once, so translating the stored row
/// would freeze whichever language ran first. Localize on read instead: the
/// persisted row stays untouched, and switching language re-renders it.
class BuiltinRunbookI18n {
  static List<Runbook> localizeAll(List<Runbook> runbooks) =>
      runbooks.map(localize).toList();

  static Runbook localize(Runbook runbook) {
    if (!runbook.isBuiltin) return runbook;
    final name = _names[runbook.id];
    if (name == null) return runbook;
    final description = _descriptions[runbook.id];
    final content = _agentContent[runbook.id];
    final copy = Runbook.create(
      id: runbook.id,
      name: UiText.t(runbook.name, name),
      icon: runbook.icon,
      type: runbook.type,
      category: runbook.category,
      description: description == null
          ? runbook.description
          : UiText.t(runbook.description ?? '', description),
      content: runbook.type == RunbookType.agent && content != null
          ? UiText.t(runbook.content, content)
          : runbook.content,
      isBuiltin: true,
    );
    copy.createdAt = runbook.createdAt;
    copy.updatedAt = runbook.updatedAt;
    copy.runCount = runbook.runCount;
    copy.lastRunAt = runbook.lastRunAt;
    return copy;
  }

  static const Map<String, String> _names = {
    'builtin_health_check': 'Host Inspection',
    'builtin_stack_inspection': 'Stack Inspection',
    'builtin_service_down': 'Service Down Response',
    'builtin_cpu_spike': 'High CPU Investigation',
    'builtin_mem_leak': 'Memory and OOM Investigation',
    'builtin_disk_check': 'Disk Problem Investigation',
    'builtin_slow_query': 'Slow Query Investigation',
    'builtin_app_deploy': 'Application Release',
    'builtin_config_push': 'Config and Certificate Change',
    'builtin_db_backup': 'Database Backup and Restore Drill',
    'builtin_security_audit': 'Security Baseline Audit',
    'builtin_intrusion_detect': 'Intrusion Response',
  };

  static const Map<String, String> _descriptions = {
    'builtin_health_check':
        'Parameterized host inspection: quick reports anomalies only, full adds baseline drift and capacity advice',
    'builtin_stack_inspection':
        'Auto-detect installed components (DB/Redis/Docker/K8s), inspect only what exists, report by severity',
    'builtin_service_down':
        'Evidence-first outage response: branch to root cause, recover with rollback, clear escalation boundary',
    'builtin_cpu_spike':
        'Branch on us/sy/wa to locate the high-CPU root cause, remediate with rollback',
    'builtin_mem_leak':
        'Two entry points: already OOM-killed (after) or memory keeps growing (before), then branch',
    'builtin_disk_check':
        'Decide space-full vs I/O bottleneck first, two remediation branches; cleanup only for regenerable data',
    'builtin_slow_query':
        'Evidence to plan to classification to verifiable optimization advice; never change production indexes directly',
    'builtin_app_deploy':
        'Rollback-safe release: pre-check, pinned version, health gate, auto-rollback on failure',
    'builtin_config_push':
        'Backup, validate, graceful apply, verify, one-step rollback',
    'builtin_db_backup':
        'Consistent backup plus isolated restore drill; a backup is usable only if the restore passes',
    'builtin_security_audit':
        'Read-only audit of SSH/accounts/permissions/firewall/patches/persistence; graded report, no auto-hardening',
    'builtin_intrusion_detect':
        'Forensics and minimal containment on suspected intrusion; preserve evidence, avoid tipping off the attacker',
  };

  static const Map<String, String> _agentContent = {
    'builtin_health_check': 'Host inspection (read-only). Default quick: report anomalies and risks only; when I ask for full, add baseline drift and capacity advice.\n'
        '[Hard constraints]\n'
        '- Read-only throughout: no install, no modify, no restart, no cleanup; report findings as advice only, remediation goes in a separate runbook.\n'
        '- Every conclusion must cite evidence (command output snippets); never conclude from impression.\n'
        '[quick checks]\n'
        '- Load and CPU: uptime, top -bn1 | head -15; separate us/sy/wa\n'
        '- Memory and swap: free -h; sustained swap in/out counts as anomalous\n'
        '- Disk space and inodes: df -h, df -i; >85% warning, >95% critical\n'
        '- Failed services: systemctl --failed; active state and recent error logs for key services\n'
        '- Listening ports: ss -tlnp; flag unexpected listeners that differ from the baseline\n'
        '- Log anomalies: journalctl -p err --since "24 hours ago" --no-pager | tail -50; repeated stacks / crash loops\n'
        '- Certificate expiry: local HTTPS certs and SSH host keys; warn under 30 days\n'
        '- Login security: last -n 10, lastb | tail -10; flag unusual sources\n'
        '[full adds]\n'
        '- Baseline capture: CPU/memory/disk I/O (iostat -x 1 3)/network I/O; compare with the previous baseline (if any) and report drift\n'
        '- Capacity trend: use available history (sar/monitoring) to estimate disk/memory exhaustion time and give scaling thresholds\n'
        '- Patches: list pending security updates (list only, do not install)\n'
        '[Output]\n'
        'List anomalies by critical/warning/info, each with evidence and advice; if none, state explicitly "no anomalies found".\n'
        'full also appends a baseline table and a capacity conclusion.',
    'builtin_stack_inspection': 'Stack inspection (read-only). First detect which components exist on this host, inspect only those; explicitly skip what is not installed, do not error.\n'
        '[Hard constraints] Read-only; no restart, no cleanup, no config change; cleanup and tuning go in a separate runbook.\n'
        '[Detect] command -v mysql psql redis-cli docker kubectl; matching systemctl units; for containerized components check docker ps.\n'
        '[MySQL/PostgreSQL (if present)]\n'
        '- Connections vs max_connections; active sessions / Threads_running\n'
        '- Slow query log toggle and recent top slow queries; tablespace / data directory size\n'
        '- Replication: SHOW REPLICA STATUS / pg_stat_replication lag and errors\n'
        '[Redis (if present)]\n'
        '- used_memory vs maxmemory and eviction policy; key count and expiry distribution\n'
        '- Persistence: last successful RDB/AOF time; hit rate; recent slowlog entries\n'
        '[Docker (if present)]\n'
        '- Containers not Running / repeatedly restarting and their recent logs\n'
        '- Disk: docker system df; reclaimable amount from dangling images / stopped containers / unused volumes (report only, do not clean)\n'
        '- Per-container resource top; containers with health=unhealthy\n'
        '[Kubernetes (if present)]\n'
        '- Node status and resource pressure; Pods not Running/Ready\n'
        '- Deployment rollout status; last 20 Warning events\n'
        '[Output] One section per component, each graded critical/warning/info with evidence and advice; explicitly skip components that are not installed.',
    'builtin_service_down': 'Service outage response. Goal: restore service in the shortest time while preserving traceable root-cause evidence.\n'
        '[Hard constraints]\n'
        '- Evidence first, remediation second. Before any restart/kill/config change, complete the Phase 1 scene snapshot.\n'
        '- One change action at a time, verify immediately after; if ineffective, roll back that action before trying the next hypothesis.\n'
        '- Actions touching production traffic, deleting data, or overwriting config require my confirmation first.\n'
        '- Do not clear logs, reboot the machine, or reinstall the service just to "restore".\n'
        '[Phase 0 scope the impact]\n'
        '- Target: service name, listening port, health check URL.\n'
        '- Blast radius: all or some endpoints/nodes? Since when?\n'
        '- Change window: any release/config/certificate/scaling change in the last 24h? If yes, suspect the change first.\n'
        '[Phase 1 scene snapshot] (read-only, capture once and archive, never overwrite later)\n'
        '- systemctl status <svc> -l --no-pager; journalctl -u <svc> -n 200 --no-pager\n'
        '- ss -tlnp | grep <port>; ps -o pid,ppid,etime,rss,cmd -C <proc>\n'
        '- df -h; free -h; dmesg -T | tail -50 (watch for oom/segfault/filesystem errors)\n'
        '[Phase 2 branch on evidence] (take the matching branch, do not run them all)\n'
        'A process gone / crash-loop -> read exit code and last stack: dmesg has oom-kill -> go to Memory and OOM Investigation;\n'
        '  config error -> C; segfault/core -> preserve core and stack, escalate to human.\n'
        'B process up but not listening / listening but refusing -> distinguish not bound vs bound but not accepting;\n'
        '  connections saturated -> check ulimit/somaxconn/connection leak, raise limits first then hunt the leak.\n'
        'C recent config/release change -> diff the previous version + syntax check; remediation = roll back, not fix forward.\n'
        'D resource exhaustion -> disk full: clean only regenerable data (logs/temp) below threshold, never delete business data;\n'
        '  memory -> go to Memory and OOM Investigation; fd -> /proc/<pid>/limits and fd count.\n'
        'E dependency failure -> minimal connectivity checks against DB/Redis/downstream/DNS; fix the dependency,\n'
        '  do not restart this service hoping for luck.\n'
        'F only some nodes affected -> diff healthy vs faulty nodes (config/version/load/network) to locate the difference.\n'
        '[Phase 3 remediation and rollback]\n'
        '- Record a rollback point before each action (original config backup / original version / original process state).\n'
        '- Priority: roll back the change > clean regenerable resources > raise limits > restart the process (last resort).\n'
        '- Before restart you must already have the Phase 1 snapshot + stack/connection dump.\n'
        '- Verify each step with health URL + port + error rate; not recovered -> roll back that step, return to Phase 2 and switch branch.\n'
        '[Escalation] (any one met: stop auto-remediation, hand to human)\n'
        '- Two branch rounds still not recovered; need to delete data / change production traffic / touch kernel parameters;\n'
        '- Evidence points to intrusion, disk hardware error, or data corruption.\n'
        '[Output]\n'
        'Root cause + evidence chain (which log/metric supports it), actions taken and rollback points, current recovery state,\n'
        'residual risk and long-term fix advice; if not recovered, give the 1-2 hypotheses most worth verifying next.',
    'builtin_cpu_spike': 'High CPU investigation. Goal: locate the root cause and give remediation advice; evidence first, remediation second.\n'
        '[Hard constraints] Snapshot before remediation; one change action at a time and verify; confirm with me before kill/throttle/restart;\n'
        'do not kill business processes directly just to lower CPU.\n'
        '[Phase 1 snapshot] uptime; top -bn1 | head -20 (read us/sy/wa); mpstat -P ALL 1 3 (if available);\n'
        'ps aux --sort=-%cpu | head -10; vmstat 1 5.\n'
        '[Phase 2 branch on us/sy/wa]\n'
        'A us high -> locate process/thread: top -H -p <pid>; Java -> jstack hot stacks + jstat -gcutil\n'
        '  (frequent GC -> go to Memory and OOM Investigation); Python -> py-spy dump (if available); C/Go -> perf top (if available).\n'
        '  Distinguish "normal business peak" from "abnormal loop / infinite loop".\n'
        'B sy high -> context switches / interrupts: vmstat cs/in; pidstat -w 1 3;\n'
        '  look for frequent syscalls / lock contention / short-connection storms; strace -c -p <pid> time-boxed sampling (needs confirmation).\n'
        'C wa high -> go to the I/O branch of Disk Problem Investigation, do not remediate here.\n'
        'D one core saturated, others idle -> single-thread bottleneck / pinning / softirq concentration: compare /proc/interrupts, /proc/softirqs.\n'
        '[Phase 3 remediation and rollback] Prefer reversible: throttle / degrade switch > tune concurrency / thread pool > scale out > restart (last).\n'
        'Record a rollback point each step and verify CPU falls; if ineffective, roll back and switch branch.\n'
        '[Escalation] Two rounds without locating it; need to kill business processes / change kernel parameters; evidence points to intrusion (unusual outbound + high CPU).\n'
        '[Output] Root cause + evidence chain (which thread/stack/metric), actions taken and rollback points, current CPU, long-term fix advice.',
    'builtin_mem_leak': 'Memory and OOM investigation. Two entry points: already OOM-killed (after) or memory keeps growing (before); decide the entry first, then branch.\n'
        '[Hard constraints] Evidence first, remediation second; do not kill business processes or drop_caches just to free memory and mask the problem;\n'
        'confirm before changing limits / restarting.\n'
        '[Phase 1 snapshot] free -h; ps aux --sort=-%mem | head -10;\n'
        'dmesg -T | grep -iE "oom|killed process" | tail -20; cat /proc/meminfo (Slab / page cache);\n'
        'container/cgroup: memory.max and memory.current (if applicable).\n'
        '[Entry decision] dmesg has oom-kill -> entry A; otherwise look at the growth trend -> entry B.\n'
        '[A already OOM-killed]\n'
        '- From the oom log take the killed process / its rss at the time / cgroup limit; confirm whole-host OOM vs cgroup/container limit OOM.\n'
        '- Whole host: who eats the most -> leak or burst; cgroup: limit too low vs real demand.\n'
        '- Remediation: adjust limit / add swap (temporary) / scale out, or fix the leak; preserve a stack before restarting the killed service.\n'
        '[B keeps growing]\n'
        '- Sample rss at intervals (pidstat -r 1 5 or two ps comparisons) to confirm monotonic growth; separate heap / cache / Slab / mmap.\n'
        '- Java -> jmap -histo:live + jstat -gcutil (old gen only grows, never falls -> leak); Go -> pprof heap (if available);\n'
        '  Python -> tracemalloc/objgraph (if available); native -> /proc/<pid>/smaps_rollup compared with pmap.\n'
        '- Distinguish "leak" from "normal cache / no upper bound": bounded and hitting the bound -> config problem; unbounded monotonic growth -> leak.\n'
        '[Phase 3 remediation and rollback] Prefer: set/adjust bounds and eviction policy > fix the leak > rolling restart (temporary stopgap, record rollback point).\n'
        'Verify the rss curve stops rising each step.\n'
        '[Escalation] Need to kill business / change kernel vm parameters; evidence points to a kernel Slab leak; two rounds without locating it.\n'
        '[Output] Entry (A/B) + root cause + evidence chain, killed/growing process, actions taken and rollback points, long-term fix advice.',
    'builtin_disk_check': 'Disk problem investigation. Decide first whether it is "space full" or "I/O bottleneck"; the two remediations are completely different, do not mix them.\n'
        '[Hard constraints] Evidence first, remediation second; before deleting any file you must confirm with me and only regenerable data (logs/temp/cache) is allowed;\n'
        'never delete business data / database files; confirm before changing I/O tuning parameters.\n'
        '[Phase 1 snapshot] df -h, df -i; iostat -x 1 3 (if available);\n'
        'du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20; lsblk;\n'
        'dmesg -T | tail -30 (IO error / ext4 / xfs messages).\n'
        '[Entry decision] usage >90% or inode >90% -> branch S; otherwise %util high / await high -> branch I.\n'
        '[S space full]\n'
        '- Locate top directories/files; separate business data / logs / temp / deleted-but-still-held (lsof +L1).\n'
        '- Deleted but still occupying space -> the holding process has not released it: record the pid, remediation = restart the holder or truncate (needs confirmation), not deleting more files.\n'
        '- Log bloat -> check whether logrotate is broken (config / execution record); remediation = fix rotation + clean expired (confirmed).\n'
        '- inode full -> find directories with massive small files (cache/session); remediation = clean regenerable small files (confirmed).\n'
        '[I I/O bottleneck]\n'
        '- await high + %util high -> device saturated; await high + %util not high -> device/link anomaly (dmesg errors).\n'
        '- Locate the I/O process: pidstat -d 1 3 / iotop (if available); separate read-heavy / write-heavy / frequent fsync.\n'
        '- Remediation: stagger / throttle background jobs > tune dirty-page / scheduler parameters (confirmed) > faster storage / scale out;\n'
        '  frequent database fsync -> go to Slow Query Investigation to check transactions / indexes.\n'
        '[Phase 3 rollback] Record a rollback point for each cleanup/parameter action (cleanup list / original parameters);\n'
        'verify usage drops or await falls; if ineffective, roll back and switch branch.\n'
        '[Escalation] Need to delete business data; dmesg has hardware I/O errors / filesystem corruption; two rounds without relief.\n'
        '[Output] Entry (S/I) + root cause + evidence, top consumers / I/O processes, actions taken and rollback points, long-term advice (rotation / scale-out / archiving).',
    'builtin_slow_query': 'Slow query investigation. Goal: find the queries most worth optimizing and give a verifiable optimization plan; never change production indexes directly.\n'
        '[Hard constraints] Read-only evidence gathering; use read-only EXPLAIN; before adding indexes / changing SQL / changing parameters you must confirm with me and run off-peak;\n'
        'do not run full-table-scan analysis on a business database.\n'
        '[Phase 1 evidence] Confirm the engine (MySQL/PG); slow log toggle and threshold;\n'
        'recent top slow queries (sorted by both total time and average time); current active slow sessions (SHOW PROCESSLIST / pg_stat_activity).\n'
        '[Phase 2 analysis] For the top 3-5:\n'
        '- Execution plan: EXPLAIN (ANALYZE only for read-only select and confirmed); look for full scan / filesort / temp table / row-estimate skew.\n'
        '- Classify: missing index / index defeated (function / implicit cast / leading wildcard) / too many rows returned / lock wait / stale statistics / N+1.\n'
        '- Lock wait -> inspect the blocking chain (innodb_trx / pg_locks); the remediation target is the blocking transaction, not the query itself.\n'
        '[Phase 3 advice and verification] For each give: the optimization (index DDL / SQL rewrite / parameter), expected gain, risk;\n'
        'after confirmation run off-peak, and verify by comparing time / rows scanned for the same query before and after; if ineffective roll back (drop the new index / restore the SQL).\n'
        '[Escalation] Need to change production schema with no off-peak window; evidence points to frequent locks/deadlocks; statistics / hardware level problems.\n'
        '[Output] Top slow query list (time / count / plan summary), root-cause classification, verified optimizations and gains, unexecuted advice and risks.',
    'builtin_app_deploy': 'Application release. Goal: complete a rollback-safe release; it counts as success only when the health gate passes.\n'
        '[Hard constraints] Before release you must confirm the target version/artifact and the rollback version; any step failing triggers immediate rollback, never "ship while sick";\n'
        'confirm before switching production traffic.\n'
        '[Phase 0 pre-check] Current version and running state; enough disk/memory headroom to build/pull; dependency services reachable;\n'
        'confirm the rollback artifact / image tag is available; back up the current config and artifact pointer.\n'
        '[Phase 1 release] Pull/build the pinned version (do not chase latest); verify the artifact (checksum / image digest); canary or single node first (if applicable).\n'
        '[Phase 2 health gate] After restart/switch: process active + port listening + health URL 2xx + no new anomalies in error rate/logs,\n'
        'observation window (default 60s); any miss -> judged failed.\n'
        '[Phase 3 rollback] On failure -> restore the previous artifact/config pointer -> restart -> re-run the health gate;\n'
        'still failing after rollback -> stop auto-remediation and escalate to human.\n'
        '[Output] Released version / rollback point, each health gate result, whether rolled back and why, residual risk. Even on success provide a rollback command for standby.',
    'builtin_config_push': 'Config/certificate change. Goal: apply one change with backup and validation, with one-step rollback on failure.\n'
        '[Hard constraints] Back up before modifying; reload only after syntax/chain validation passes; use graceful reload rather than restart (if supported);\n'
        'confirm before overwriting production config.\n'
        '[Phase 0] Confirm the change target (file path / domain) and intended content; back up the current file/certificate to a timestamped copy (record the rollback point).\n'
        '[Phase 1 validation] Config: nginx -t / apachectl configtest / the service built-in -t;\n'
        'certificate: openssl x509 -noout -dates -subject + private key match (modulus/pubkey comparison) + complete chain.\n'
        '[Phase 2 apply] Write the new config/certificate -> reload -> verify: service active + health URL + certificate s_client chain/expiry + spot-check the applied config items.\n'
        '[Phase 3 rollback] Verification fails -> restore the backup -> reload -> re-verify; still failing -> escalate to human.\n'
        '[Output] Change summary, backup/rollback point, validation and verification results, new certificate expiry date, whether rolled back.',
    'builtin_db_backup': 'Database backup and restore drill. A backup file existing does not mean the backup is usable; it is complete only when the restore drill passes.\n'
        '[Hard constraints] Use a consistent backup method (mysqldump --single-transaction / pg_dump / xtrabackup if applicable);\n'
        'the restore drill must run on an isolated instance / temporary directory, never overwrite the production database; confirm before deleting old backups.\n'
        '[Phase 1 backup] Confirm engine / data size / target path and free space; run a consistent backup; record checksum + size + duration.\n'
        '[Phase 2 verification] Compare checksums; restore to an isolated instance / temporary directory;\n'
        'run row-count / key-table checksum spot checks + application read-only connectivity verification; record restore duration (RTO reference).\n'
        '[Phase 3 retention] Find gaps against the expected schedule; list expirable old backups (list only, do not delete); give retention / off-site advice.\n'
        '[Escalation] Restore drill fails (backup unusable) -> alert immediately and stop overwriting subsequent backups; insufficient space; need to touch the production database.\n'
        '[Output] Backup path/size/checksum, restore drill result and duration, schedule gaps, retention advice. State an explicit "backup usable / unusable" conclusion.',
    'builtin_security_audit': 'Security baseline audit (read-only). Covers SSH/accounts/permissions/firewall/patches/persistence, produces a graded report, no auto-hardening.\n'
        '[Hard constraints] Read-only throughout; do not print password hashes / private key contents; do not change any config/rule/account; hardening advice is executed separately after confirmation.\n'
        '[Checks]\n'
        '- SSH: root login / password login / port / AllowUsers; unexpected new authorized_keys\n'
        '- Accounts: empty passwords / non-root UID0 / list of accounts with a login shell; sudoers and wheel/sudo members\n'
        '- Permissions: SUID/SGID list compared against distro defaults to flag unexpected items; recently modified files in /etc /bin /usr/bin\n'
        '- Firewall: default policy / open ports and owners / overly broad rules (0.0.0.0/0 high-risk ports)\n'
        '- Persistence: per-user crontab + /etc/cron.* + systemd timers, flag suspicious/unfamiliar entries\n'
        '- Patches: list pending security updates (list only, do not install); whether a reboot is needed\n'
        '- Logins: lastb brute-force sources / unusual sources and times of successful logins\n'
        '[Output] Grade by critical/warning/info, each with evidence and hardening advice (include commands but do not execute); give an overall risk conclusion.\n'
        'State explicitly that nothing was modified.',
    'builtin_intrusion_detect': 'Intrusion response. Forensics and containment on suspected intrusion; preserve evidence first, avoid tipping off the attacker.\n'
        '[Hard constraints] Evidence first, containment second; do not restart/clean/antivirus (it destroys evidence and may trigger attacker self-destruct);\n'
        'you must confirm with me before isolating the network / blocking IPs / changing credentials; do not print plaintext credentials.\n'
        '[Phase 1 forensic snapshot] (read-only, archive)\n'
        '- Logins: last/lastb/w; unusual sources/times/accounts\n'
        '- Processes: full ps auxf tree; hidden-process comparison (/proc walk vs ps); unusual outbound ss -tnp\n'
        '- Persistence: crontab/systemd timers/rc.local/authorized_keys/ld.so.preload\n'
        '- Files: recent additions/modifications in /etc /bin /usr/bin /tmp /dev/shm; unusual SUID; webshell-characteristic directories\n'
        '- Logs: auth/secure/journal login and privilege-escalation traces; whether logs were cleared/truncated (itself an indicator)\n'
        '[Phase 2 assessment] Aggregate IOCs (malicious IP/domain/file hash/unusual account); separate false positive / scan noise / real intrusion; give a confidence level.\n'
        '[Phase 3 containment (confirmed)] Prefer reversible: block IOCs at security group/firewall > disable unusual accounts / remove authorized_keys > isolate host network;\n'
        'record a rollback point each step; preserve memory/disk evidence before considering reinstall.\n'
        '[Escalation] Real intrusion confirmed -> hand to human/security team immediately, this playbook only does forensics and minimal containment; data exfiltration involved -> compliance process.\n'
        '[Output] IOC list + evidence chain, confidence level, containment taken and rollback points, impact assessment, follow-up eradication/recovery advice.',
  };
}
