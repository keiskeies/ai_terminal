# 多机编排（Orchestrator）需求设计

## 1. 定位

**不是子 agent，是单 agent 跨主机调度。**

一个 AgentEngine 在一个对话里，按顺序调度多台主机的 executor 执行任务。不引入并发 ReAct 循环，不引入状态隔离复杂度。

**核心价值**：把"对 N 台机器做同一件事"或"把一个任务拆到 N 台机器"从手动逐台操作变成一次对话完成。

## 2. 现实场景分类

### A. 批量运维（同构操作，低风险）
| 场景 | 操作 | 风险 |
|---|---|---|
| 时间同步 | `ntpdate ntp.aliyun.com` / `chronyc makestep` | 低 |
| 清理日志 | `journalctl --vacuum-time=7d` / `find /var/log -mtime +30 -delete` | 中（误删） |
| 重启服务 | `systemctl restart nginx` | 中（业务中断） |
| 安装补丁 | `apt update && apt upgrade -y` | 高（兼容性） |
| 检查磁盘 | `df -h` / `du -sh /var/*` | 低 |
| 收集诊断 | `top -bn1` / `netstat -tlnp` / `dmesg -T` | 低 |
| 配置推送 | 同步 nginx.conf / sshd_config 到多机 | 高（配置错误） |

**共性**：操作相同，目标主机列表不同。AI 只需生成一份命令模板，在多机上重复执行。

### B. 分工部署（异构操作，高风险）
| 场景 | 角色 | 操作 |
|---|---|---|
| Web 应用 | 前端机 | 上传 dist、nginx reload |
| Web 应用 | 后端机 | 上传 jar/node、systemctl restart |
| Web 应用 | 数据库机 | 执行 SQL migration |
| Web 应用 | 缓存机 | 上传 redis.conf、重启 |
| 集群初始化 | 主节点 | `kubeadm init`、生成 join 命令 |
| 集群初始化 | 工作节点 | `kubeadm join` |
| 监控部署 | 被监控机 | 安装 node_exporter、启动 |
| 监控部署 | 监控机 | 配置 prometheus scrape、reload |

**共性**：每台机器操作不同，但有依赖关系（后端起不来 nginx 配了也 502）。

### C. 连通性验证（只读操作，低风险）
| 场景 | 操作 |
|---|---|
| 内网互通 | A→B ping、A→B 指定端口 telnet/nc |
| 服务发现 | 多机互相 DNS 解析、consul 注册查询 |
| 证书验证 | 跨机 HTTPS curl、证书链检查 |
| 防火墙验证 | A→B 指定端口连通性测试 |

**共性**：需要"从 A 机的视角去测 B 机"，必须跨 host 执行。

### D. 灾备演练（中等风险）
| 场景 | 操作 |
|---|---|
| 主备切换 | 数据库主从切换、VIP 漂移 |
| 备份恢复 | 在备份机执行恢复、校验数据 |
| 故障注入 | 模拟网络分区、服务挂掉，观察其他节点 |

**共性**：有时序，有回滚需求。

## 3. 功能边界

### 3.1 做（MVP）
- ✅ 单 agent 跨多 host 串行执行
- ✅ 主机分组与命名（"web 组"、"db 组"）
- ✅ 批量执行同一命令到多机
- ✅ 跨机连通性测试工具
- ✅ 部署矩阵持久化（任务断点恢复）
- ✅ 分阶段确认（每阶段需用户确认才继续）
- ✅ 失败策略（继续/跳过/中止，用户可选）
- ✅ 多机快照与回滚建议

### 3.2 不做（v1）
- ❌ 并发执行（串行更可控，多机并发让 AI 上下文爆炸）
- ❌ 自动拓扑发现（用户必须明确指定哪台机做什么）
- ❌ 自动回滚执行（只给建议，不自动执行危险操作）
- ❌ 实时进度条（用流式文本 + 阶段标记代替）
- ❌ 跨账户/跨云厂商编排（只支持已配置的 SSH host）

### 3.3 暂不做（v2+）
- 🔹 Playbook 录制与回放（编排完成后可保存为可复用脚本）
- 🔹 条件分支（if A 成功则执行 B，否则执行 C）
- 🔹 变量传递（A 的输出作为 B 的输入，如 kubeadm join 命令）

## 4. 用户交互设计

### 4.1 入口
- AI 面板新增"多机编排"按钮（区别于普通对话）
- 或自然语言识别：用户提到"所有服务器"、"多台"、"分别"时提示进入编排模式

### 4.2 编排对话流程

