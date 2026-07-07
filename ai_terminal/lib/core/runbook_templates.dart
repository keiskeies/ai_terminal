/// 预设 Runbook 模板 — 一键调用常见运维流程
///
/// 每个模板是一段发给 AI 的自然语言任务描述，AI 会按 ReAct 框架执行。
/// 模板内容偏向"只读巡检"，避免一键触发修改性操作。

class RunbookTemplate {
  final String id;
  final String name;
  final String icon;
  final String description;
  final String prompt;

  const RunbookTemplate({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.prompt,
  });
}

class RunbookTemplates {
  static const List<RunbookTemplate> all = [
    RunbookTemplate(
      id: 'health_check',
      name: '健康体检',
      icon: '🩺',
      description: '全面检查服务器状态：CPU/内存/磁盘/服务/端口/补丁',
      prompt: '请对当前服务器做一次全面健康体检，依次检查并报告：\n'
          '1. 系统负载与 CPU 使用率（uptime、top -bn1 | head -20）\n'
          '2. 内存使用情况（free -h）\n'
          '3. 磁盘空间与 inode 使用（df -h、df -i）\n'
          '4. 关键服务状态（systemctl 列出 failed 服务）\n'
          '5. 监听端口清单（ss -tlnp）\n'
          '6. 最近登录记录（last -n 10）\n'
          '7. 待安装的安全更新（如适用）\n'
          '8. 系统启动时间和运行时长\n'
          '最后给出一份简明的体检结论，标注异常项。',
    ),
    RunbookTemplate(
      id: 'security_audit',
      name: '安全审计',
      icon: '🛡️',
      description: 'SSH 配置、防火墙、异常进程、SUID 文件检查',
      prompt: '请对当前服务器做一次基础安全审计，检查：\n'
          '1. SSH 配置（是否禁止 root 登录、是否禁止密码登录、端口是否非默认）\n'
          '2. 防火墙状态（ufw status / firewall-cmd --list-all / iptables -L -n）\n'
          '3. 最近 24 小时登录失败记录（lastb 或 journalctl）\n'
          '4. 异常进程（按 CPU 和内存排序的 top 进程）\n'
          '5. SUID/SGID 异常文件（find / -perm /6000 -type f 2>/dev/null 限制前 20 条）\n'
          '6. 空口令账户（awk -F: "\$2==\"\"{print \$1}" /etc/shadow）\n'
          '7. sudo 组成员（getent group sudo / wheel）\n'
          '最后给出安全评分和整改建议。',
    ),
    RunbookTemplate(
      id: 'disk_check',
      name: '磁盘排查',
      icon: '💾',
      description: '找出占满磁盘的大文件/大目录',
      prompt: '服务器磁盘空间告警，请帮我排查：\n'
          '1. 先用 df -h 查看各分区使用情况\n'
          '2. 用 du -sh /* 2>/dev/null | sort -rh | head -10 找出根目录下最大的子目录\n'
          '3. 针对最大的目录继续向下钻取（du -sh 该目录/* | sort -rh | head -10），最多 3 层\n'
          '4. 用 find / -type f -size +500M 2>/dev/null | head -20 列出大文件\n'
          '5. 检查日志目录 /var/log 大小\n'
          '6. 检查是否有过期的日志可清理\n'
          '最后报告前 5 大占用源，并给出清理建议（只建议，不执行清理）。',
    ),
    RunbookTemplate(
      id: 'network_diag',
      name: '网络诊断',
      icon: '🌐',
      description: '连通性/DNS/端口/路由诊断',
      prompt: '请对当前服务器做网络诊断：\n'
          '1. 检查网卡配置和 IP（ip addr）\n'
          '2. 测试外网连通性（ping -c 3 8.8.8.8）\n'
          '3. 测试 DNS 解析（nslookup github.com 或 dig github.com）\n'
          '4. 查看路由表（ip route）\n'
          '5. 查看监听端口（ss -tlnp）\n'
          '6. 查看当前已建立连接数（ss -s）\n'
          '7. 检查 iptables/ufw 规则\n'
          '最后报告网络是否正常，标注异常项。',
    ),
    RunbookTemplate(
      id: 'service_check',
      name: '服务巡检',
      icon: '⚙️',
      description: '检查常见服务（nginx/mysql/docker/redis）运行状态',
      prompt: '请巡检常见服务的运行状态：\n'
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
    ),
    RunbookTemplate(
      id: 'cert_check',
      name: '证书检查',
      icon: '🔐',
      description: '检查 HTTPS 证书和 SSH host key 到期情况',
      prompt: '请检查证书到期情况：\n'
          '1. 用 ss -tlnp 找出监听 443 端口的服务\n'
          '2. 如果有 HTTPS 服务，用 echo | openssl s_client -connect localhost:443 -servername localhost 2>/dev/null | openssl x509 -noout -dates -subject 查看证书\n'
          '3. 检查 /etc/letsencrypt/live 目录下的证书（如存在）\n'
          '4. 检查 SSH host key 指纹（ssh-keygen -l -f /etc/ssh/ssh_host_*_key.pub）\n'
          '5. 检查 /etc/ssh 下的 host key 修改时间（ls -la /etc/ssh/ssh_host_*_key*）\n'
          '最后报告证书到期日期和剩余天数，标注 30 天内到期的证书。',
    ),
  ];
}
