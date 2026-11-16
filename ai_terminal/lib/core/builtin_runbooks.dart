import '../models/runbook.dart';
import '../services/daos.dart';

/// 内置运维工作流模板（精简版：12 条决策驱动 playbook）
///
/// 设计原则：证据先行、按证据分支、处置带回滚点、明确升级边界；
/// 巡检/审计类只读出报告，故障/变更类才允许处置。
/// 首次安装或升级时写入数据库；升级时退役已下线模板、刷新保留模板。
class BuiltinRunbooks {
  static List<Runbook> get all => [
    Runbook.create(
      id: 'builtin_health_check',
      name: '主机巡检',
      icon: '🩺',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '参数化主机巡检：quick 只报异常，full 加基线对比与容量建议',
      content: '主机巡检（只读）。默认 quick：只报异常与风险；我指定 full 时追加基线对比与容量建议。\n'
          '【硬性约束】\n'
          '- 全程只读：不安装、不修改、不重启、不清理；发现问题只给建议，处置另开工作流。\n'
          '- 每项结论必须附证据（命令输出片段），不得凭印象下结论。\n'
          '【quick 检查项】\n'
          '- 负载与 CPU：uptime、top -bn1 | head -15；区分 us/sy/wa\n'
          '- 内存与 swap：free -h；swap 持续换入换出视为异常\n'
          '- 磁盘空间与 inode：df -h、df -i；>85% 预警、>95% 告警\n'
          '- 失败服务：systemctl --failed；关键服务 active 状态与最近错误日志\n'
          '- 监听端口：ss -tlnp；标出与预期不符的意外监听\n'
          '- 日志异常：journalctl -p err --since "24 hours ago" --no-pager | tail -50；重复堆栈/崩溃循环\n'
          '- 证书到期：本机 HTTPS 证书与 SSH host key；<30 天预警\n'
          '- 登录安全：last -n 10、lastb | tail -10；标出异常来源\n'
          '【full 追加项】\n'
          '- 基线采集：CPU/内存/磁盘IO(iostat -x 1 3)/网络IO；与上次基线(如有)对比给出漂移\n'
          '- 容量趋势：结合可用历史(sar/监控)估算磁盘/内存耗尽时间，给扩容阈值建议\n'
          '- 补丁：待安装安全更新清单（只列不装）\n'
          '【输出】\n'
          '按 严重/警告/提示 分级列异常，每项附证据与建议；无异常明确说"未发现异常"。\n'
          'full 另附基线表与容量结论。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_stack_inspection',
      name: '组件巡检',
      icon: '📦',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '自动探测已安装组件（DB/Redis/Docker/K8s），只查存在的并分级报告',
      content: '组件巡检（只读）。先探测本机存在哪些组件，只检查存在的；未安装的明确跳过，不要报错。\n'
          '【硬性约束】只读；不重启、不清理、不改配置；清理与调优另开工作流。\n'
          '【探测】command -v mysql psql redis-cli docker kubectl；systemctl 对应 unit；容器化组件看 docker ps。\n'
          '【MySQL/PostgreSQL（如存在）】\n'
          '- 连接数 vs max_connections；活跃会话/Threads_running\n'
          '- 慢查询开关与最近 top 慢查询；表空间/数据目录大小\n'
          '- 主从：SHOW REPLICA STATUS / pg_stat_replication 的延迟与错误\n'
          '【Redis（如存在）】\n'
          '- used_memory vs maxmemory 与淘汰策略；key 数量与过期分布\n'
          '- 持久化：RDB/AOF 最近成功时间；命中率；slowlog 最近条目\n'
          '【Docker（如存在）】\n'
          '- 非 Running/反复 restart 的容器及其最近日志\n'
          '- 磁盘：docker system df；悬空镜像/停止容器/未用卷的可回收量（只报不清）\n'
          '- 单容器资源占用 top；health=unhealthy 的容器\n'
          '【Kubernetes（如存在）】\n'
          '- Node 状态与资源压力；非 Running/Ready 的 Pod\n'
          '- Deployment rollout 状态；最近 20 条 Warning events\n'
          '【输出】按组件分节，每节 严重/警告/提示 分级 + 证据 + 建议；未安装组件明确跳过。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_service_down',
      name: '服务不可用排查',
      icon: '🚨',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '证据先行的服务不可用应急处置：分支定位、带回滚恢复、明确升级边界',
      content: '服务不可用应急处置。目标：最短时间恢复服务，同时保留可追溯的根因证据。\n'
          '【硬性约束】\n'
          '- 先取证、后处置。任何 restart/kill/改配置前，必须先完成阶段 1 现场快照。\n'
          '- 一次只做一个变更动作，做完立即验证；无效则回滚该动作再试下一个假设。\n'
          '- 涉及生产流量、删数据、覆盖配置的动作，先向我确认再执行。\n'
          '- 不得为"恢复"而清日志、重启机器或重装服务。\n'
          '【阶段 0 界定影响】\n'
          '- 对象：服务名、监听端口、健康检查 URL。\n'
          '- 影响面：全量还是部分接口/节点？从何时开始？\n'
          '- 变更窗口：近 24h 有无发布/配置/证书/扩缩容变更？有→优先怀疑变更。\n'
          '【阶段 1 现场快照】（只读，一次性采集并归档，后续不得覆盖）\n'
          '- systemctl status <svc> -l --no-pager；journalctl -u <svc> -n 200 --no-pager\n'
          '- ss -tlnp | grep <port>；ps -o pid,ppid,etime,rss,cmd -C <proc>\n'
          '- df -h；free -h；dmesg -T | tail -50（关注 oom/segfault/文件系统错误）\n'
          '【阶段 2 按证据分支】（命中即走对应分支，不要全跑）\n'
          'A 进程不存在/crash-loop → 看退出码与最后堆栈：dmesg 有 oom-kill→转内存与OOM排查；\n'
          '  配置报错→C；segfault/core→保留 core 与堆栈，升级人工。\n'
          'B 进程在但不监听/监听但拒连 → 区分没 bind 与 bind 不 accept；\n'
          '  连接打满→查 ulimit/somaxconn/连接泄漏，先调限制再查泄漏。\n'
          'C 近期有配置/发布变更 → diff 上一版本+语法校验；处置=回滚，而非向前修。\n'
          'D 资源耗尽 → 磁盘满只清理可再生数据(日志/临时)到阈值下，禁删业务数据；\n'
          '  内存→转内存与OOM排查；fd→/proc/<pid>/limits 与 fd 计数。\n'
          'E 依赖故障 → 对 DB/Redis/下游/DNS 做最小连通验证；依赖坏了就处置依赖，\n'
          '  不要重启本服务碰运气。\n'
          'F 仅部分节点异常 → 对比健康/故障节点差异(配置/版本/负载/网络)定位差异点。\n'
          '【阶段 3 处置与回滚】\n'
          '- 每个动作执行前记录回滚点(原配置备份/原版本/原进程状态)。\n'
          '- 优先级：回滚变更 > 清理可再生资源 > 调整限制 > 重启进程(最后手段)。\n'
          '- 重启前必须已有阶段 1 快照+堆栈/连接 dump。\n'
          '- 每步用健康 URL+端口+错误率验证；未恢复→回滚该步，回阶段 2 换分支。\n'
          '【升级条件】（任一满足即停自动处置，交人工）\n'
          '- 两轮分支处置仍未恢复；需删数据/改生产流量/动内核参数；\n'
          '- 证据指向入侵、磁盘硬件错误、数据损坏。\n'
          '【输出】\n'
          '根因+证据链(哪条日志/指标支撑)、已执行动作与回滚点、当前恢复状态、\n'
          '遗留风险与长期修复建议；未恢复时给出下一步最该验证的 1-2 个假设。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cpu_spike',
      name: 'CPU 飙高排查',
      icon: '🔥',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '按 us/sy/wa 分支定位高 CPU 根因，处置带回滚',
      content: 'CPU 飙高排查。目标：定位根因并给出处置建议，先取证后处置。\n'
          '【硬性约束】先快照后处置；一次一个变更动作并验证；kill/限流/重启前先向我确认；\n'
          '不得为降 CPU 而直接 kill 业务进程。\n'
          '【阶段 1 快照】uptime；top -bn1 | head -20（看 us/sy/wa）；mpstat -P ALL 1 3（如有）；\n'
          'ps aux --sort=-%cpu | head -10；vmstat 1 5。\n'
          '【阶段 2 按 us/sy/wa 分支】\n'
          'A us 高 → 定位进程/线程：top -H -p <pid>；Java→jstack 取热点栈+jstat -gcutil\n'
          '  （GC 频繁→转内存与OOM排查）；Python→py-spy dump（如有）；C/Go→perf top（如有）。\n'
          '  区分"正常业务高峰"与"异常循环/死循环"。\n'
          'B sy 高 → 上下文切换/中断：vmstat 的 cs/in；pidstat -w 1 3；\n'
          '  查频繁 syscall/锁竞争/短连接风暴；strace -c -p <pid> 限时采样（需确认）。\n'
          'C wa 高 → 转磁盘问题排查的 IO 分支，不在本 playbook 处置。\n'
          'D 单核打满其余空闲 → 单线程瓶颈/绑核/软中断集中：对比 /proc/interrupts、/proc/softirqs。\n'
          '【阶段 3 处置与回滚】优先可逆：限流/降级开关 > 调整并发/线程池 > 扩容 > 重启(最后)。\n'
          '每步记录回滚点并验证 CPU 回落；无效回滚换分支。\n'
          '【升级条件】两轮未定位；需 kill 业务进程/改内核参数；证据指向入侵(异常外联+高 CPU)。\n'
          '【输出】根因+证据链(哪个线程/栈/指标)、已执行动作与回滚点、当前 CPU、长期修复建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_mem_leak',
      name: '内存与 OOM 排查',
      icon: '🧠',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '双入口：已被 OOM kill（事后）或内存持续增长（事前），分支定位',
      content: '内存与 OOM 排查。两条入口：已被 OOM kill（事后）或内存持续增长（事前），先判定入口再分支。\n'
          '【硬性约束】先取证后处置；不得为释放内存直接 kill 业务进程或 drop_caches 掩盖问题；\n'
          '改 limit/重启前确认。\n'
          '【阶段 1 快照】free -h；ps aux --sort=-%mem | head -10；\n'
          'dmesg -T | grep -iE "oom|killed process" | tail -20；cat /proc/meminfo（Slab/页面缓存）；\n'
          '容器/cgroup：memory.max 与 memory.current（如适用）。\n'
          '【入口判定】dmesg 有 oom-kill → 入口A；否则看增长趋势 → 入口B。\n'
          '【A 已被 OOM kill】\n'
          '- 从 oom 日志取被杀进程/当时 rss/cgroup 限制；确认整机 OOM 还是 cgroup/容器 limit OOM。\n'
          '- 整机：谁吃最多→泄漏或突发；cgroup：limit 过低 vs 真实需求。\n'
          '- 处置：调 limit/加 swap(临时)/扩容 或 修复泄漏；重启被杀服务前先留堆栈。\n'
          '【B 持续增长】\n'
          '- 间隔采样 rss（pidstat -r 1 5 或两次 ps 对比）确认单调增长；区分 堆/缓存/Slab/mmap。\n'
          '- Java→jmap -histo:live + jstat -gcutil（老年代只增不降→泄漏）；Go→pprof heap（如有）；\n'
          '  Python→tracemalloc/objgraph（如有）；native→/proc/<pid>/smaps_rollup 与 pmap 对比。\n'
          '- 区分"泄漏"与"正常缓存/未设上限"：有上限且命中→配置问题；无上限单调增→泄漏。\n'
          '【阶段 3 处置与回滚】优先：设/调上限与淘汰策略 > 修复泄漏 > 滚动重启(临时止血,记回滚点)。\n'
          '每步验证 rss 曲线止涨。\n'
          '【升级条件】需 kill 业务/改内核 vm 参数；证据指向内核 Slab 泄漏；两轮未定位。\n'
          '【输出】入口(A/B)+根因+证据链、被杀/增长进程、已执行动作与回滚点、长期修复建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_disk_check',
      name: '磁盘问题排查',
      icon: '💾',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '先判定空间满还是 IO 瓶颈，两分支处置；清理只允许可再生数据',
      content: '磁盘问题排查。先判定是"空间满"还是"IO 瓶颈"，两者处置完全不同，不要混跑。\n'
          '【硬性约束】先取证后处置；删除任何文件前必须向我确认且只允许可再生数据(日志/临时/缓存)；\n'
          '禁删业务数据/数据库文件；IO 调优改参数前确认。\n'
          '【阶段 1 快照】df -h、df -i；iostat -x 1 3（如有）；\n'
          'du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20；lsblk；\n'
          'dmesg -T | tail -30（IO error/ext4/xfs 报错）。\n'
          '【入口判定】使用率>90% 或 inode>90% → 分支S；否则 %util 高/await 高 → 分支I。\n'
          '【S 空间满】\n'
          '- 定位 top 目录/文件；区分 业务数据/日志/临时/已删除但被占用(lsof +L1)。\n'
          '- 已删除仍占空间→持有进程未释放：记录 pid，处置=重启持有进程或 truncate（需确认），而非再删文件。\n'
          '- 日志膨胀→检查 logrotate 是否失效(配置/执行记录)；处置=修复轮转+清理过期(确认)。\n'
          '- inode 满→找海量小文件目录(缓存/session)；处置=清理可再生小文件(确认)。\n'
          '【I IO 瓶颈】\n'
          '- await 高+%util 高→设备饱和；await 高+%util 不高→设备/链路异常(dmesg 错误)。\n'
          '- 定位 IO 进程：pidstat -d 1 3 / iotop（如有）；区分 读密集/写密集/fsync 频繁。\n'
          '- 处置：错峰/限流后台任务 > 调刷脏/调度参数(确认) > 换更快存储/扩容；\n'
          '  数据库 fsync 频繁→转慢查询排查查事务/索引。\n'
          '【阶段 3 回滚】每个清理/参数动作记录回滚点(清理清单/原参数)；\n'
          '验证 使用率下降 或 await 回落；无效回滚换分支。\n'
          '【升级条件】需删业务数据；dmesg 有硬件 IO 错误/文件系统损坏；两轮未缓解。\n'
          '【输出】入口(S/I)+根因+证据、top 占用/IO 进程、已执行动作与回滚点、长期建议(轮转/扩容/归档)。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_slow_query',
      name: '慢查询排查',
      icon: '🐢',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '取证→执行计划→归类→可验证的优化建议；不直接改生产索引',
      content: '慢查询排查。目标：找出最值得优化的查询并给出可验证的优化方案，不直接改生产索引。\n'
          '【硬性约束】只读取证；EXPLAIN 用只读方式；加索引/改 SQL/改参数前必须向我确认并在低峰执行；\n'
          '不得在业务库跑全表扫描型分析。\n'
          '【阶段 1 取证】确认引擎(MySQL/PG)；慢日志开关与阈值；\n'
          '最近 top 慢查询(按 总耗时 与 平均耗时 双排序)；当前活跃慢会话(SHOW PROCESSLIST / pg_stat_activity)。\n'
          '【阶段 2 分析】对 top 3-5 条：\n'
          '- 执行计划：EXPLAIN(ANALYZE 仅只读 select 且确认)；看 全表扫描/filesort/临时表/行数估算偏差。\n'
          '- 归类：缺索引 / 索引失效(函数/隐式转换/前导通配) / 返回行过多 / 锁等待 / 统计信息过期 / N+1。\n'
          '- 锁等待→查阻塞链(innodb_trx / pg_locks)，处置对象是阻塞事务而非查询本身。\n'
          '【阶段 3 建议与验证】每条给：优化手段(索引 DDL/SQL 改写/参数)、预期收益、风险；\n'
          '经确认后在低峰执行，执行前后用同一查询对比 耗时/扫描行数 验证；无效回滚(删新建索引/还原 SQL)。\n'
          '【升级条件】需改生产 schema 且无低峰窗口；证据指向锁/死锁频发；统计信息/硬件层面问题。\n'
          '【输出】top 慢查询清单(耗时/次数/计划摘要)、根因归类、已验证的优化与收益、未执行建议与风险。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_app_deploy',
      name: '应用发布',
      icon: '🚀',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '可回滚发布：pre-check→指定版本→健康门→失败自动回滚',
      content: '应用发布。目标：可回滚地完成一次发布，健康门通过才算成功。\n'
          '【硬性约束】发布前必须确认 目标版本/制品 与 回滚版本；任何一步失败立即回滚，不得"带病上线"；\n'
          '生产流量切换前确认。\n'
          '【阶段 0 pre-check】当前版本与运行状态；磁盘/内存余量够构建/拉取；依赖服务可达；\n'
          '确认回滚制品/镜像 tag 可用；备份当前配置与制品指针。\n'
          '【阶段 1 发布】拉取/构建指定版本(不追 latest)；产物校验(checksum/镜像 digest)；灰度或单节点先行(如适用)。\n'
          '【阶段 2 健康门】重启/切换后：进程 active + 端口监听 + 健康 URL 2xx + 错误率/日志无新增异常，\n'
          '观察窗口(默认 60s)；任一不达标→判定失败。\n'
          '【阶段 3 回滚】失败→恢复上一版本制品/配置指针→重启→重跑健康门；\n'
          '回滚后仍失败→停止自动处置升级人工。\n'
          '【输出】发布版本/回滚点、健康门各项结果、是否回滚及原因、遗留风险。成功也需给出回滚命令备用。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_config_push',
      name: '配置与证书变更',
      icon: '🔐',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '备份→校验→graceful 生效→验证→一键回滚',
      content: '配置/证书变更。目标：带备份与校验地生效一次变更，失败可一键回滚。\n'
          '【硬性约束】先备份后修改；语法/链校验通过才 reload；reload 用 graceful 而非 restart(如支持)；\n'
          '覆盖生产配置前确认。\n'
          '【阶段 0】确认变更对象(文件路径/域名)与目标内容；备份当前文件/证书到带时间戳副本(记录回滚点)。\n'
          '【阶段 1 校验】配置：nginx -t / apachectl configtest / 服务自带 -t；\n'
          '证书：openssl x509 -noout -dates -subject + 私钥匹配(modulus/pubkey 比对) + 链完整。\n'
          '【阶段 2 生效】写入新配置/证书→reload→验证：服务 active + 健康 URL + 证书 s_client 链/到期 + 配置生效项抽查。\n'
          '【阶段 3 回滚】验证失败→恢复备份→reload→复验；仍失败→升级人工。\n'
          '【输出】变更摘要、备份/回滚点、校验与验证结果、新证书到期日、是否回滚。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_db_backup',
      name: '数据库备份与恢复验证',
      icon: '🗄️',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '一致性备份+隔离恢复演练；恢复通过才算备份可用',
      content: '数据库备份与恢复验证。备份文件存在≠备份可用；恢复演练通过才算完成。\n'
          '【硬性约束】备份用一致性方式(mysqldump --single-transaction / pg_dump / xtrabackup 如适用)；\n'
          '恢复演练必须在隔离实例/临时目录，严禁覆盖生产库；删旧备份前确认。\n'
          '【阶段 1 备份】确认引擎/数据量/目标路径与剩余空间；执行一致性备份；记录 校验和+大小+耗时。\n'
          '【阶段 2 验证】校验和比对；恢复到隔离实例/临时目录；\n'
          '跑 行数/关键表 checksum 抽查 + 应用只读连通验证；记录恢复耗时(RTO 参考)。\n'
          '【阶段 3 保留策略】对照预期 schedule 找缺口；列出可过期旧备份(只列不删)；给保留/异地建议。\n'
          '【升级条件】恢复演练失败(备份不可用)→立即告警并停止后续备份覆盖；空间不足；需动生产库。\n'
          '【输出】备份路径/大小/校验和、恢复演练结果与耗时、schedule 缺口、保留建议。明确"备份可用/不可用"结论。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_security_audit',
      name: '安全基线审计',
      icon: '🛡️',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '只读审计 SSH/账户/权限/防火墙/补丁/持久化，出分级报告不自动加固',
      content: '安全基线审计（只读）。覆盖 SSH/账户/权限/防火墙/补丁/持久化，出分级报告，不自动加固。\n'
          '【硬性约束】全程只读；不打印密码哈希/私钥内容；不改任何配置/规则/账户；加固建议另经确认执行。\n'
          '【检查项】\n'
          '- SSH：root 登录/密码登录/端口/AllowUsers；authorized_keys 异常新增\n'
          '- 账户：空口令/UID0 非 root/可登录 shell 账户清单；sudoers 与 wheel/sudo 成员\n'
          '- 权限：SUID/SGID 清单对照发行版默认标出意外项；/etc /bin /usr/bin 近期被改文件\n'
          '- 防火墙：默认策略/开放端口与归属/过宽规则(0.0.0.0/0 高危端口)\n'
          '- 持久化：各用户 crontab + /etc/cron.* + systemd timers 标出可疑/陌生条目\n'
          '- 补丁：待安装安全更新清单(只列不装)；是否需重启\n'
          '- 登录：lastb 失败爆破来源/成功登录异常来源与时间\n'
          '【输出】按 严重/警告/提示 分级，每项附证据与加固建议(含命令但不执行)；给一个总体风险结论。\n'
          '明确未做任何修改。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_intrusion_detect',
      name: '入侵应急响应',
      icon: '🕵️',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '怀疑入侵时取证与最小遏制；保留证据、避免打草惊蛇',
      content: '入侵应急响应。怀疑被入侵时的取证与遏制；优先保留证据、避免打草惊蛇。\n'
          '【硬性约束】先取证后遏制；不要重启/清理/杀毒(会破坏证据与触发攻击者自毁)；\n'
          '隔离网络/封禁 IP/改凭据前必须向我确认；不打印凭据明文。\n'
          '【阶段 1 取证快照】（只读,归档）\n'
          '- 登录：last/lastb/w；异常来源/时间/账户\n'
          '- 进程：ps auxf 全量树；隐藏进程对比(/proc 遍历 vs ps)；异常外联 ss -tnp\n'
          '- 持久化：crontab/systemd timers/rc.local/authorized_keys/ld.so.preload\n'
          '- 文件：/etc /bin /usr/bin /tmp /dev/shm 近期新增/修改；SUID 异常；webshell 特征目录\n'
          '- 日志：auth/secure/journal 登录与提权痕迹；日志是否被清空/截断(本身即指标)\n'
          '【阶段 2 判定】汇总 IOC(恶意 IP/域名/文件 hash/异常账户)；区分 误报/扫描噪声/真实入侵；给置信度。\n'
          '【阶段 3 遏制(经确认)】优先可逆：安全组/防火墙封禁 IOC > 禁用异常账户/移除 authorized_keys > 隔离主机网络；\n'
          '每步记录回滚点；保留内存/磁盘证据后再考虑重装。\n'
          '【升级条件】确认真实入侵→立即交人工/安全团队，本 playbook 只取证与最小遏制；涉及数据外泄→合规流程。\n'
          '【输出】IOC 清单+证据链、置信度、已执行遏制与回滚点、被影响面评估、后续根除/恢复建议。',
      isBuiltin: true,
    ),
  ];