```
用户: 把本地 story 项目部署到 web 集群

AI: 我识别到这是多机部署任务，需要确认几个信息：
    1. story 项目类型？(Node.js / 静态站点 / Python)
    2. 部署到哪些机器？分别承担什么角色？
    
用户: Node.js 后端，web1 和 web2 做负载，db1 跑数据库

AI: [展示部署矩阵表单]
    ┌─────────┬──────────┬─────────────────┬──────────┐
    │ 主机    │ 角色     │ 目标路径        │ 操作     │
    ├─────────┼──────────┼─────────────────┼──────────┤
    │ web1    │ 后端     │ /opt/story      │ 上传+重启│
    │ web2    │ 后端     │ /opt/story      │ 上传+重启│
    │ db1     │ 数据库   │ -               │ 执行 SQL │
    └─────────┴──────────┴─────────────────┴──────────┘
    确认后开始？[确认执行] [修改]

用户: [确认]

AI: [阶段1/4] 本地构建...
    ✓ npm install (12s)
    ✓ npm run build (8s)
    
    [阶段2/4] 上传到 web1, web2, db1...
    ✓ web1: /opt/story (3 files, 2.1MB)
    ✓ web2: /opt/story (3 files, 2.1MB)
    ✓ db1: schema.sql
    
    [阶段3/4] 执行部署...
    [web1] systemctl restart story ✓
    [web2] systemctl restart story ✓
    [db1] mysql -u root < schema.sql ✓
    
    [阶段4/4] 连通性验证...
    [web1→web2:8080] ✓
    [web1→db1:3306] ✓
    [web2→db1:3306] ✓
    
    全部完成。
```

### 4.3 失败处理

```
AI: [阶段3/4] 执行部署...
    [web1] systemctl restart story ✓
    [web2] systemctl restart story ✗ (exit 1)
    [db1] mysql < schema.sql ✓ (未执行，被跳过)
    
    web2 失败：Job for story.service failed (exit 1)
    最近日志: TypeError: Cannot find module 'express'
    
    [中止] [跳过 web2 继续] [重试 web2]
```

## 5. 技术架构

### 5.1 核心抽象：MultiHostExecutor

```dart
/// 多机执行器：在单个 AgentEngine 内部按 hostId 路由命令
class MultiHostExecutor {
  final AgentHostRegistry _registry;
  
  /// 获取指定 host 的 executor（不切换 activeHostId，避免 UI 串台）
  CommandExecutor? executorFor(String hostId) => _registry.getExecutor(hostId);
  
  /// 在指定 host 上执行命令
  Future<CommandResult> executeOn(String hostId, String command, {Duration? timeout});
  
  /// 批量执行：同一命令在多台机上执行，返回每台的结果
  Future<Map<String, CommandResult>> executeBatch(
    List<String> hostIds, String command, {Duration? timeout});
  
  /// 跨机连通性测试
  Future<ConnectivityResult> checkConnectivity({
    required String fromHostId,
    required String targetHost,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  });
}
```

**关键设计**：
- `executeOn` 不切换 `_registry.activeHostId`，避免 R3 违规（多 host 状态污染）
- 每次执行都从 registry 取最新的 executor，不持有引用（避免重连后过期）
- 批量执行是串行的（`for` 循环），不是并发

### 5.2 编排工具集（tool-call）

#### 5.2.1 `exec_on` — 跨机执行命令
```json
{
  "hostId": "web1",
  "command": "systemctl restart nginx",
  "timeout": 30
}
```
AI 在编排模式下用 `exec_on` 替代普通命令执行，明确指定目标主机。

#### 5.2.2 `exec_batch` — 批量执行
```json
{
  "hostIds": ["web1", "web2", "web3"],
  "command": "ntpdate ntp.aliyun.com",
  "stopOnFailure": false
}
```
同一命令多机执行。`stopOnFailure=false` 时一台失败不影响其他。

#### 5.2.3 `check_connectivity` — 连通性测试
```json
{
  "fromHostId": "web1",
  "targetHost": "192.168.1.10",
  "port": 3306
}
```
内部实现：在 fromHostId 的 executor 上执行 `nc -zv -w3 target port` 或 `timeout 3 bash -c 'cat < /dev/tcp/target/port'`。

#### 5.2.4 `upload_to` — 跨机上传
```json
{
  "hostId": "web1",
  "localPath": "/Users/x/story/dist",
  "remotePath": "/opt/story",
  "recursive": true
}
```
复用现有 SftpUploadTool，增加 hostId 路由。

### 5.3 编排状态机

```dart
enum OrchestratorPhase {
  planning,      // AI 规划部署矩阵
  confirming,    // 等待用户确认矩阵
  executing,     // 执行中
  verifying,     // 连通性验证
  completed,
  failed,
  paused,        // 失败后暂停，等用户决策
}

class OrchestratorState {
  final OrchestratorPhase phase;
  final List<HostRole> matrix;        // 部署矩阵
  final Map<String, HostTaskStatus> hostStatus; // 每台机的状态
  final int currentPhaseIndex;
  final int totalPhases;
  final String? failureHostId;
  final String? failureReason;
}
```

### 5.4 编排引擎扩展

**不新建 OrchestratorEngine，扩展现有 AgentEngine**：

```dart
class AgentEngine {
  bool _orchestratorMode = false;
  MultiHostExecutor? _multiHost;
  
  /// 进入编排模式：传入可用 hostId 列表
  void enableOrchestrator(List<String> hostIds) {
    _orchestratorMode = true;
    _multiHost = MultiHostExecutor(hostIds: hostIds);
  }
  
  /// _handleExecuteAction 改造：编排模式下，命令必须带 hostId
  /// AI 输出 "动作: exec_on\n主机: web1\n命令: xxx" 
  /// 而非 "动作: execute\n命令: xxx"
}
```

