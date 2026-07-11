import '../models/runbook.dart';
import '../services/daos.dart';

/// 内置运维工作流模板
/// 首次安装或升级时写入数据库，已有则跳过
class BuiltinRunbooks {
  static List<Runbook> get all => [
    Runbook.create(
      id: 'builtin_health_check',
      name: '健康体检',
      icon: '🩺',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '全面检查服务器状态：CPU/内存/磁盘/服务/端口/补丁',
      content: '请对当前服务器做一次全面健康体检，依次检查并报告：\n'
          '1. 系统负载与 CPU 使用率（uptime、top -bn1 | head -20）\n'
          '2. 内存使用情况（free -h）\n'
          '3. 磁盘空间与 inode 使用（df -h、df -i）\n'
          '4. 关键服务状态（systemctl 列出 failed 服务）\n'
          '5. 监听端口清单（ss -tlnp）\n'
          '6. 最近登录记录（last -n 10）\n'
          '7. 待安装的安全更新（如适用）\n'
          '8. 系统启动时间和运行时长\n'
          '最后给出一份简明的体检结论，标注异常项。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_security_audit',
      name: '安全审计',
      icon: '🛡️',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: 'SSH 配置、防火墙、异常进程、SUID 文件检查',
      content: '请对当前服务器做一次基础安全审计，检查：\n'
          '1. SSH 配置（是否禁止 root 登录、是否禁止密码登录、端口是否非默认）\n'
          '2. 防火墙状态（ufw status / firewall-cmd --list-all / iptables -L -n）\n'
          '3. 最近 24 小时登录失败记录（lastb 或 journalctl）\n'
          '4. 异常进程（按 CPU 和内存排序的 top 进程）\n'
          '5. SUID/SGID 异常文件（find / -perm /6000 -type f 2>/dev/null 限制前 20 条）\n'
          '6. 空口令账户（awk -F: "\$2==""{print \$1}" /etc/shadow）\n'
          '7. sudo 组成员（getent group sudo / wheel）\n'
          '最后给出安全评分和整改建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_disk_check',
      name: '磁盘排查',
      icon: '💾',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '找出占满磁盘的大文件/大目录',
      content: '服务器磁盘空间告警，请帮我排查：\n'
          '1. 先用 df -h 查看各分区使用情况\n'
          '2. 用 du -sh /* 2>/dev/null | sort -rh | head -10 找出根目录下最大的子目录\n'
          '3. 针对最大的目录继续向下钻取（du -sh 该目录/* | sort -rh | head -10），最多 3 层\n'
          '4. 用 find / -type f -size +500M 2>/dev/null | head -20 列出大文件\n'
          '5. 检查日志目录 /var/log 大小\n'
          '6. 检查是否有过期的日志可清理\n'
          '最后报告前 5 大占用源，并给出清理建议（只建议，不执行清理）。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_network_diag',
      name: '网络诊断',
      icon: '🌐',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '连通性/DNS/端口/路由诊断',
      content: '请对当前服务器做网络诊断：\n'
          '1. 检查网卡配置和 IP（ip addr）\n'
          '2. 测试外网连通性（ping -c 3 8.8.8.8）\n'
          '3. 测试 DNS 解析（nslookup github.com 或 dig github.com）\n'
          '4. 查看路由表（ip route）\n'
          '5. 查看监听端口（ss -tlnp）\n'
          '6. 查看当前已建立连接数（ss -s）\n'
          '7. 检查 iptables/ufw 规则\n'
          '最后报告网络是否正常，标注异常项。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_service_check',
      name: '服务巡检',
      icon: '⚙️',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '检查常见服务（nginx/mysql/docker/redis）运行状态',
      content: '请巡检常见服务的运行状态：\n'
          '1. 列出所有 systemd 服务中 failed 的（systemctl --failed）\n'
          '2. 逐个检查以下服务（如已安装）的 active 状态和最近 10 行日志：\n'
          '   - nginx / apache2 / httpd\n'
          '   - mysql / mariadb / postgresql\n'
          '   - docker\n'
          '   - redis\n'
          '   - sshd\n'
          '3. 对每个服务用 systemctl status XXX 检查，并用 journalctl -u XXX -n 10 --no-pager 查最近日志\n'
          '4. 检查开机自启状态（systemctl is-enabled XXX）\n'
          '最后报告各服务健康度，标注异常或未运行的服务。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cert_check',
      name: '证书检查',
      icon: '🔐',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '检查 HTTPS 证书和 SSH host key 到期情况',
      content: '请检查证书到期情况：\n'
          '1. 用 ss -tlnp 找出监听 443 端口的服务\n'
          '2. 如果有 HTTPS 服务，用 echo | openssl s_client -connect localhost:443 -servername localhost 2>/dev/null | openssl x509 -noout -dates -subject 查看证书\n'
          '3. 检查 /etc/letsencrypt/live 目录下的证书（如存在）\n'
          '4. 检查 SSH host key 指纹（ssh-keygen -l -f /etc/ssh/ssh_host_*_key.pub）\n'
          '5. 检查 /etc/ssh 下的 host key 修改时间（ls -la /etc/ssh/ssh_host_*_key*）\n'
          '最后报告证书到期日期和剩余天数，标注 30 天内到期的证书。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_perf_baseline',
      name: '性能基线采集',
      icon: '📊',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '采集 CPU/内存/磁盘IO/网络IO 基线数据，作为后续对比基准',
      content: '请采集当前服务器的性能基线数据，作为后续对比基准：\n'
          '1. CPU 信息与负载\n'
          '   - lscpu 查看型号/核数/频率\n'
          '   - uptime 查看负载均衡\n'
          '   - cat /proc/loadavg 查看 1/5/15 分钟平均负载\n'
          '   - top -bn1 | head -20 查看 CPU 使用率和占用最高的进程\n'
          '   - vmstat 1 3 查看 CPU 上下文切换和中断\n'
          '2. 内存基线\n'
          '   - free -h 查看总量/可用/缓存\n'
          '   - cat /proc/meminfo | head -10 查看 MemAvailable/Cached/SwapCached\n'
          '   - swapon --show 查看 swap 配置\n'
          '3. 磁盘 IO 基线\n'
          '   - iostat -xz 1 3 (如可用) 查看 %util/await/svctm\n'
          '   - cat /proc/diskstats 查看磁盘统计\n'
          '4. 网络基线\n'
          '   - ip -s link 查看网卡收发包和错误\n'
          '   - sar -n DEV 1 3 (如可用) 查看网络吞吐\n'
          '   - ss -s 查看连接数统计\n'
          '5. 系统信息\n'
          '   - uname -a 内核版本\n'
          '   - cat /etc/os-release 发行版\n'
          '   - nproc 逻辑核数\n'
          '最后把以上数据整理成基线报告，建议保存以便后续对比。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_db_inspection',
      name: '数据库巡检',
      icon: '🗄️',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: 'MySQL/PostgreSQL 连接数/慢查询/表空间/主从状态',
      content: '请巡检数据库运行状态，自动识别已安装的 MySQL/MariaDB/PostgreSQL：\n'
          '1. 检查数据库进程和服务\n'
          '   - systemctl status mysql mariadb postgresql 2>/dev/null\n'
          '   - ps aux | grep -E "mysqld|postgres" | grep -v grep\n'
          '2. MySQL/MariaDB 检查（如已安装且有客户端）：\n'
          '   - mysql -e "SHOW GLOBAL STATUS LIKE \'Threads_connected\';" 当前连接数\n'
          '   - mysql -e "SHOW GLOBAL STATUS LIKE \'Slow_queries\';" 慢查询累计\n'
          '   - mysql -e "SHOW VARIABLES LIKE \'max_connections\';" 最大连接数\n'
          '   - mysql -e "SHOW SLAVE STATUS\\G" 主从状态（如有从库）\n'
          '   - mysql -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS size_mb FROM information_schema.tables GROUP BY table_schema;" 各库大小\n'
          '3. PostgreSQL 检查（如已安装）：\n'
          '   - sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;" 连接数\n'
          '   - sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;" 库大小\n'
          '   - sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;" 主从状态\n'
          '4. 检查慢查询日志配置（slow_query_log / log_min_duration_statement）\n'
          '5. 检查数据库数据目录磁盘占用（du -sh /var/lib/mysql /var/lib/postgresql 2>/dev/null）\n'
          '最后报告数据库健康度、连接数占比、主从延迟、慢查询趋势。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_redis_inspection',
      name: 'Redis 巡检',
      icon: '🟥',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: 'Redis 内存使用/键值数量/持久化状态/命中率',
      content: '请巡检 Redis 运行状态：\n'
          '1. 检查 Redis 进程和服务\n'
          '   - systemctl status redis redis-server 2>/dev/null\n'
          '   - ps aux | grep redis-server | grep -v grep\n'
          '2. 基本信息\n'
          '   - redis-cli INFO server 查看版本/运行时长/配置文件路径\n'
          '   - redis-cli INFO clients 查看连接数/阻塞客户端\n'
          '3. 内存使用\n'
          '   - redis-cli INFO memory 查看 used_memory/used_memory_peak/maxmemory\n'
          '   - redis-cli CONFIG GET maxmemory 查看内存上限\n'
          '   - redis-cli CONFIG GET maxmemory-policy 查看淘汰策略\n'
          '4. 键值统计\n'
          '   - redis-cli DBSIZE 查看键总数\n'
          '   - redis-cli INFO keyspace 查看各 DB 键分布和过期\n'
          '5. 持久化状态\n'
          '   - redis-cli INFO persistence 查看 RDB/AOF 状态\n'
          '   - redis-cli CONFIG GET save 查看 RDB 触发策略\n'
          '   - redis-cli CONFIG GET appendonly 查看 AOF 是否开启\n'
          '6. 性能与命中率\n'
          '   - redis-cli INFO stats 查看 keyspace_hits/keyspace_misses 计算命中率\n'
          '   - redis-cli --latency 测量延迟\n'
          '   - redis-cli SLOWLOG GET 10 查看慢操作\n'
          '最后报告 Redis 健康度、内存使用率、命中率和潜在风险。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_docker_inspection',
      name: 'Docker 巡检',
      icon: '🐳',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '容器状态/镜像/卷/资源占用/异常容器',
      content: '请巡检 Docker 运行状态：\n'
          '1. Docker 服务状态\n'
          '   - systemctl status docker\n'
          '   - docker info 查看 Docker 整体信息（存储驱动/容器数/镜像数）\n'
          '2. 容器状态\n'
          '   - docker ps -a 查看所有容器及状态\n'
          '   - docker ps --filter "status=exited" 查看已停止容器\n'
          '   - docker ps --filter "status=restarting" 查看反复重启容器\n'
          '3. 资源占用\n'
          '   - docker stats --no-stream 查看各容器 CPU/内存/网络/IO\n'
          '   - docker system df 查看磁盘使用（镜像/容器/卷/缓存）\n'
          '4. 镜像检查\n'
          '   - docker images 查看所有镜像\n'
          '   - docker images --filter "dangling=true" 查看悬空镜像\n'
          '5. 卷检查\n'
          '   - docker volume ls 查看所有卷\n'
          '   - docker volume ls -f dangling=true 查看悬空卷\n'
          '6. 异常容器日志\n'
          '   - 对状态异常的容器执行 docker logs --tail 50 <容器名> 查看最近日志\n'
          '   - docker events --since 1h --until 0s 查看最近 1 小时事件\n'
          '最后报告 Docker 健康度、资源使用率、异常容器和清理建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_k8s_inspection',
      name: 'Kubernetes 巡检',
      icon: '☸️',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: 'Pod/Service/Deployment/Node 状态',
      content: '请巡检 Kubernetes 集群状态（需要 kubectl 已安装且已配置 kubeconfig）：\n'
          '1. 集群基本信息\n'
          '   - kubectl cluster-info 查看集群端点\n'
          '   - kubectl version --short 查看客户端/服务端版本\n'
          '2. 节点状态\n'
          '   - kubectl get nodes -o wide 查看节点状态/IP/版本\n'
          '   - kubectl describe nodes | grep -A5 "Allocated" 查看资源分配\n'
          '   - kubectl top nodes 查看节点 CPU/内存使用（需 metrics-server）\n'
          '3. Pod 状态\n'
          '   - kubectl get pods --all-namespaces -o wide 查看所有 Pod\n'
          '   - kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 查看异常 Pod\n'
          '   - 对异常 Pod 执行 kubectl describe pod <pod> -n <namespace> 查看事件\n'
          '   - kubectl logs --tail=30 <pod> -n <namespace> 查看异常 Pod 日志\n'
          '4. Deployment/StatefulSet/DaemonSet 状态\n'
          '   - kubectl get deploy,sts,ds --all-namespaces 查看期望/就绪副本数\n'
          '   - kubectl get deploy --all-namespaces -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas/.spec.replicas\n'
          '5. Service/Ingress\n'
          '   - kubectl get svc --all-namespaces 查看所有 Service\n'
          '   - kubectl get ingress --all-namespaces 查看 Ingress 规则\n'
          '6. 事件和告警\n'
          '   - kubectl get events --all-namespaces --sort-by=.lastTimestamp | tail -20 查看最近事件\n'
          '最后报告集群健康度、异常 Pod/Node 列表和修复建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_capacity_planning',
      name: '资源容量规划',
      icon: '📈',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '分析使用趋势，给出扩容建议',
      content: '请分析当前服务器的资源使用趋势并给出容量规划建议：\n'
          '1. CPU 容量分析\n'
          '   - nproc 查看逻辑核数\n'
          '   - uptime 查看当前负载和平均负载\n'
          '   - cat /proc/loadavg 查看负载详情\n'
          '   - sar -u 1 3 (如可用) 查看历史 CPU 使用率\n'
          '   - top -bn1 | head -5 查看 CPU 总体使用\n'
          '2. 内存容量分析\n'
          '   - free -h 查看物理内存和 swap\n'
          '   - cat /proc/meminfo | grep -E "MemTotal|MemAvailable|Cached|SwapTotal|SwapFree"\n'
          '   - sar -r 1 3 (如可用) 查看历史内存使用率\n'
          '3. 磁盘容量分析\n'
          '   - df -h 查看各分区使用率和剩余空间\n'
          '   - df -i 查看 inode 使用率\n'
          '   - du -sh /var/log /var/lib /home /tmp 2>/dev/null 查看主要目录大小\n'
          '   - sar -d 1 3 (如可用) 查看磁盘 IO 历史\n'
          '4. 增长趋势分析（如有 sar 历史数据）\n'
          '   - sar -u -f /var/log/sa/sa01 查看月初 CPU 使用率\n'
          '   - sar -r -f /var/log/sa/sa01 查看月初内存使用率\n'
          '   - 对比当前数据估算增长趋势\n'
          '5. 按照以下阈值给出建议：\n'
          '   - CPU 持续 >70%：建议扩容或优化\n'
          '   - 内存使用 >80%：建议增加内存\n'
          '   - 磁盘使用 >75%：建议扩容或清理\n'
          '   - inode 使用 >70%：建议清理小文件\n'
          '最后给出容量规划报告，包含当前使用率、增长趋势和扩容时间预测。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_log_scan',
      name: '日志巡检',
      icon: '📜',
      type: RunbookType.agent,
      category: RunbookCategory.inspection,
      description: '扫描系统日志中的 ERROR/WARN/异常堆栈',
      content: '请扫描系统日志中的异常信息：\n'
          '1. 系统日志\n'
          '   - journalctl -p err --since "24 hours ago" --no-pager | tail -50 查看最近 24 小时错误\n'
          '   - journalctl -p warning --since "24 hours ago" --no-pager | tail -30 查看警告\n'
          '2. 常见日志文件扫描\n'
          '   - grep -Ern "ERROR|CRITICAL|FATAL" /var/log/messages /var/log/syslog 2>/dev/null | tail -30\n'
          '   - grep -Ern "panic|Oops|BUG" /var/log/messages /var/log/syslog /var/log/kern.log 2>/dev/null | tail -20\n'
          '   - grep -rn "segfault" /var/log/ 2>/dev/null | tail -10\n'
          '3. 认证日志\n'
          '   - grep "Failed password" /var/log/auth.log /var/log/secure 2>/dev/null | tail -20 查看失败登录\n'
          '   - grep "Accepted password" /var/log/auth.log /var/log/secure 2>/dev/null | tail -10 查看成功登录\n'
          '4. 应用日志（检查常见路径）\n'
          '   - find /var/log -name "*.log" -mtime -1 查看今天修改的日志文件\n'
          '   - grep -Ern "Exception|Traceback|Error" /var/log/nginx /var/log/apache2 /var/log/httpd 2>/dev/null | tail -20\n'
          '   - grep -Ern "Exception|Traceback|Error" /opt /srv /app 2>/dev/null --include="*.log" | tail -20\n'
          '5. dmesg 检查\n'
          '   - dmesg -T --level=err,crit,alert,emerg | tail -20 查看内核错误\n'
          '6. 统计汇总\n'
          '   - journalctl --since "24 hours ago" -p err --no-pager | wc -l 统计错误总数\n'
          '最后报告发现的异常数量、分类和重点关注项。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_intrusion_detect',
      name: '入侵检测',
      icon: '🕵️',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '异常登录/可疑进程/rootkit/后门检查',
      content: '请对服务器进行入侵检测排查：\n'
          '1. 异常登录检查\n'
          '   - last -n 30 查看最近登录记录\n'
          '   - lastb -n 30 2>/dev/null 查看失败登录（需 root）\n'
          '   - grep "Accepted" /var/log/auth.log /var/log/secure 2>/dev/null | tail -20 查看成功登录\n'
          '   - 检查是否有非工作时间或未知 IP 的登录\n'
          '2. 可疑进程检查\n'
          '   - ps auxf 查看进程树，关注异常父进程\n'
          '   - ps aux --sort=-%cpu | head -10 查看 CPU 占用最高的进程\n'
          '   - netstat -tlnp 或 ss -tlnp 查看监听端口\n'
          '   - lsof -i 查看网络连接对应的进程\n'
          '3. 后门检查\n'
          '   - find /tmp /var/tmp /dev/shm -type f -executable 2>/dev/null 查找临时目录可执行文件\n'
          '   - find / -name ".*" -type f -executable 2>/dev/null | head -20 查找隐藏可执行文件\n'
          '   - crontab -l 查看当前用户定时任务\n'
          '   - ls /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ 查看系统定时任务\n'
          '   - cat /etc/rc.local 2>/dev/null 查看启动项\n'
          '4. SSH 后门检查\n'
          '   - cat /root/.ssh/authorized_keys 2>/dev/null 检查 root SSH 密钥\n'
          '   - find /home -name authorized_keys -exec cat {} \\; 2>/dev/null 检查用户 SSH 密钥\n'
          '   - cat /etc/passwd | grep -E "/bin/(bash|sh|zsh)\$" 检查可登录用户\n'
          '5. Rootkit 检查（如已安装）\n'
          '   - chkrootkit 2>/dev/null 或 rkhunter --check --sk 2>/dev/null\n'
          '   - rpm -Va 2>/dev/null 或 debsums -c 2>/dev/null 检查系统文件完整性\n'
          '6. 网络异常\n'
          '   - ip link 检查网卡是否处于 PROMISC 模式（嗅探）\n'
          '   - ss -tnp 查看所有 TCP 连接，关注异常外连\n'
          '最后报告发现的可疑项、风险等级和建议处置措施。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_weak_password',
      name: '弱口令检查',
      icon: '🔑',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '密码策略/空口令/弱口令用户',
      content: '请检查服务器的密码安全状况：\n'
          '1. 空口令检查\n'
          '   - awk -F: "length(\$2)==0{print \$1}" /etc/shadow 检查空口令账户（需 root）\n'
          '   - awk -F: "(\$2==""||\$2=="*"){print \$1,\$2}" /etc/shadow 检查无密码或锁定账户\n'
          '2. 密码策略检查\n'
          '   - cat /etc/pam.d/common-password (Debian/Ubuntu) 检查 PAM 密码策略\n'
          '   - cat /etc/pam.d/system-auth (RHEL/CentOS) 检查 PAM 密码策略\n'
          '   - cat /etc/security/pwquality.conf 2>/dev/null 检查密码质量配置\n'
          '   - 检查 minlen（最小长度）、minclass（字符类别数）等参数\n'
          '3. 密码过期策略\n'
          '   - cat /etc/login.defs | grep -E "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE"\n'
          '   - chage -l root 查看 root 密码过期信息\n'
          '   - for user in \$(awk -F: "\$7~/bash|sh|zsh/{print \$1}" /etc/passwd); do echo "=== \$user ==="; chage -l \$user; done\n'
          '4. 弱口令用户排查\n'
          '   - 检查用户名和密码是否相同的常见弱口令\n'
          '   - cat /etc/passwd | awk -F: "\$3<1000{print \$1,\$3}" 查看系统用户\n'
          '   - cat /etc/passwd | awk -F: "\$3>=1000{print \$1,\$3}" 查看普通用户\n'
          '5. 账户锁定策略\n'
          '   - cat /etc/pam.d/common-auth (Debian) 或 /etc/pam.d/system-auth (RHEL) 检查 pam_tally2/pam_faillock 配置\n'
          '6. SSH 密码认证\n'
          '   - grep -E "PasswordAuthentication|PermitRootLogin|PermitEmptyPasswords" /etc/ssh/sshd_config\n'
          '最后报告密码安全评分、弱口令风险项和整改建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_file_integrity',
      name: '文件完整性检查',
      icon: '📁',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '关键系统文件是否被篡改（对比 mtime/hash）',
      content: '请检查关键系统文件的完整性：\n'
          '1. 包管理器完整性验证\n'
          '   - rpm -Va 2>/dev/null (RHEL/CentOS) 验证所有已安装包的文件\n'
          '   - dpkg --verify 2>/dev/null 或 debsums -c 2>/dev/null (Debian/Ubuntu) 检查文件校验和\n'
          '   - 重点关注 S（大小变化）、5（MD5变化）、T（时间戳变化）标记\n'
          '2. 关键配置文件检查\n'
          '   - ls -la /etc/passwd /etc/shadow /etc/group /etc/gshadow 检查权限和修改时间\n'
          '   - ls -la /etc/sudoers /etc/ssh/sshd_config /etc/crontab 检查修改时间\n'
          '   - ls -la /etc/pam.d/ /etc/security/ /etc/login.defs 检查安全配置文件\n'
          '3. 关键二进制文件检查\n'
          '   - ls -la /bin/ /sbin/ /usr/bin/ /usr/sbin/ | grep -v "^total" | head -30 检查修改时间\n'
          '   - which ps ls netstat ss find grep top 检查关键命令路径\n'
          '   - file /bin/ls /bin/ps /bin/netstat 检查文件类型是否正常\n'
          '4. SUID/SGID 文件检查\n'
          '   - find / -perm /4000 -type f 2>/dev/null 查找所有 SUID 文件\n'
          '   - find / -perm /2000 -type f 2>/dev/null 查找所有 SGID 文件\n'
          '   - 与系统默认 SUID 列表对比（正常的有 su/sudo/passwd/mount/umount 等）\n'
          '5. 最近修改文件检查\n'
          '   - find /etc -type f -mtime -7 2>/dev/null 查找 7 天内修改的配置文件\n'
          '   - find /usr/bin /usr/sbin /bin /sbin -type f -mtime -30 2>/dev/null 查找 30 天内修改的二进制\n'
          '   - find / -type f -mtime -1 2>/dev/null | grep -vE "/proc|/sys|/run|/tmp|/var/log" | head -20\n'
          '6. 如有 aide/tripwire（文件完整性监控工具）\n'
          '   - aide --check 2>/dev/null 或 tripwire --check 2>/dev/null\n'
          '最后报告文件完整性状况、可疑篡改文件列表和风险等级。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_privilege_audit',
      name: '权限审计',
      icon: '⚖️',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: 'sudoers/crontab/SSH密钥/特殊权限文件',
      content: '请审计服务器的权限配置：\n'
          '1. sudo 权限审计\n'
          '   - cat /etc/sudoers 检查主配置\n'
          '   - ls /etc/sudoers.d/ && cat /etc/sudoers.d/* 检查额外配置\n'
          '   - getent group sudo wheel 查看 sudo 组成员\n'
          '   - grep -r "NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null 检查免密 sudo\n'
          '   - grep -r "ALL=(ALL)" /etc/sudoers /etc/sudoers.d/ 2>/dev/null 检查全权限 sudo\n'
          '2. crontab 审计\n'
          '   - cat /etc/crontab 系统主 crontab\n'
          '   - ls /etc/cron.d/ && cat /etc/cron.d/* 查看 cron.d 配置\n'
          '   - ls /etc/cron.daily/ /etc/cron.hourly/ /etc/cron.weekly/ /etc/cron.monthly/ 查看周期任务\n'
          '   - for user in \$(cut -f1 -d: /etc/passwd); do crontab -u \$user -l 2>/dev/null && echo "--- \$user ---"; done 查看用户 crontab\n'
          '3. SSH 密钥审计\n'
          '   - find / -name authorized_keys -exec ls -la {} \\; 2>/dev/null 查找所有 authorized_keys\n'
          '   - find / -name authorized_keys -exec cat {} \\; 2>/dev/null 查看密钥内容\n'
          '   - find / -name "id_rsa" -o -name "id_ed25519" 2>/dev/null | head -20 查找私钥文件\n'
          '   - 检查私钥文件权限是否为 600\n'
          '4. 特殊权限文件审计\n'
          '   - find / -perm -4000 -type f 2>/dev/null SUID 文件\n'
          '   - find / -perm -2000 -type f 2>/dev/null SGID 文件\n'
          '   - find / -perm -1000 -type d 2>/dev/null sticky bit 目录\n'
          '   - getcap -r / 2>/dev/null 查找有 capabilities 的文件\n'
          '5. 用户和组审计\n'
          '   - cat /etc/passwd | awk -F: "\$3==0{print \$1}" 查找 UID=0 的用户（除 root 外不应有）\n'
          '   - cat /etc/group | grep -E "sudo|wheel|docker|admin" 查看特权组成员\n'
          '   - who -b 查看上次启动时间\n'
          '6. 可登录用户审计\n'
          '   - grep -E "/bin/(bash|sh|zsh|fish)\$" /etc/passwd 查看可登录用户\n'
          '   - passwd -S -a 2>/dev/null 或 for u in \$(grep "/bash|/sh" /etc/passwd | cut -d: -f1); do passwd -S \$u; done 查看密码状态\n'
          '最后报告权限审计结果、过度授权项和整改建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_firewall_audit',
      name: '防火墙审计',
      icon: '🧱',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: '规则合理性/开放端口/危险规则',
      content: '请审计服务器防火墙配置：\n'
          '1. 防火墙服务状态\n'
          '   - systemctl status ufw firewalld iptables nftables 2>/dev\n'
          '   - 检查哪个防火墙服务处于 active 状态\n'
          '2. iptables 规则审计\n'
          '   - iptables -L -n -v 查看所有规则（filter 表）\n'
          '   - iptables -t nat -L -n -v 查看 NAT 表规则\n'
          '   - iptables -L INPUT -n --line-numbers 查看 INPUT 链规则编号\n'
          '   - 检查是否有 "ACCEPT all" 或 "DROP all" 等宽泛规则\n'
          '   - 检查默认策略：iptables -L | grep "Chain.*policy"\n'
          '3. ufw 审计（如已安装）\n'
          '   - ufw status verbose 查看详细状态\n'
          '   - ufw app list 查看应用规则\n'
          '   - 检查是否有 ufw allow from any 规则\n'
          '4. firewalld 审计（如已安装）\n'
          '   - firewall-cmd --list-all 查看当前区域规则\n'
          '   - firewall-cmd --list-all-zones 查看所有区域\n'
          '   - firewall-cmd --get-active-zones 查看活跃区域\n'
          '   - firewall-cmd --list-services --list-ports 查看开放服务和端口\n'
          '5. 开放端口审计\n'
          '   - ss -tlnp 查看所有监听端口\n'
          '   - ss -ulnp 查看所有 UDP 监听\n'
          '   - 对比监听端口和防火墙规则，找出未放行但监听的端口\n'
          '   - 检查是否有 0.0.0.0:端口 监听（绑定所有网卡）\n'
          '6. 危险规则检查\n'
          '   - 检查是否有 INPUT 全部 ACCEPT 的规则\n'
          '   - 检查是否有对外全部放行的 OUTPUT 规则\n'
          '   - 检查是否有限制 SSH 来源的规则\n'
          '   - 检查是否有端口转发/DNAT 规则\n'
          '最后报告防火墙配置评分、开放端口清单、危险规则和整改建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cis_benchmark',
      name: '合规检查',
      icon: '📋',
      type: RunbookType.agent,
      category: RunbookCategory.security,
      description: 'CIS Benchmark 基础检查项',
      content: '请执行 CIS Benchmark 基础合规检查：\n'
          '1. SSH 安全配置（CIS 6.x）\n'
          '   - grep -E "PermitRootLogin|PasswordAuthentication|Protocol|X11Forwarding|MaxAuthTries|ClientAliveInterval|LoginGraceTime|PermitEmptyPasswords" /etc/ssh/sshd_config\n'
          '   - 检查 PermitRootLogin 是否为 no\n'
          '   - 检查 MaxAuthTries 是否 <= 4\n'
          '   - 检查 ClientAliveInterval 和 ClientAliveCountMax 配置\n'
          '   - 检查是否禁止空密码和 X11 转发\n'
          '2. 密码策略（CIS 5.x）\n'
          '   - cat /etc/pam.d/common-password (Debian) 或 /etc/pam.d/system-auth (RHEL)\n'
          '   - cat /etc/security/pwquality.conf 2>/dev/null\n'
          '   - 检查 minlen >= 14, minclass >= 4\n'
          '   - cat /etc/login.defs | grep -E "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE"\n'
          '   - 检查 PASS_MAX_DAYS <= 90\n'
          '3. 用户和访问控制（CIS 5.x/6.x）\n'
          '   - 检查 UID=0 的用户只有 root\n'
          '   - 检查默认账号（如 games/gnats/irc 等）是否被锁定\n'
          '   - 检查 PATH 环境变量是否包含空目录或 . \n'
          '4. 内核参数加固（CIS 3.x）\n'
          '   - sysctl net.ipv4.ip_forward 检查是否为 0\n'
          '   - sysctl net.ipv4.conf.all.send_redirects 检查是否为 0\n'
          '   - sysctl net.ipv4.conf.all.accept_redirects 检查是否为 0\n'
          '   - sysctl net.ipv4.conf.all.accept_source_route 检查是否为 0\n'
          '   - sysctl net.ipv4.tcp_syncookies 检查是否为 1\n'
          '   - sysctl net.ipv4.conf.all.log_martians 检查是否为 1\n'
          '   - sysctl kernel.randomize_va_space 检查是否为 2\n'
          '5. 文件权限（CIS 6.x）\n'
          '   - 检查 /etc/passwd 权限是否为 644\n'
          '   - 检查 /etc/shadow 权限是否为 640 或 000\n'
          '   - 检查 /etc/group 权限是否为 644\n'
          '   - 检查 /etc/gshadow 权限是否为 640 或 000\n'
          '   - 检查 /etc/sudoers 权限是否为 440\n'
          '   - 检查 cron 文件权限\n'
          '6. 日志和审计（CIS 4.x/8.x）\n'
          '   - systemctl status rsyslog 检查日志服务\n'
          '   - systemctl status auditd 2>/dev/null 检查审计服务\n'
          '   - cat /etc/audit/auditd.conf 2>/dev/null 检查审计配置\n'
          '7. 系统更新（CIS 1.x）\n'
          '   - 检查是否有可用安全更新\n'
          '   - apt list --upgradable 2>/dev/null (Debian)\n'
          '   - yum check-update --security 2>/dev/null (RHEL)\n'
          '最后报告 CIS 合规评分（通过/不通过/手动检查项数）和整改优先级。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_server_init',
      name: '环境初始化',
      icon: '🚀',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '新服务器基础软件安装和配置',
      content: '请对新服务器进行基础环境初始化（注意：只执行安全的基础配置，关键变更需先确认）：\n'
          '1. 系统更新\n'
          '   - apt update && apt upgrade -y (Debian/Ubuntu) 或 yum update -y (RHEL/CentOS)\n'
          '2. 安装基础工具\n'
          '   - Debian/Ubuntu: apt install -y vim curl wget git htop iotop nethogs tree unzip zip net-tools bind-utils tmux screen\n'
          '   - RHEL/CentOS: yum install -y vim curl wget git htop iotop nethogs tree unzip zip net-tools bind-utils tmux screen\n'
          '3. 设置时区\n'
          '   - timedatectl set-timezone Asia/Shanghai\n'
          '   - timedatectl status 验证时区和 NTP\n'
          '4. 配置 NTP 时间同步\n'
          '   - apt install -y chrony 或 yum install -y chrony\n'
          '   - systemctl enable --now chronyd\n'
          '   - chronyc sources 验证时间源\n'
          '5. 创建运维用户（如需要）\n'
          '   - useradd -m -s /bin/bash deploy\n'
          '   - passwd deploy（交互设置密码）\n'
          '   - usermod -aG sudo deploy 或 usermod -aG wheel deploy\n'
          '6. SSH 安全配置\n'
          '   - 备份 sshd_config: cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak\n'
          '   - 设置 PermitRootLogin no（如需）\n'
          '   - 设置 PasswordAuthentication no（如已有密钥）\n'
          '   - 设置 MaxAuthTries 4\n'
          '   - systemctl restart sshd\n'
          '7. 防火墙配置\n'
          '   - ufw default deny incoming && ufw default allow outgoing\n'
          '   - ufw allow 22/tcp 放行 SSH\n'
          '   - ufw enable\n'
          '8. 配置 swap（如内存 < 2G）\n'
          '   - free -h 检查内存\n'
          '   - 如无 swap: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile\n'
          '   - echo "/swapfile none swap sw 0 0" >> /etc/fstab\n'
          '9. 文件描述符限制\n'
          '   - echo "* soft nofile 65535" >> /etc/security/limits.conf\n'
          '   - echo "* hard nofile 65535" >> /etc/security/limits.conf\n'
          '最后报告初始化结果，列出已安装的软件和已应用的配置。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_app_deploy',
      name: '应用部署',
      icon: '📦',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '拉取代码/构建/重启服务/健康检查',
      content: '请执行应用部署流程（注意：每步操作前先确认，危险操作需人工确认）：\n'
          '1. 部署前检查\n'
          '   - 检查当前服务状态：systemctl status <服务名>\n'
          '   - 检查磁盘空间：df -h（确保有足够空间）\n'
          '   - 检查代码仓库：git -C <代码目录> status\n'
          '   - 备份当前版本：cp -r <代码目录> <代码目录>.bak.\$(date +%Y%m%d%H%M%S)\n'
          '2. 拉取最新代码\n'
          '   - cd <代码目录> && git fetch --all\n'
          '   - git log --oneline -5 origin/<分支> 查看待部署提交\n'
          '   - git checkout <分支> && git pull origin <分支>\n'
          '   - git log --oneline -5 确认当前版本\n'
          '3. 安装依赖\n'
          '   - 如有 package.json: npm install 或 npm ci\n'
          '   - 如有 requirements.txt: pip install -r requirements.txt\n'
          '   - 如有 go.mod: go mod download\n'
          '   - 如有 pom.xml: mvn clean package -DskipTests\n'
          '4. 构建项目\n'
          '   - npm run build 或 yarn build\n'
          '   - go build -o <输出文件> <入口文件>\n'
          '   - mvn clean package\n'
          '5. 重启服务\n'
          '   - systemctl restart <服务名> 或 supervisorctl restart <服务名>\n'
          '   - 或使用 PM2: pm2 restart <应用名>\n'
          '   - 或直接重启进程\n'
          '6. 健康检查\n'
          '   - systemctl status <服务名> 检查服务状态\n'
          '   - curl -f http://localhost:<端口>/health 检查健康端点\n'
          '   - journalctl -u <服务名> -n 20 --no-pager 检查启动日志\n'
          '   - ss -tlnp | grep <端口> 确认端口监听\n'
          '7. 验证\n'
          '   - 从外部访问测试：curl -I http://<IP>:<端口>/\n'
          '   - 检查关键功能是否正常\n'
          '最后报告部署结果、版本号和健康检查状态。如部署失败，提供回滚命令。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_ssl_deploy',
      name: 'SSL 证书部署',
      icon: '🔒',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '部署/更新 HTTPS 证书并重载服务',
      content: '请部署/更新 SSL 证书并重载 Web 服务（注意：先备份旧证书）：\n'
          '1. 检查当前证书状态\n'
          '   - echo | openssl s_client -connect localhost:443 -servername <域名> 2>/dev/null | openssl x509 -noout -dates -subject -issuer\n'
          '   - 记录当前证书到期日期\n'
          '2. 备份旧证书\n'
          '   - 确定证书路径：通常在 /etc/nginx/ssl/ 或 /etc/letsencrypt/live/ 或 /etc/apache2/ssl/\n'
          '   - mkdir -p /etc/nginx/ssl/backup\n'
          '   - cp /etc/nginx/ssl/<域名>.crt /etc/nginx/ssl/backup/<域名>.crt.\$(date +%Y%m%d%H%M%S)\n'
          '   - cp /etc/nginx/ssl/<域名>.key /etc/nginx/ssl/backup/<域名>.key.\$(date +%Y%m%d%H%M%S)\n'
          '3. 部署新证书\n'
          '   - 将新证书文件复制到证书目录\n'
          '   - 确保证书文件权限正确：chmod 644 <域名>.crt && chmod 600 <域名>.key\n'
          '   - 验证证书和私钥是否匹配：\n'
          '     openssl x509 -noout -modulus -in <域名>.crt | openssl md5\n'
          '     openssl rsa -noout -modulus -in <域名>.key | openssl md5\n'
          '     （两个 MD5 值应相同）\n'
          '4. 验证证书链\n'
          '   - openssl x509 -in <域名>.crt -text -noout | grep -A2 "Issuer|Subject"\n'
          '   - 确保证书链完整（包含中间证书）\n'
          '5. 测试 Web 服务配置\n'
          '   - nginx -t (如使用 Nginx)\n'
          '   - apachectl configtest (如使用 Apache)\n'
          '6. 重载服务\n'
          '   - systemctl reload nginx 或 systemctl reload apache2\n'
          '   - 注意：使用 reload 而非 restart，避免中断连接\n'
          '7. 验证新证书\n'
          '   - echo | openssl s_client -connect localhost:443 -servername <域名> 2>/dev/null | openssl x509 -noout -dates -subject -issuer\n'
          '   - 确认新证书已生效且到期日期正确\n'
          '   - curl -vI https://<域名>/ 2>&1 | grep -E "subject|issuer|expire date"\n'
          '8. 如使用 Let\'s Encrypt\n'
          '   - certbot certificates 查看证书列表\n'
          '   - certbot renew --dry-run 测试续期\n'
          '   - certbot renew 手动续期（如需）\n'
          '最后报告证书部署结果、新旧证书到期日期对比和验证状态。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_db_backup',
      name: '数据库备份',
      icon: '💾',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '执行数据库备份并验证',
      content: '请执行数据库备份并验证（注意：大库备份可能耗时较长）：\n'
          '1. 备份前检查\n'
          '   - 检查磁盘空间：df -h（确保备份目录有足够空间，至少为数据库大小的 2 倍）\n'
          '   - 检查数据库运行状态：systemctl status mysql postgresql\n'
          '   - 确定备份目录：通常为 /backup/ 或 /data/backup/\n'
          '   - mkdir -p /backup/db && cd /backup/db\n'
          '2. MySQL/MariaDB 备份\n'
          '   - 全量备份：mysqldump -u root -p --all-databases --single-transaction --routines --triggers --events > alldb_\$(date +%Y%m%d%H%M%S).sql\n'
          '   - 单库备份：mysqldump -u root -p --single-transaction --routines --triggers <数据库名> > <数据库名>_\$(date +%Y%m%d%H%M%S).sql\n'
          '   - 压缩备份：mysqldump -u root -p --all-databases --single-transaction | gzip > alldb_\$(date +%Y%m%d%H%M%S).sql.gz\n'
          '3. PostgreSQL 备份\n'
          '   - 全量备份：sudo -u postgres pg_dumpall > alldb_\$(date +%Y%m%d%H%M%S).sql\n'
          '   - 单库备份：sudo -u postgres pg_dump -Fc <数据库名> > <数据库名>_\$(date +%Y%m%d%H%M%S).dump\n'
          '   - 压缩备份：sudo -u postgres pg_dump -Fc <数据库名> | gzip > <数据库名>_\$(date +%Y%m%d%H%M%S).dump.gz\n'
          '4. 验证备份\n'
          '   - 检查备份文件大小：ls -lh /backup/db/\n'
          '   - 检查备份文件是否为空：find /backup/db -name "*.sql" -size 0\n'
          '   - 验证 SQL 文件头部：head -20 <备份文件>\n'
          '   - 验证 SQL 文件尾部：tail -20 <备份文件>\n'
          '   - 检查是否包含 CREATE TABLE 语句：grep -c "CREATE TABLE" <备份文件>\n'
          '5. 测试恢复（可选，在测试环境）\n'
          '   - MySQL: mysql -u root -p <测试库名> < <备份文件>\n'
          '   - PostgreSQL: sudo -u postgres pg_restore -d <测试库> <备份文件>\n'
          '6. 清理旧备份\n'
          '   - find /backup/db -name "*.sql*" -mtime +30 -exec ls -lh {} \\; 列出 30 天前的备份\n'
          '   - 确认后清理：find /backup/db -name "*.sql*" -mtime +30 -delete\n'
          '7. 记录备份信息\n'
          '   - 记录备份文件名、大小、时间、数据库版本\n'
          '最后报告备份结果、文件大小、验证状态和恢复测试结果。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_config_push',
      name: '配置推送',
      icon: '📤',
      type: RunbookType.agent,
      category: RunbookCategory.deployment,
      description: '向服务器推送配置文件并重载服务',
      content: '请向服务器推送配置文件并重载服务（注意：先备份旧配置，重载前先测试语法）：\n'
          '1. 推送前检查\n'
          '   - 检查目标服务状态：systemctl status <服务名>\n'
          '   - 检查目标配置路径：通常为 /etc/<服务名>/ 或 /etc/<服务名>/conf.d/\n'
          '   - 确认源配置文件存在且内容正确\n'
          '2. 备份旧配置\n'
          '   - mkdir -p /etc/<服务名>/backup\n'
          '   - cp /etc/<服务名>/<配置文件> /etc/<服务名>/backup/<配置文件>.\$(date +%Y%m%d%H%M%S)\n'
          '   - 或：cp -r /etc/<服务名>/conf.d/ /etc/<服务名>/conf.d.bak.\$(date +%Y%m%d%H%M%S)\n'
          '3. 推送新配置\n'
          '   - 如果是从本地推送：scp <本地配置文件> <用户>@<服务器>:/etc/<服务名>/<配置文件>\n'
          '   - 如果已在服务器上：cp <新配置文件> /etc/<服务名>/<配置文件>\n'
          '   - 确保文件权限正确：chown root:root /etc/<服务名>/<配置文件> && chmod 644 /etc/<服务名>/<配置文件>\n'
          '4. 测试配置语法\n'
          '   - Nginx: nginx -t\n'
          '   - Apache: apachectl configtest 或 httpd -t\n'
          '   - SSH: sshd -t\n'
          '   - 如语法检查失败，立即回滚：cp /etc/<服务名>/backup/<配置文件>.<时间戳> /etc/<服务名>/<配置文件>\n'
          '5. 对比配置差异\n'
          '   - diff /etc/<服务名>/backup/<配置文件>.<时间戳> /etc/<服务名>/<配置文件>\n'
          '   - 确认变更内容符合预期\n'
          '6. 重载服务\n'
          '   - systemctl reload <服务名>（优先使用 reload，不中断连接）\n'
          '   - 如 reload 不可用：systemctl restart <服务名>\n'
          '7. 验证\n'
          '   - systemctl status <服务名> 检查服务状态\n'
          '   - journalctl -u <服务名> -n 20 --no-pager 检查日志无报错\n'
          '   - curl -I http://localhost:<端口>/ 验证服务正常响应（如适用）\n'
          '8. 回滚准备\n'
          '   - 记录备份文件路径\n'
          '   - 准备回滚命令：cp /etc/<服务名>/backup/<配置文件>.<时间戳> /etc/<服务名>/<配置文件> && systemctl reload <服务名>\n'
          '最后报告配置推送结果、变更差异摘要和验证状态。如推送失败，提供回滚步骤。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cpu_spike',
      name: 'CPU 飙高排查',
      icon: '🔥',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '定位高 CPU 进程并分析原因',
      content: '服务器 CPU 使用率飙高，请帮我排查：\n'
          '1. 确认 CPU 使用率\n'
          '   - uptime 查看负载均衡\n'
          '   - cat /proc/loadavg 查看负载详情\n'
          '   - top -bn1 | head -5 查看 CPU 总体使用率（us/sy/si/wa）\n'
          '   - 确认是用户态(us)高还是内核态(sy)高，或是 IO 等待(wa)高\n'
          '2. 定位高 CPU 进程\n'
          '   - top -bn1 | head -20 查看 CPU 占用最高的进程\n'
          '   - ps aux --sort=-%cpu | head -10 列出 CPU 占比最高的 10 个进程\n'
          '   - pidstat 1 3 2>/dev/null 持续监控各进程 CPU 变化\n'
          '3. 分析高 CPU 进程\n'
          '   - 确认进程信息：ps -fp <PID>\n'
          '   - 查看进程线程：ps -T -p <PID> 或 top -H -p <PID>\n'
          '   - 查看进程打开的文件：lsof -p <PID> | head -20\n'
          '   - 查看进程网络连接：lsof -i -a -p <PID>\n'
          '4. 深入分析\n'
          '   - 查看进程的命令行和启动时间：cat /proc/<PID>/cmdline | tr "\\0" " "\n'
          '   - 查看进程的父进程：ps -o ppid= -p <PID> 然后查看父进程\n'
          '   - 如是 Java 进程：jstack <PID> | head -50 查看线程栈\n'
          '   - 如是 Java 进程：jstat -gcutil <PID> 1000 3 查看 GC 情况\n'
          '   - 如是 Python 进程：py-spy dump --pid <PID> 2>/dev/null\n'
          '5. 系统级分析\n'
          '   - vmstat 1 5 查看 CPU 上下文切换和中断\n'
          '   - mpstat -P ALL 1 3 2>/dev/null 查看各 CPU 核使用率\n'
          '   - sar -u 1 3 2>/dev/null 查看 CPU 历史\n'
          '6. 检查定时任务和日志\n'
          '   - crontab -l 检查是否有定时任务正在执行\n'
          '   - journalctl --since "10 min ago" --no-pager | tail -30 查看最近日志\n'
          '最后报告 CPU 飙高的根因、高 CPU 进程列表和处置建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_mem_leak',
      name: '内存泄漏排查',
      icon: '🧠',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '分析内存使用和进程内存增长',
      content: '服务器内存持续增长，疑似内存泄漏，请排查：\n'
          '1. 确认内存使用状况\n'
          '   - free -h 查看内存总量/已用/可用/缓存\n'
          '   - cat /proc/meminfo | head -15 查看详细内存信息\n'
          '   - vmstat 1 5 查看 si/so（swap 换入换出）\n'
          '   - swapon --show 查看 swap 使用\n'
          '2. 定位内存占用最高的进程\n'
          '   - ps aux --sort=-%mem | head -10 列出内存占比最高的进程\n'
          '   - top -bn1 | head -20 查看 RES（物理内存）和 VIRT（虚拟内存）\n'
          '   - pidstat -r 1 3 2>/dev/null 持续监控各进程内存变化\n'
          '3. 分析可疑进程内存\n'
          '   - 查看进程内存映射：cat /proc/<PID>/maps | head -30\n'
          '   - 查看进程状态：cat /proc/<PID>/status | grep -E "Vm|Rss|Threads"\n'
          '   - 查看进程 smaps 汇总：cat /proc/<PID>/smaps_rollup 2>/dev/null\n'
          '   - pmap -x <PID> 2>/dev/null | tail -5 查看内存映射汇总\n'
          '4. 判断是否为内存泄漏\n'
          '   - 多次采样对比 RSS 是否持续增长：while true; do ps -o pid,rss,comm -p <PID>; sleep 5; done\n'
          '   - 检查进程运行时间：ps -o pid,etime,rss,comm -p <PID>\n'
          '   - 如是 Java：jmap -histo <PID> | head -30 查看对象统计\n'
          '   - 如是 Java：jstat -gcutil <PID> 1000 3 查看 GC 和各代内存\n'
          '   - 如是 Java：jcmd <PID> GC.heap_info 2>/dev/null\n'
          '5. 系统级内存分析\n'
          '   - slabtop -o -s c | head -20 查看 slab 缓存占用\n'
          '   - cat /proc/meminfo | grep -E "Slab|SReclaimable|SUnreclaim"\n'
          '   - 检查大页：cat /proc/meminfo | grep -i huge\n'
          '   - 检查 tmpfs：df -h | grep tmpfs\n'
          '6. 检查 OOM 记录\n'
          '   - dmesg | grep -i "out of memory" | tail -10\n'
          '   - journalctl -k | grep -i oom | tail -10\n'
          '最后报告内存泄漏分析结果、可疑进程和处置建议（如重启/限制内存/修复代码）。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_service_down',
      name: '服务不可用排查',
      icon: '🚨',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '快速定位服务挂掉的原因',
      content: '服务不可用，请帮我快速排查：\n'
          '1. 确认服务状态\n'
          '   - systemctl status <服务名> 查看服务状态和最近日志\n'
          '   - systemctl is-active <服务名> 确认是否 active\n'
          '   - systemctl is-enabled <服务名> 确认是否开机自启\n'
          '   - 如服务不存在：systemctl list-units --type=service | grep <关键词>\n'
          '2. 检查进程和端口\n'
          '   - ps aux | grep <服务名> | grep -v grep 检查进程是否存在\n'
          '   - ss -tlnp | grep <端口> 检查端口是否监听\n'
          '   - ss -tnp | grep <端口> 检查是否有已建立连接\n'
          '3. 查看服务日志\n'
          '   - journalctl -u <服务名> -n 50 --no-pager 查看最近 50 行日志\n'
          '   - journalctl -u <服务名> --since "30 min ago" --no-pager 查看最近 30 分钟日志\n'
          '   - 检查应用日志：find /var/log -name "*<服务名>*" -exec tail -30 {} \\;\n'
          '   - tail -50 <日志路径> 查看应用日志文件\n'
          '4. 检查资源限制\n'
          '   - df -h 检查磁盘是否满\n'
          '   - free -h 检查内存是否不足\n'
          '   - ulimit -a 检查资源限制\n'
          '   - cat /proc/<PID>/limits 2>/dev/null 查看进程资源限制\n'
          '5. 检查配置文件\n'
          '   - 确认配置文件存在：ls -la <配置文件路径>\n'
          '   - 测试配置语法（如适用）：nginx -t / apachectl configtest / <服务> -t\n'
          '   - diff 配置文件与备份，确认最近是否有变更\n'
          '6. 检查依赖服务\n'
          '   - 检查数据库是否可达：mysql -e "SELECT 1" 或 psql -c "SELECT 1"\n'
          '   - 检查 Redis：redis-cli ping\n'
          '   - 检查网络连通性：ping <依赖服务IP>\n'
          '   - 检查 DNS 解析：nslookup <域名>\n'
          '7. 检查系统事件\n'
          '   - dmesg | tail -30 查看内核日志\n'
          '   - journalctl --since "30 min ago" -p err --no-pager 查看系统错误\n'
          '   - 检查 OOM：dmesg | grep -i oom\n'
          '8. 尝试恢复\n'
          '   - systemctl restart <服务名> 尝试重启\n'
          '   - systemctl status <服务名> 确认是否恢复\n'
          '   - curl -f http://localhost:<端口>/ 健康检查\n'
          '最后报告服务不可用的根因、排查过程和恢复状态。如未恢复，提供下一步排查建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_oom_analyze',
      name: 'OOM 排查',
      icon: '💀',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '分析 OOM killer 日志和原因',
      content: '服务器发生 OOM（内存溢出）事件，请排查：\n'
          '1. 确认 OOM 事件\n'
          '   - dmesg | grep -i "out of memory" | tail -20 查看内核 OOM 日志\n'
          '   - dmesg | grep -i "oom-killer" | tail -20 查看 OOM killer 记录\n'
          '   - dmesg | grep -i "killed process" | tail -20 查看被杀进程\n'
          '   - journalctl -k | grep -i "oom|out of memory" | tail -20 从 journal 查看内核日志\n'
          '2. 分析 OOM 详情\n'
          '   - dmesg -T | grep -A30 "Out of memory" 查看带时间戳的 OOM 详情\n'
          '   - 确认被 OOM 杀掉的进程名称和 PID\n'
          '   - 确认触发 OOM 时的内存状况（total/used/free）\n'
          '   - 确认 OOM score：cat /proc/<PID>/oom_score 2>/dev/null\n'
          '3. 检查当前内存状态\n'
          '   - free -h 查看当前内存\n'
          '   - cat /proc/meminfo | head -15 查看详细内存信息\n'
          '   - ps aux --sort=-%mem | head -10 查看当前内存占用最高的进程\n'
          '4. 检查 OOM 配置\n'
          '   - sysctl vm.overcommit_memory 查看过度提交策略（0=启发式,1=总是,2=不允许）\n'
          '   - sysctl vm.overcommit_ratio 查看过度提交比例\n'
          '   - sysctl vm.panic_on_oom 查看是否 OOM 时 panic\n'
          '   - cat /proc/<PID>/oom_score_adj 2>/dev/null 查看 OOM 调整值\n'
          '5. 检查被杀进程\n'
          '   - 确认被杀进程的服务：systemctl status <服务名>\n'
          '   - 查看服务是否已自动重启：systemctl is-active <服务名>\n'
          '   - 查看服务日志：journalctl -u <服务名> --since "1 hour ago" --no-pager | tail -50\n'
          '6. 检查 swap 配置\n'
          '   - swapon --show 查看 swap 是否配置\n'
          '   - cat /proc/swaps 查看 swap 设备\n'
          '   - 如无 swap，建议添加（可缓解 OOM）\n'
          '7. 检查 cgroup 内存限制（如使用容器）\n'
          '   - cat /sys/fs/cgroup/memory/<路径>/memory.limit_in_bytes 2>/dev/null\n'
          '   - cat /sys/fs/cgroup/memory/<路径>/memory.max 2>/dev/null (cgroup v2)\n'
          '   - docker inspect <容器名> | grep -i memory 2>/dev/null\n'
          '8. 分析根因\n'
          '   - 是否为突发内存使用（如大查询/大文件加载）\n'
          '   - 是否为内存泄漏导致渐进式增长\n'
          '   - 是否为容器内存限制过小\n'
          '   - 是否为 swap 不足或未配置\n'
          '最后报告 OOM 事件时间线、被杀进程、根因分析和预防建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_slow_query',
      name: '慢查询排查',
      icon: '🐌',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '分析数据库慢查询日志',
      content: '数据库响应慢，请排查慢查询：\n'
          '1. 确认慢查询日志配置\n'
          '   - MySQL: mysql -e "SHOW VARIABLES LIKE \'slow_query_log%\';" 查看是否开启和路径\n'
          '   - MySQL: mysql -e "SHOW VARIABLES LIKE \'long_query_time\';" 查看慢查询阈值\n'
          '   - MySQL: mysql -e "SHOW GLOBAL STATUS LIKE \'Slow_queries\';" 查看慢查询累计数\n'
          '   - PostgreSQL: sudo -u postgres psql -c "SHOW log_min_duration_statement;" 查看慢查询阈值\n'
          '   - PostgreSQL: sudo -u postgres psql -c "SHOW log_directory;" 查看日志目录\n'
          '2. MySQL 慢查询分析\n'
          '   - 确认慢查询日志文件路径\n'
          '   - mysqldumpslow -s t -t 10 <慢查询日志> 按总耗时排序前 10 条\n'
          '   - mysqldumpslow -s c -t 10 <慢查询日志> 按出现次数排序前 10 条\n'
          '   - mysqldumpslow -s r -t 10 <慢查询日志> 按返回行数排序前 10 条\n'
          '   - 直接查看最近慢查询：tail -100 <慢查询日志>\n'
          '3. PostgreSQL 慢查询分析\n'
          '   - sudo -u postgres psql -c "SELECT * FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;" (如已安装 pg_stat_statements)\n'
          '   - sudo -u postgres psql -c "SELECT query, calls, total_time, mean_time, rows FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"\n'
          '   - 查看 PostgreSQL 日志中的慢查询：grep "duration" /var/log/postgresql/*.log | tail -30\n'
          '4. 分析当前活跃查询\n'
          '   - MySQL: mysql -e "SHOW PROCESSLIST;" 查看当前正在执行的查询\n'
          '   - MySQL: mysql -e "SELECT * FROM information_schema.processlist WHERE time > 5 ORDER BY time DESC;" 查看执行超过 5 秒的查询\n'
          '   - PostgreSQL: sudo -u postgres psql -c "SELECT pid, now()-query_start as duration, query FROM pg_stat_activity WHERE state=\'active\' ORDER BY duration DESC;"\n'
          '5. 分析执行计划\n'
          '   - 对最慢的查询用 EXPLAIN 分析：EXPLAIN SELECT ...\n'
          '   - MySQL: EXPLAIN ANALYZE SELECT ... (MySQL 8.0+)\n'
          '   - PostgreSQL: EXPLAIN ANALYZE SELECT ...\n'
          '   - 检查是否缺少索引：对比 WHERE 条件和索引列表\n'
          '6. 检查索引状态\n'
          '   - MySQL: mysql -e "SHOW INDEX FROM <表名>;" 查看表索引\n'
          '   - MySQL: mysql -e "SELECT * FROM sys.schema_unused_indexes;" 查看未使用的索引 (MySQL 5.7+)\n'
          '   - PostgreSQL: sudo -u postgres psql -c "SELECT schemaname, relname, indexrelname, idx_scan FROM pg_stat_user_indexes ORDER BY idx_scan;"\n'
          '7. 检查表状态\n'
          '   - MySQL: mysql -e "SHOW TABLE STATUS;" 查看各表数据和索引大小\n'
          '   - 检查表碎片：MySQL -e "SELECT table_name, data_free FROM information_schema.tables WHERE data_free > 0;"\n'
          '最后报告最慢的 10 条查询、执行计划分析和索引优化建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_io_bottleneck',
      name: '磁盘 IO 瓶颈',
      icon: '⚡',
      type: RunbookType.agent,
      category: RunbookCategory.troubleshooting,
      description: '分析磁盘 IO 性能和等待',
      content: '服务器磁盘 IO 高，疑似 IO 瓶颈，请排查：\n'
          '1. 确认 IO 状况\n'
          '   - vmstat 1 5 查看 wa（IO 等待）列和 bi/bo（块读写）\n'
          '   - iostat -xz 1 3 2>/dev/null 查看各磁盘 %util/await/svctm\n'
          '   - 重点关注 %util（接近 100% 表示饱和）和 await（超过 10ms 较差）\n'
          '   - cat /proc/diskstats 查看磁盘统计原始数据\n'
          '2. 定位高 IO 进程\n'
          '   - iotop -bn1 2>/dev/null | head -20 查看各进程 IO 读写（需 root）\n'
          '   - pidstat -d 1 3 2>/dev/null 持续监控各进程 IO\n'
          '   - 如 iotop 不可用：ls /proc/*/io 2>/dev/null | head -20，然后 cat /proc/<PID>/io 查看各进程 IO 统计\n'
          '3. 分析高 IO 进程\n'
          '   - ps aux | grep <PID> 确认进程信息\n'
          '   - lsof -p <PID> | head -30 查看进程打开的文件\n'
          '   - cat /proc/<PID>/io 查看进程 IO 统计（read_bytes/write_bytes）\n'
          '   - strace -p <PID> -e trace=read,write,fsync 2>&1 | head -30 查看系统调用（谨慎使用）\n'
          '4. 检查磁盘和文件系统\n'
          '   - df -h 查看磁盘空间使用\n'
          '   - df -i 查看 inode 使用\n'
          '   - mount | grep <磁盘> 查看挂载选项（是否 noatime 等）\n'
          '   - tune2fs -l <磁盘设备> 2>/dev/null 查看文件系统信息\n'
          '5. 检查 IO 调度器\n'
          '   - cat /sys/block/<磁盘>/queue/scheduler 查看当前 IO 调度器\n'
          '   - 常见调度器：deadline/cfq/noop/mq-deadline/none\n'
          '   - SSD 建议用 noop/none，机械盘建议用 deadline/cfq\n'
          '6. 检查 swap IO\n'
          '   - free -h 查看内存和 swap\n'
          '   - vmstat 1 5 查看 si/so（swap 换入换出）\n'
          '   - 如 si/so 较高，说明内存不足导致频繁 swap IO\n'
          '7. 检查脏页比例\n'
          '   - cat /proc/sys/vm/dirty_ratio 查看脏页比例阈值\n'
          '   - cat /proc/sys/vm/dirty_background_ratio 查看后台刷脏页阈值\n'
          '   - cat /proc/meminfo | grep -i dirty 查看当前脏页\n'
          '8. 检查特定场景\n'
          '   - 数据库大量读写：检查数据库缓冲池配置\n'
          '   - 日志写入：检查日志文件大小和写入频率\n'
          '   - 大文件读写：find / -type f -size +1G 2>/dev/null | head -10\n'
          '   - 容器存储：docker info | grep "Storage Driver"\n'
          '最后报告 IO 瓶颈根因、高 IO 进程和优化建议（如换 SSD/调整调度器/优化应用）。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_log_cleanup',
      name: '日志清理',
      icon: '🧹',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '清理过期日志释放空间',
      content: '请清理服务器过期日志释放磁盘空间（注意：只清理明确安全的日志，不删除当前活跃日志）：\n'
          '1. 评估日志占用空间\n'
          '   - du -sh /var/log/ 查看日志目录总大小\n'
          '   - du -sh /var/log/* | sort -rh | head -10 找出最大的日志目录\n'
          '   - find /var/log -type f -name "*.log" -exec ls -lh {} \\; | sort -k5 -rh | head -20 列出最大的日志文件\n'
          '2. 检查 journal 日志占用\n'
          '   - journalctl --disk-usage 查看 journal 磁盘占用\n'
          '   - journalctl --vacuum-time=7d 清理 7 天前的 journal 日志\n'
          '   - journalctl --vacuum-size=500M 将 journal 限制到 500MB\n'
          '3. 清理已轮转的日志文件\n'
          '   - find /var/log -name "*.log.*" -o -name "*.log-*" -o -name "*.gz" | head -20 列出已轮转日志\n'
          '   - find /var/log -name "*.gz" -mtime +30 -exec ls -lh {} \\; 列出 30 天前的压缩日志\n'
          '   - find /var/log -name "*.gz" -mtime +30 -delete 清理 30 天前的压缩日志\n'
          '   - find /var/log -name "*.log.*" -mtime +30 -delete 清理 30 天前的轮转日志\n'
          '4. 清理应用日志\n'
          '   - 检查 Nginx 日志：ls -lh /var/log/nginx/\n'
          '   - 检查 Apache 日志：ls -lh /var/log/apache2/ 或 /var/log/httpd/\n'
          '   - 检查应用日志：find /opt /srv /app /home -name "*.log" -size +100M 2>/dev/null\n'
          '   - 对大日志文件可截断（保留最近 1000 行）：tail -1000 <日志文件> > <日志文件>.tmp && mv <日志文件>.tmp <日志文件>\n'
          '5. 检查 dmesg 日志\n'
          '   - dmesg -T | wc -l 查看 dmesg 行数\n'
          '   - dmesg --clear 清空 dmesg 缓冲区（不影响日志文件）\n'
          '6. 检查 logrotate 配置\n'
          '   - cat /etc/logrotate.conf 查看主配置\n'
          '   - ls /etc/logrotate.d/ 查看各服务配置\n'
          '   - 确认日志轮转是否正常运行：cat /var/lib/logrotate/status 2>/dev/null\n'
          '7. 清理后验证\n'
          '   - df -h 查看磁盘空间释放情况\n'
          '   - du -sh /var/log/ 查看清理后日志大小\n'
          '最后报告清理前后的磁盘空间对比、清理的文件列表和建议的 logrotate 优化。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_sys_update',
      name: '系统更新',
      icon: '🔄',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '检查并安装安全更新',
      content: '请检查并安装系统安全更新（注意：生产环境建议先在测试环境验证，关键服务更新前需备份）：\n'
          '1. 检查可用更新\n'
          '   - Debian/Ubuntu: apt update && apt list --upgradable\n'
          '   - RHEL/CentOS: yum check-update\n'
          '   - 统计可更新包数量\n'
          '2. 检查安全更新（仅安全相关）\n'
          '   - Debian/Ubuntu: apt list --upgradable 2>/dev/null | grep -i security\n'
          '   - Ubuntu: unattended-upgrade --dry-run -v 2>/dev/null\n'
          '   - RHEL/CentOS: yum check-update --security\n'
          '   - RHEL/CentOS: yum updateinfo list security available\n'
          '3. 查看更新详情\n'
          '   - Debian/Ubuntu: apt changelog <包名> | head -30 查看变更日志\n'
          '   - RHEL/CentOS: yum info <包名> 查看包信息\n'
          '   - yum updateinfo info <安全公告ID> 查看安全公告详情\n'
          '4. 备份关键配置（更新前）\n'
          '   - 确认需要更新的包列表\n'
          '   - 备份相关配置文件：cp -r /etc/<服务名> /etc/<服务名>.bak.\$(date +%Y%m%d%H%M%S)\n'
          '5. 安装更新\n'
          '   - 仅安装安全更新：\n'
          '     Debian/Ubuntu: unattended-upgrade -v 或 apt install --only-upgrade <包名列表>\n'
          '     RHEL/CentOS: yum update --security\n'
          '   - 安装所有更新（需确认）：\n'
          '     Debian/Ubuntu: apt upgrade -y\n'
          '     RHEL/CentOS: yum update -y\n'
          '6. 检查是否需要重启\n'
          '   - Debian/Ubuntu: ls /var/run/reboot-required 2>/dev/null 检查是否需要重启\n'
          '   - RHEL/CentOS: needs-restarting -r 2>/dev/null 检查是否需要重启\n'
          '   - 检查是否有服务需要重启：needs-restarting -s 2>/dev/null (RHEL)\n'
          '7. 重启受影响的服务\n'
          '   - 对更新了库文件的服务执行 systemctl restart <服务名>\n'
          '   - 如内核更新且需要重启：安排维护窗口重启\n'
          '8. 验证\n'
          '   - systemctl status <服务名> 检查服务状态\n'
          '   - 确认系统版本：cat /etc/os-release\n'
          '   - 确认内核版本：uname -r\n'
          '最后报告更新结果、安装的包列表、是否需要重启和验证状态。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_docker_cleanup',
      name: 'Docker 清理',
      icon: '🗑️',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '清理无用镜像/容器/卷',
      content: '请清理 Docker 无用资源释放磁盘空间（注意：不清理正在使用的资源）：\n'
          '1. 评估 Docker 磁盘占用\n'
          '   - docker system df 查看 Docker 总磁盘使用\n'
          '   - docker system df -v 查看详细信息（每项大小）\n'
          '   - df -h 查看系统磁盘使用\n'
          '2. 清理已停止的容器\n'
          '   - docker ps -a --filter "status=exited" 查看已停止容器\n'
          '   - docker ps -a --filter "status=exited" --format "{{.ID}} {{.Names}} {{.Image}} {{.Status}}"\n'
          '   - docker container prune -f 清理所有已停止容器\n'
          '   - 或选择性清理：docker rm <容器ID>\n'
          '3. 清理悬空镜像\n'
          '   - docker images -f "dangling=true" 查看悬空镜像\n'
          '   - docker image prune -f 清理悬空镜像\n'
          '4. 清理未使用的镜像\n'
          '   - docker images 查看所有镜像\n'
          '   - docker image prune -a -f 清理所有未被容器引用的镜像（谨慎）\n'
          '   - 或选择性清理：docker rmi <镜像ID>\n'
          '5. 清理未使用的卷\n'
          '   - docker volume ls -f "dangling=true" 查看悬空卷\n'
          '   - docker volume prune -f 清理悬空卷\n'
          '   - 注意：确认卷中没有重要数据\n'
          '6. 清理未使用的网络\n'
          '   - docker network ls 查看所有网络\n'
          '   - docker network prune -f 清理未使用的网络\n'
          '7. 清理构建缓存\n'
          '   - docker builder prune -f 清理构建缓存\n'
          '   - docker builder prune -a -f 清理所有构建缓存\n'
          '8. 一键清理（可选）\n'
          '   - docker system prune -f 清理已停止容器+悬空镜像+悬空卷+未使用网络\n'
          '   - docker system prune -a -f --volumes 清理所有未使用资源（包括非悬空镜像和卷，谨慎）\n'
          '9. 清理 Docker 日志\n'
          '   - find /var/lib/docker/containers -name "*-json.log" -exec ls -lh {} \\; 查看容器日志大小\n'
          '   - truncate -s 0 /var/lib/docker/containers/*/*-json.log 截断过大日志（临时方案）\n'
          '   - 建议配置日志轮转：在 /etc/docker/daemon.json 添加 log-opts max-size\n'
          '10. 清理后验证\n'
          '   - docker system df 查看清理后磁盘使用\n'
          '   - df -h 查看系统磁盘释放\n'
          '   - docker ps 确认运行中的容器未受影响\n'
          '最后报告清理前后的磁盘空间对比、清理的资源列表和推荐的日常清理配置。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cron_audit',
      name: '定时任务审计',
      icon: '⏰',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '检查 crontab 配置合理性',
      content: '请审计服务器上的所有定时任务：\n'
          '1. 系统级 crontab\n'
          '   - cat /etc/crontab 查看系统主 crontab\n'
          '   - ls -la /etc/cron.d/ 查看 cron.d 目录\n'
          '   - cat /etc/cron.d/* 查看 cron.d 下的定时任务\n'
          '2. 周期性任务目录\n'
          '   - ls -la /etc/cron.hourly/\n'
          '   - ls -la /etc/cron.daily/\n'
          '   - ls -la /etc/cron.weekly/\n'
          '   - ls -la /etc/cron.monthly/\n'
          '   - cat /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/* 2>/dev/null 查看脚本内容\n'
          '3. 用户级 crontab\n'
          '   - for user in \$(cut -f1 -d: /etc/passwd); do crontab -u \$user -l 2>/dev/null && echo "--- \$user ---"; done 查看所有用户 crontab\n'
          '   - crontab -l 查看当前用户 crontab\n'
          '   - ls -la /var/spool/cron/crontabs/ (Debian) 或 /var/spool/cron/ (RHEL) 查看 crontab 文件\n'
          '4. systemd timer\n'
          '   - systemctl list-timers --all 查看所有 systemd 定时器\n'
          '   - systemctl list-timers --all --no-pager 查看详情\n'
          '   - 对每个 timer 查看对应的 service 配置\n'
          '5. anacron 配置\n'
          '   - cat /etc/anacrontab 2>/dev/null 查看 anacron 配置\n'
          '6. 审计要点\n'
          '   - 检查执行频率是否合理（是否有每分钟执行的高频任务）\n'
          '   - 检查执行时间是否冲突（多个任务同时执行）\n'
          '   - 检查任务是否有错误处理（如 set -e、错误通知）\n'
          '   - 检查任务脚本路径是否正确\n'
          '   - 检查是否有可疑的定时任务（入侵后门）\n'
          '   - 检查任务执行用户是否合理（避免 root 执行不必要的任务）\n'
          '   - 检查是否有输出重定向（避免邮件堆积）\n'
          '7. 检查 cron 日志\n'
          '   - grep CRON /var/log/syslog /var/log/cron 2>/dev/null | tail -30 查看 cron 执行日志\n'
          '   - journalctl -u cron --since "24 hours ago" --no-pager | tail -30\n'
          '   - 检查是否有执行失败的任务\n'
          '8. 检查 at 任务\n'
          '   - atq 2>/dev/null 查看待执行的一次性任务\n'
          '   - at -c <任务ID> 2>/dev/null 查看任务内容\n'
          '最后报告定时任务清单、审计发现的问题和优化建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_backup_verify',
      name: '备份验证',
      icon: '✅',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '检查备份文件是否存在/大小/可恢复性',
      content: '请验证服务器备份的有效性：\n'
          '1. 确认备份目录和策略\n'
          '   - 确认备份目录路径（常见：/backup/ /data/backup/ /mnt/backup/）\n'
          '   - ls -la /backup/ 2>/dev/null 或 find / -name "backup" -type d 2>/dev/null | head -5\n'
          '   - 确认备份方式（全量/增量/差异）和周期\n'
          '2. 检查备份文件完整性\n'
          '   - find /backup -type f -mtime -1 2>/dev/null 查看最近 24 小时内的备份\n'
          '   - find /backup -type f -mtime -7 2>/dev/null 查看最近 7 天内的备份\n'
          '   - ls -lhR /backup/ 2>/dev/null | head -50 查看备份文件列表和大小\n'
          '   - 检查备份文件大小是否合理（与上次对比，不应突然变小为 0）\n'
          '   - find /backup -type f -size 0 2>/dev/null 查找空备份文件\n'
          '3. 验证备份文件格式\n'
          '   - file /backup/<备份文件> 确认文件类型（如 gzip/tar/sql/dump）\n'
          '   - gzip -t /backup/*.gz 2>/dev/null 测试 gzip 文件完整性\n'
          '   - tar -tzf /backup/*.tar.gz 2>/dev/null | head -10 测试 tar 包内容\n'
          '   - head -20 /backup/*.sql 2>/dev/null 查看 SQL 文件头部\n'
          '   - tail -20 /backup/*.sql 2>/dev/null 查看 SQL 文件尾部\n'
          '4. 验证数据库备份内容\n'
          '   - MySQL: grep -c "CREATE TABLE" /backup/*.sql 统计建表语句数\n'
          '   - MySQL: grep -c "INSERT INTO" /backup/*.sql 统计插入语句数\n'
          '   - PostgreSQL: pg_restore -l /backup/*.dump 2>/dev/null 查看 dump 内容\n'
          '5. 验证备份可恢复性（在测试环境）\n'
          '   - 创建测试数据库：mysql -e "CREATE DATABASE test_restore;" 或 createdb test_restore\n'
          '   - 恢复备份：mysql test_restore < /backup/<备份文件>.sql\n'
          '   - 或 PostgreSQL：pg_restore -d test_restore /backup/<备份文件>.dump\n'
          '   - 验证表数量和数据量\n'
          '   - 清理测试数据：mysql -e "DROP DATABASE test_restore;" 或 dropdb test_restore\n'
          '6. 检查备份日志\n'
          '   - 查看备份脚本输出日志\n'
          '   - journalctl -u <备份服务名> --since "24 hours ago" --no-pager | tail -30\n'
          '   - 检查备份 cron 任务是否正常执行\n'
          '7. 检查远程备份（如有）\n'
          '   - 检查 rsync 同步日志\n'
          '   - 检查远程存储可达性\n'
          '   - 验证远程备份文件列表\n'
          '8. 检查备份保留策略\n'
          '   - find /backup -type f -mtime +30 -exec ls -lh {} \\; 列出超过 30 天的备份\n'
          '   - find /backup -type f -mtime +90 -exec ls -lh {} \\; 列出超过 90 天的备份\n'
          '   - 确认旧备份是否按策略清理\n'
          '最后报告备份验证结果、备份完整性状况、恢复测试结果和改进建议。',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_logrotate_check',
      name: '日志轮转检查',
      icon: '🔁',
      type: RunbookType.agent,
      category: RunbookCategory.maintenance,
      description: '检查 logrotate 配置和执行状态',
      content: '请检查 logrotate 日志轮转配置和执行状态：\n'
          '1. 检查 logrotate 安装和配置\n'
          '   - which logrotate 确认已安装\n'
          '   - logrotate --version 查看版本\n'
          '   - cat /etc/logrotate.conf 查看主配置\n'
          '   - 检查全局参数：rotate（保留份数）、weekly/daily（频率）、compress（压缩）、missingok、notifempty\n'
          '2. 检查各服务的轮转配置\n'
          '   - ls /etc/logrotate.d/ 查看各服务配置文件\n'
          '   - cat /etc/logrotate.d/* 逐个查看配置\n'
          '   - 重点关注：nginx、apache2/mysql、redis、docker、syslog 等\n'
          '3. 检查轮转状态\n'
          '   - cat /var/lib/logrotate/status 2>/dev/null 查看轮转记录\n'
          '   - cat /var/lib/logrotate/status 2>/dev/null | grep "\$(date +%Y)" 查看今年轮转记录\n'
          '   - 或 cat /var/lib/logrotate/logrotate.status 2>/dev/null (某些发行版路径不同)\n'
          '4. 测试轮转配置\n'
          '   - logrotate -d /etc/logrotate.conf 查看调试输出（dry run，不实际执行）\n'
          '   - logrotate -d /etc/logrotate.d/<服务名> 测试单个服务配置\n'
          '   - 检查输出中是否有 error 或 warning\n'
          '5. 手动执行轮转（如需要）\n'
          '   - logrotate -f /etc/logrotate.conf 强制执行轮转\n'
          '   - logrotate -f /etc/logrotate.d/<服务名> 强制执行单个服务轮转\n'
          '6. 检查轮转效果\n'
          '   - ls -la /var/log/*.log* /var/log/**/*.log* 2>/dev/null 查看轮转后的日志文件\n'
          '   - 确认是否有 .1/.gz 等轮转文件\n'
          '   - 确认当前日志文件已被截断（大小变小）\n'
          '   - 确认轮转份数符合配置\n'
          '7. 检查 cron 和 systemd timer\n'
          '   - cat /etc/cron.daily/logrotate 2>/dev/null 查看 cron 调用\n'
          '   - systemctl status logrotate.timer 2>/dev/null 查看 systemd timer\n'
          '   - systemctl list-timers logrotate.timer 2>/dev/null 查看下次执行时间\n'
          '8. 检查常见问题\n'
          '   - 日志文件持续增大未轮转：检查配置是否正确\n'
          '   - 轮转后服务继续写旧文件：检查是否需要 postrotate 重载服务\n'
          '   - 权限问题：确认 logrotate 运行用户有权限操作日志文件\n'
          '   - 磁盘满导致轮转失败：df -h 检查磁盘空间\n'
          '9. 检查应用自身日志轮转\n'
          '   - Nginx: 确认是否通过 logrotate 或自身配置轮转\n'
          '   - Docker: 检查 /etc/docker/daemon.json 中的 log-opts max-size\n'
          '   - Java 应用：检查 logback/log4j2 的 RollingFileAppender 配置\n'
          '最后报告 logrotate 配置状况、轮转状态、发现的问题和优化建议。',
      isBuiltin: true,
    ),
    // ===== 自定义类（custom）— command 类型 =====
    Runbook.create(
      id: 'builtin_cmd_uptime',
      name: '查看系统负载',
      icon: '⏱️',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看系统运行时间和平均负载',
      content: 'uptime',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_df',
      name: '查看磁盘使用',
      icon: '💾',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看各分区磁盘使用情况',
      content: 'df -h',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_free',
      name: '查看内存使用',
      icon: '🧠',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看物理内存和 swap 使用情况',
      content: 'free -h',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_ports',
      name: '查看监听端口',
      icon: '🔌',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看所有 TCP 监听端口和对应进程',
      content: 'ss -tlnp',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_users',
      name: '查看登录用户',
      icon: '👥',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看当前登录的用户及其活动',
      content: 'w',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_restart_service',
      name: '重启指定服务',
      icon: '🔄',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '重启指定的 systemd 服务',
      content: 'systemctl restart {{service}}',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_service_log',
      name: '查看服务日志',
      icon: '📋',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看指定服务最近 100 行日志',
      content: 'journalctl -u {{service}} -n 100 --no-pager',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_port_conn',
      name: '查看端口连接',
      icon: '🔗',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查看指定端口的所有 TCP 连接',
      content: 'ss -tnp | grep {{port}}',
      isBuiltin: true,
    ),
    Runbook.create(
      id: 'builtin_cmd_find_process',
      name: '查找进程',
      icon: '🔍',
      type: RunbookType.command,
      category: RunbookCategory.custom,
      description: '查找包含指定关键字的进程',
      content: 'ps aux | grep {{process}}',
      isBuiltin: true,
    ),
  ];

  /// 初始化内置 Runbook 模板（首次安装或升级时调用）
  /// 按 id 增量添加：已有的不覆盖，新模板自动追加
  static Future<void> initBuiltin() async {
    for (final rb in all) {
      final existing = await RunbooksDao.getById(rb.id);
      if (existing == null) {
        await RunbooksDao.upsert(rb);
      }
    }
  }
}