  /// 初始化内置 Runbook 模板（首次安装或升级时调用）
  ///
  /// 升级语义：
  /// - 退役：删除已不在 [all] 中的内置模板（仅 isBuiltin 行，克隆/导入不受影响）；
  /// - 刷新：保留模板内容变化时覆盖模板字段，但保留 createdAt/runCount/lastRunAt；
  /// - 追加：新模板自动写入。
  /// 内容未变化时跳过写入，避免每次启动 bump updatedAt。
  static Future<void> initBuiltin() async {
    final templates = all;
    final ids = templates.map((r) => r.id).toSet();
    for (final stored in await RunbooksDao.getAll()) {
      if (stored.isBuiltin && !ids.contains(stored.id)) {
        await RunbooksDao.delete(stored.id);
      }
    }
    for (final rb in templates) {
      final existing = await RunbooksDao.getById(rb.id);
      if (existing == null) {
        await RunbooksDao.upsert(rb);
        continue;
      }
      if (!existing.isBuiltin) continue;
      final unchanged = existing.name == rb.name &&
          existing.icon == rb.icon &&
          existing.description == rb.description &&
          existing.type == rb.type &&
          existing.category == rb.category &&
          existing.content == rb.content;
      if (unchanged) continue;
      rb.createdAt = existing.createdAt;
      rb.runCount = existing.runCount;
      rb.lastRunAt = existing.lastRunAt;
      await RunbooksDao.upsert(rb);
    }
  }
}