**AI 的 ReAct 循环不变**，只是：
- 普通模式：`动作: execute, 命令: xxx` → 在当前 host 执行
- 编排模式：`动作: exec_on, 主机: web1, 命令: xxx` → 在指定 host 执行

这样保持了 ReAct 单循环的简洁，只是命令路由层多了 hostId 维度。

### 5.5 System Prompt 扩展（编排模式）

```
【多机编排模式】
当前可用的主机列表：
- web1 (192.168.1.11): Ubuntu 22.04, nginx 运行中
- web2 (192.168.1.12): Ubuntu 22.04, nginx 运行中  
- db1 (192.168.1.20): CentOS 7, MySQL 8

规则：
1. 每条命令必须指定目标主机，用 "动作: exec_on\n主机: web1\n命令: xxx"
2. 批量操作用 "动作: exec_batch\n主机列表: web1,web2\n命令: xxx"
3. 跨机测试用 "动作: check_connectivity\n从: web1\n目标: 192.168.1.20\n端口: 3306"
4. 高风险操作（restart/stop/修改配置）必须先告知用户并等待确认
5. 一台失败时，询问用户：中止/跳过/重试
6. 不要假设主机间网络互通，关键依赖必须用 check_connectivity 验证
```

## 6. 风险与对策

| 风险 | 对策 |
|---|---|
| **AI 误判项目类型** | 不自动判断，让用户确认部署矩阵表单 |
| **半成品状态** | 分阶段确认 + 多机快照，失败时给回滚建议 |
| **网络不可见** | check_connectivity 工具 + system prompt 强制验证关键依赖 |
| **配置文件生成错误** | nginx.conf 等关键配置走 inline 确认按钮，用户审阅 |
| **长任务超时** | 每阶段独立 timeout，不设全局超时 |
| **多 host 状态污染** | MultiHostExecutor 不切换 activeHostId，所有状态写编排 state |
| **连接断开** | 每次执行前检查 executor.isConnected，断开则标记该 host 失败 |
| **AI 上下文爆炸** | 批量操作合并结果（"web1✓ web2✓ web3✗ 原因:xxx"），不逐条展开 |

## 7. 实施分期

### Phase 1: 基础能力（MVP，1-2 周）
- [ ] MultiHostExecutor 类
- [ ] `exec_on` / `exec_batch` / `check_connectivity` 工具
- [ ] AgentEngine 编排模式开关
- [ ] 编排模式 system prompt
- [ ] 编排状态注入 OrchestratorState

**验证场景**：时间同步、日志清理、磁盘检查、连通性测试（A 类场景）

### Phase 2: 部署向导（2-3 周）
- [ ] 部署矩阵 UI（表单）
- [ ] 分阶段执行与确认
- [ ] 失败处理三选项（中止/跳过/重试）
- [ ] `upload_to` 跨机上传
- [ ] 多机快照与回滚建议

**验证场景**：Node 应用部署到多机、nginx 配置推送（B 类场景）

### Phase 3: 持久化与恢复（1 周）
- [ ] 编排任务持久化（Hive）
- [ ] 断点恢复
- [ ] 编排历史记录

### Phase 4: Playbook 录制（v2）
- [ ] 编排过程录制为 shell 脚本
- [ ] 脚本回放（不走 AI，直接执行）

## 8. 与现有架构的兼容性

| 现有机制 | 编排模式影响 |
|---|---|
| ReAct 单循环 | ✅ 不变，只多 hostId 路由 |
| tool-call 协议 | ✅ 不变，新增 4 个工具 |
| AgentHostRegistry | ✅ 不变，MultiHostExecutor 只读访问 |
| 事件去重（R4） | ✅ 不变，事件加 hostId 字段 |
| 状态机一致性（R5） | ✅ 编排有独立 phase 状态 |
| 危险命令确认 | ✅ 不变，inline 确认按钮 |
| 跨 host 隔离（R3） | ⚠️ MultiHostExecutor 必须不切换 activeHostId |
| 资源生命周期（R2） | ⚠️ 编排任务的连接复用 registry，不单独建连 |

## 9. 不做的理由

### 为什么不做并发执行
- AI 的 ReAct 是串行思考，并发执行后 AI 还是要逐个处理结果
- 多机并发失败时，AI 的上下文里会有 N 个混杂的结果，推理质量下降
- 串行执行的总时间损失通常可接受（部署瓶颈在网络和磁盘 IO，不是命令执行）

### 为什么不做自动拓扑发现
- 用户的网络环境 AI 看不见，自动猜错率太高
- "哪台机做什么"是业务决策，不是技术决策
- 让用户填表的成本远低于让 AI 猜错的成本

### 为什么不做自动回滚
- 回滚是危险操作（R5/R7），必须人工确认
- 多机回滚的依赖关系复杂（A 回滚了 B 没回滚更糟）
- 给建议 + 让用户决策，比自动执行安全
