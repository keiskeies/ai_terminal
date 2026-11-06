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
    'builtin_health_check': 'Health Check',
    'builtin_security_audit': 'Security Audit',
    'builtin_disk_check': 'Disk Investigation',
    'builtin_network_diag': 'Network Diagnostics',
    'builtin_service_check': 'Service Inspection',
    'builtin_cert_check': 'Certificate Check',
    'builtin_perf_baseline': 'Performance Baseline',
    'builtin_db_inspection': 'Database Inspection',
    'builtin_redis_inspection': 'Redis Inspection',
    'builtin_docker_inspection': 'Docker Inspection',
    'builtin_k8s_inspection': 'Kubernetes Inspection',
    'builtin_capacity_planning': 'Capacity Planning',
    'builtin_log_scan': 'Log Scan',
    'builtin_intrusion_detect': 'Intrusion Detection',
    'builtin_weak_password': 'Weak Password Check',
    'builtin_file_integrity': 'File Integrity Check',
    'builtin_privilege_audit': 'Privilege Audit',
    'builtin_firewall_audit': 'Firewall Audit',
    'builtin_cis_benchmark': 'CIS Benchmark',
    'builtin_server_init': 'Server Bootstrap',
    'builtin_app_deploy': 'Application Deploy',
    'builtin_ssl_deploy': 'SSL Certificate Deploy',
    'builtin_db_backup': 'Database Backup',
    'builtin_config_push': 'Config Push',
    'builtin_cpu_spike': 'High CPU Investigation',
    'builtin_mem_leak': 'Memory Leak Investigation',
    'builtin_service_down': 'Service Down Investigation',
    'builtin_oom_analyze': 'OOM Investigation',
    'builtin_slow_query': 'Slow Query Investigation',
    'builtin_io_bottleneck': 'Disk I/O Bottleneck',
    'builtin_log_cleanup': 'Log Cleanup',
    'builtin_sys_update': 'System Updates',
    'builtin_docker_cleanup': 'Docker Cleanup',
    'builtin_cron_audit': 'Cron Audit',
    'builtin_backup_verify': 'Backup Verification',
    'builtin_logrotate_check': 'Logrotate Check',
    'builtin_cmd_uptime': 'View System Load',
    'builtin_cmd_df': 'View Disk Usage',
    'builtin_cmd_free': 'View Memory Usage',
    'builtin_cmd_ports': 'View Listening Ports',
    'builtin_cmd_users': 'View Logged-in Users',
    'builtin_cmd_restart_service': 'Restart a Service',
    'builtin_cmd_service_log': 'View Service Logs',
    'builtin_cmd_port_conn': 'View Port Connections',
    'builtin_cmd_find_process': 'Find a Process',
  };

  static const Map<String, String> _descriptions = {
    'builtin_health_check': 'Full server check: CPU, memory, disk, services, ports, patches',
    'builtin_security_audit': 'SSH config, firewall, suspicious processes, SUID files',
    'builtin_disk_check': 'Find the files and directories filling the disk',
    'builtin_network_diag': 'Connectivity, DNS, ports, and routing diagnostics',
    'builtin_service_check': 'Check nginx/mysql/docker/redis and other services',
    'builtin_cert_check': 'Check HTTPS certificate and SSH host key expiry',
    'builtin_perf_baseline': 'Capture CPU, memory, disk I/O, and network I/O baselines',
    'builtin_db_inspection': 'MySQL/PostgreSQL connections, slow queries, tablespaces, replication',
    'builtin_redis_inspection': 'Redis memory, keys, persistence, and hit rate',
    'builtin_docker_inspection': 'Containers, images, volumes, resource usage, unhealthy containers',
    'builtin_k8s_inspection': 'Pod, Service, Deployment, and Node status',
    'builtin_capacity_planning': 'Analyze usage trends and recommend capacity changes',
    'builtin_log_scan': 'Scan system logs for ERROR/WARN entries and stack traces',
    'builtin_intrusion_detect': 'Unusual logins, suspicious processes, rootkits, backdoors',
    'builtin_weak_password': 'Password policy, empty passwords, weak accounts',
    'builtin_file_integrity': 'Detect tampering in critical system files (mtime/hash)',
    'builtin_privilege_audit': 'sudoers, crontab, SSH keys, special-permission files',
    'builtin_firewall_audit': 'Rule sanity, open ports, dangerous rules',
    'builtin_cis_benchmark': 'Baseline CIS Benchmark checks',
    'builtin_server_init': 'Install and configure baseline software on a new server',
    'builtin_app_deploy': 'Pull code, build, restart the service, health check',
    'builtin_ssl_deploy': 'Deploy or renew an HTTPS certificate and reload the service',
    'builtin_db_backup': 'Create and verify a database backup',
    'builtin_config_push': 'Push a configuration file and reload the service',
    'builtin_cpu_spike': 'Find the high-CPU process and analyze the cause',
    'builtin_mem_leak': 'Analyze memory usage and process growth',
    'builtin_service_down': 'Quickly find why a service is down',
    'builtin_oom_analyze': 'Analyze OOM killer logs and causes',
    'builtin_slow_query': 'Analyze database slow query logs',
    'builtin_io_bottleneck': 'Analyze disk I/O performance and wait time',
    'builtin_log_cleanup': 'Reclaim space from expired logs',
    'builtin_sys_update': 'Check for and install security updates',
    'builtin_docker_cleanup': 'Remove unused images, containers, and volumes',
    'builtin_cron_audit': 'Review crontab entries for correctness and risk',
    'builtin_backup_verify': 'Check backup existence, size, and restorability',
    'builtin_logrotate_check': 'Check logrotate configuration and execution',
    'builtin_cmd_uptime': 'Show uptime and average load',
    'builtin_cmd_df': 'Show disk usage per partition',
    'builtin_cmd_free': 'Show physical memory and swap usage',
    'builtin_cmd_ports': 'Show all TCP listening ports and processes',
    'builtin_cmd_users': 'Show current users and their activity',
    'builtin_cmd_restart_service': 'Restart the specified systemd service',
    'builtin_cmd_service_log': 'Show the last 100 log lines for a service',
    'builtin_cmd_port_conn': 'Show all TCP connections on a port',
    'builtin_cmd_find_process': 'Find processes matching a keyword',
  };

  static const Map<String, String> _agentContent = {
    'builtin_health_check':
        'Run a full health check on this server and report, in order:\n'
        '1. System load and CPU usage (uptime, top -bn1 | head -20)\n'
        '2. Memory usage (free -h)\n'
        '3. Disk space and inode usage (df -h, df -i)\n'
        '4. Failed systemd services\n'
        '5. Listening ports (ss -tlnp)\n'
        '6. Recent logins (last -n 10)\n'
        '7. Pending security updates, if applicable\n'
        '8. Boot time and uptime\n'
        'Finish with a concise health conclusion and flag every anomaly.',
    'builtin_security_audit':
        'Run a baseline security audit of this server and check:\n'
        '1. SSH configuration (root login, password login, port)\n'
        '2. Firewall status (ufw status / firewall-cmd --list-all / iptables -L -n)\n'
        '3. Failed logins in the last 24 hours (lastb or journalctl)\n'
        '4. Unusual processes (top processes by CPU and memory)\n'
        '5. Unexpected SUID/SGID files (first 20 results)\n'
        '6. Empty-password accounts\n'
        '7. Members of sudo/wheel\n'
        'Finish with a security score and remediation advice.',
    'builtin_disk_check':
        'Disk space is alerting. Investigate:\n'
        '1. df -h for every partition\n'
        '2. Largest directories under / up to 3 levels deep\n'
        '3. Files larger than 500 MB\n'
        '4. Size of /var/log and expired logs that can be cleaned\n'
        'Report the top 5 space consumers and cleanup suggestions. Do not delete anything.',
    'builtin_network_diag':
        'Diagnose the network of this server:\n'
        '1. Interfaces and IP addresses (ip addr)\n'
        '2. External connectivity (ping -c 3 8.8.8.8)\n'
        '3. DNS resolution (nslookup github.com or dig github.com)\n'
        '4. Routing table (ip route)\n'
        '5. Listening ports (ss -tlnp)\n'
        '6. Connection summary (ss -s)\n'
        '7. iptables/ufw rules\n'
        'Report whether the network is healthy and flag anomalies.',
    'builtin_service_check':
        'Inspect common services:\n'
        '1. Failed systemd units (systemctl --failed)\n'
        '2. For each installed service (nginx/apache, mysql/postgres, docker, redis), check active status and the last 10 log lines\n'
        'Report which services are down and the likely reason.',
    'builtin_cert_check':
        'Check certificate expiry:\n'
        '1. HTTPS certificates on configured domains (openssl s_client or certbot certificates)\n'
        '2. SSH host key fingerprint and type\n'
        'Report every expiry date and recommend renewals that are due soon.',
    'builtin_perf_baseline':
        'Collect a performance baseline:\n'
        '1. CPU count, load, and utilization\n'
        '2. Memory and swap usage\n'
        '3. Disk I/O (iostat -x 1 3 if available)\n'
        '4. Network I/O and errors\n'
        '5. Top processes by CPU and memory\n'
        'Save a concise baseline report for future comparison.',
    'builtin_db_inspection':
        'Inspect the database server:\n'
        '1. Connection count and max connections\n'
        '2. Slow query log status and top slow queries\n'
        '3. Tablespace and data directory size\n'
        '4. Replication status, if configured\n'
        '5. Key configuration values affecting performance\n'
        'Report findings and risks.',
    'builtin_redis_inspection':
        'Inspect Redis:\n'
        '1. Memory usage and maxmemory policy\n'
        '2. Key count and expiry distribution\n'
        '3. Persistence status (RDB/AOF)\n'
        '4. Hit rate and slowlog\n'
        'Report findings and risks.',
    'builtin_docker_inspection':
        'Inspect Docker:\n'
        '1. Container status and restart counts\n'
        '2. Images, volumes, and disk usage\n'
        '3. Resource usage per container\n'
        '4. Unhealthy or restarting containers and their logs\n'
        'Report issues and cleanup suggestions.',
    'builtin_k8s_inspection':
        'Inspect the Kubernetes cluster:\n'
        '1. Node status and resource pressure\n'
        '2. Pods that are not Running/Ready\n'
        '3. Deployment rollout status\n'
        '4. Services and endpoints\n'
        '5. Recent warning events\n'
        'Report unhealthy workloads and likely causes.',
    'builtin_capacity_planning':
        'Analyze capacity:\n'
        '1. CPU, memory, disk, and network usage over the available history\n'
        '2. Growth trends and current headroom\n'
        '3. Workloads close to their limits\n'
        'Give concrete capacity and scaling recommendations with thresholds.',
    'builtin_log_scan':
        'Scan system logs for problems:\n'
        '1. ERROR/WARN entries in the last 24 hours\n'
        '2. Repeated exceptions or crash loops\n'
        '3. Authentication failures and unusual patterns\n'
        'Summarize the top issues with timestamps and source services. Do not change anything.',
    'builtin_intrusion_detect':
        'Check for signs of intrusion:\n'
        '1. Unusual logins and failed login bursts\n'
        '2. Suspicious processes and network connections\n'
        '3. Rootkit/backdoor indicators\n'
        '4. Unexpected cron jobs and startup items\n'
        '5. Unexpected listening ports\n'
        'Report suspicious findings and evidence. Do not change anything.',
    'builtin_weak_password':
        'Check account and password security:\n'
        '1. Password policy in /etc/login.defs and PAM\n'
        '2. Accounts with empty passwords\n'
        '3. Accounts with weak or shared credentials (do not print hashes)\n'
        '4. Password aging settings\n'
        'Report findings and hardening steps.',
    'builtin_file_integrity':
        'Check integrity of critical system files:\n'
        '1. Verify package-managed files against package metadata where possible\n'
        '2. Look for recently modified files in /etc, /bin, /sbin, /usr/bin\n'
        '3. Report modified or suspicious files with timestamps\n'
        'Do not modify anything.',
    'builtin_privilege_audit':
        'Audit privileges:\n'
        '1. sudoers and included files\n'
        '2. crontab entries for every user\n'
        '3. SSH authorized_keys\n'
        '4. SUID/SGID files\n'
        '5. Accounts with shell access\n'
        'Report risky privileges and recommended fixes.',
    'builtin_firewall_audit':
        'Audit the firewall:\n'
        '1. Default policies\n'
        '2. Open ports and their owners\n'
        '3. Overly permissive or dangerous rules\n'
        '4. Rules that do not match any service\n'
        'Report risks and suggested changes. Do not modify rules without confirmation.',
    'builtin_cis_benchmark':
        'Run a baseline CIS Benchmark check covering:\n'
        '1. SSH hardening\n'
        '2. User and group settings\n'
        '3. File permissions\n'
        '4. Logging and auditing\n'
        '5. Kernel/network hardening\n'
        'Report passed and failed items with remediation notes.',
    'builtin_server_init':
        'Prepare this new server:\n'
        '1. Update package metadata and install common tools\n'
        '2. Set the timezone and enable time synchronization\n'
        '3. Configure basic security (updates, SSH hygiene, firewall if requested)\n'
        '4. Verify the installed services\n'
        'Report what changed and any follow-up steps. Ask before making risky changes.',
    'builtin_app_deploy':
        'Deploy the application:\n'
        '1. Pull the latest code\n'
        '2. Build or install dependencies\n'
        '3. Restart the service\n'
        '4. Run a health check and inspect the logs\n'
        'Report each step and the final result.',
    'builtin_ssl_deploy':
        'Deploy or renew the HTTPS certificate:\n'
        '1. Obtain or locate the certificate\n'
        '2. Configure the web server\n'
        '3. Reload the service\n'
        '4. Verify chain, expiry, and HTTPS access\n'
        'Report the result.',
    'builtin_db_backup':
        'Create a database backup:\n'
        '1. Identify the database engine and data size\n'
        '2. Run a consistent dump/backup\n'
        '3. Verify size and basic integrity\n'
        'Report the backup path, size, and retention recommendation.',
    'builtin_config_push':
        'Push the requested configuration file:\n'
        '1. Back up the current file\n'
        '2. Write the new configuration\n'
        '3. Validate it\n'
        '4. Reload the service and verify\n'
        'Report what changed and how to roll back.',
    'builtin_cpu_spike':
        'Investigate high CPU usage:\n'
        '1. Identify the top CPU processes and threads\n'
        '2. Check load average and recent changes\n'
        '3. Inspect the busiest process logs\n'
        'Determine the likely cause and recommend an action.',
    'builtin_mem_leak':
        'Investigate memory pressure:\n'
        '1. Memory and swap usage\n'
        '2. Top processes by memory\n'
        '3. Processes whose memory keeps growing\n'
        '4. OOM or allocation errors in logs\n'
        'Identify likely leaks and suggest next steps.',
    'builtin_service_down':
        'Diagnose why the service is down:\n'
        '1. Service status and exit code\n'
        '2. Recent logs\n'
        '3. Listening ports and dependencies\n'
        '4. Disk, memory, and permission problems\n'
        'Propose a fix and, after confirmation, apply it and verify.',
    'builtin_oom_analyze':
        'Analyze OOM events:\n'
        '1. Kernel OOM killer logs\n'
        '2. Killed processes and their memory usage\n'
        '3. Cgroup and container memory limits\n'
        '4. Likely cause and mitigation\n'
        'Report findings.',
    'builtin_slow_query':
        'Analyze database slow queries:\n'
        '1. Slow query log settings and recent entries\n'
        '2. Top queries by total and average time\n'
        '3. Execution plans where available\n'
        '4. Indexing recommendations\n'
        'Report the biggest wins.',
    'builtin_io_bottleneck':
        'Analyze disk I/O:\n'
        '1. iostat utilization and await\n'
        '2. Top I/O processes\n'
        '3. Queue depth and latency\n'
        '4. Filesystem or device limits\n'
        'Recommend improvements.',
    'builtin_log_cleanup':
        'Find space that can be reclaimed from logs:\n'
        '1. Largest log files and directories\n'
        '2. Rotation status\n'
        '3. Expired logs safe to remove\n'
        'Report a cleanup plan with reclaimable space. Do not delete anything without confirmation.',
    'builtin_sys_update':
        'Check for and install security updates:\n'
        '1. List pending updates\n'
        '2. Install security updates only\n'
        '3. Report whether a reboot is required\n'
        '4. Flag any risks or held packages',
    'builtin_docker_cleanup':
        'Find Docker resources that can be reclaimed:\n'
        '1. Dangling images and build cache\n'
        '2. Stopped containers\n'
        '3. Unused volumes\n'
        '4. Reclaimable space\n'
        'Suggest a safe cleanup. Do not remove anything without confirmation.',
    'builtin_cron_audit':
        'Audit scheduled jobs:\n'
        '1. User crontabs and /etc/cron.*\n'
        '2. systemd timers\n'
        '3. Schedules, owners, and commands\n'
        '4. Suspicious or duplicate entries\n'
        'Report risks and recommendations.',
    'builtin_backup_verify':
        'Verify backups:\n'
        '1. Backup files and locations\n'
        '2. Size and age\n'
        '3. Restorability or checksum checks\n'
        '4. Gaps against the expected schedule\n'
        'Report findings and recommendations.',
    'builtin_logrotate_check':
        'Check log rotation:\n'
        '1. logrotate configuration\n'
        '2. Cron and systemd timer execution\n'
        '3. Permissions and recent failures\n'
        '4. Files that keep growing without rotation\n'
        'Report issues and fixes.',
  };
}
