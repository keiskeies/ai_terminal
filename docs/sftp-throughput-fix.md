# SFTP / SSH 大文件传输吞吐修复

状态：已实现并完成本地真机对比
关联：`ai_terminal/lib/core/ssh_algorithms.dart`、`lib/services/sftp_service.dart`、`lib/services/ssh_service.dart`

---

## 1. 现象

单文件 SFTP 上传/下载长期在 **1–1.5MB/s**，而同一条链路的千兆网络实测 `delivery_rate≈278Mbps`、RTT 0.04ms、零重传。之前的分析把原因归到“SFTP 同步请求-响应协议”，但同一客户端用 **SSH exec 通道 `cat > file`** 流式传同一个文件也只有 1.46MB/s——协议解释不了这个数字。

## 2. 根因

`SSHService` / `SftpService` 创建 `SSHClient` 时没有传 `algorithms`，dartssh2 默认顺序是：

```
aes256-gcm → aes128-gcm → chacha20-poly1305 → aes256-ctr → aes128-ctr → cbc
```

服务器支持 AES-GCM，于是协商到 **aes256-gcm@openssh.com**。dartssh2 的 AES-GCM 走 PointyCastle 纯 Dart 实现，未走 AES-NI/硬件加速；在本机实测只有约 1.5MB/s。SSH exec 与 SFTP 共用这条加密通道，所以两者一样慢——此前“SFTP 协议本身”的判断是错的。

## 3. 实测矩阵（127.0.0.1 本地 OpenSSH 容器，32MB / 8MB，排除网络因素）

| 算法 | SFTP 吞吐 |
|---|---|
| 默认（AES-256-GCM） | 1.49 MB/s |
| AES-128-GCM | 1.50 MB/s |
| ChaCha20-Poly1305 | **26.06 MB/s** |
| AES-128-CTR | 18.06 MB/s |
| AES-256-CTR | 20.00 MB/s |

29MB/s 是客户端 CPU 上限，不是链路上限；换成本机 native `scp`/`rsync` 还能更高。

应用 `SSHService + SftpService` 修复前后的同一个 32MB 文件：

| 路径 | 修复前 | 修复后 |
|---|---|---|
| SFTP 上传 | 1.40 MB/s | **29.06 MB/s** |
| SFTP 下载 | 1.38 MB/s | **16.21 MB/s** |
| SSH exec 上传（cat） | 1.46 MB/s | **61.90 MB/s** |
| SSH exec 下载（cat） | 1.43 MB/s | **49.61 MB/s** |

## 4. 修复

### 4.1 统一 SSH 算法偏好

新增 `kFastSshAlgorithms`：

```
chacha20-poly1305
aes128-ctr
aes256-ctr
aes128-gcm
aes256-gcm
aes128-cbc
aes256-cbc
```

- ChaCha20-Poly1305 是 AEAD，现代 OpenSSH 默认支持；
- AES-CTR 作为高速后备，配合默认的 HMAC-SHA256 Encrypt-then-MAC；
- AES-GCM 保留给只支持 GCM 的老服务器；
- CBC 仍然最后（CVE-2008-5161）。
- 四个 `SSHClient` 构造点（`SSHService` / `SftpService` 的主连接与跳板机）全部使用该偏好；`SftpService.attachToClient` 复用 `SSHService` 的客户端，自动继承。

### 4.2 SFTP 进度回调节流

SFTP 每 16KB 回调一次，29MB/s 时接近 2000 次/秒；`SftpPanel` 每回调 `setState` 重建整个面板，会反向拖慢传输。`uploadFile` / `downloadFile` 统一节流到约 10 次/秒，完成时补一次 100%。

### 4.3 目录上传：自适应并发

旧实现是 `for (final file in allFiles) { await uploadFile(...) }`，每个文件都串行等 open/write/close/rename，还会为每个文件做一次远程 `stat`（目标检查）和一次 `_ensureRemoteDir`（父目录已在上一步建好）。20,487 个小文件会把每文件往返延迟完全叠加。

现在：

- 目录结构仍然先统一创建，但去掉每文件的父目录 `stat/mkdir`；
- 目录批量上传传 `checkExisting: false`，跳过每文件一次目标 `stat`；
- 进度回调在 service 层节流到 5 次/秒，agent 工具层再节流到 1 次/秒，避免 20k 条 `上传进度: n/20487` 事件把会话和 UI 撑爆；
- **默认使用自适应并发**（`concurrency: null`），采样最多 32 个文件估算平均大小：
  - 小文件（<256KB）→ 16 路；
  - 平均 ~1MB → 8 路；
  - 平均 ~4MB → 4 路；
  - 大文件（≥8MB）→ 2 路。
- 运行中 AIMD：连续 3 个文件失败就把并发减半（最低 1），连续 20 个文件成功后恢复 1 路，最高回到初始值；最终摘要会显示 `并发: 16 → 8（连续失败后降速）`。
- 需要固定值时传 `concurrency: 1–16`。

本地 500 个 1KB 文件实测：

| 策略 | 耗时 | 吞吐 |
|---|---|---|
| 1（旧逻辑量级） | 90.1s | 5.5 files/s |
| 4 | 23.6s | 21.1 files/s |
| 8 | 12.6s | 39.5 files/s |
| **16 / 自适应** | **7.1s** | **70.0 files/s** |

自适应在 1KB 文件上自动选 16，和固定 16 持平；相比串行约 **12.7 倍**，相比固定 8 约 **1.8 倍**。20,487 个文件按 70 files/s 估算约 5 分钟（不含大文件字节传输时间）。

### 4.4 中断与新旧上传串行

用户中断 AI 后，旧上传工具没有取消信号，会继续跑；新任务立刻再开一个 SFTP 上传，两个上传同时占带宽、进度事件还会交错（截图里 `5663/22214` 与 `1278/22214` 交替出现）。

现在：

- `SftpUploadTool` / `UploadToTool` 每 250ms 检查引擎注入的 `isTaskActive`（或工具的 cancelToken），转成 `SftpService` 的 `cancelToken`；
- `uploadDirectory` 在取下一个文件前检查令牌，`uploadFile` 监听令牌并 `writer.abort()`；当前文件中止、临时文件删除，已完成文件保留；
- `UploadDirectoryResult.cancelled` 标记取消，摘要显示 `上传已取消: x/y 个文件`，不会把部分结果伪装成成功；
- 同 `host:port:user` 的目录上传走 `DirectoryUploadLock` 串行：新任务会先等旧上传退出（进度提示“等待上一轮上传退出...”），再开始，避免两个上传同时进行。

新上传目前仍从 0 开始扫描；按 `size`/`mtime` 跳过已完成文件的断点续传是下一步可选项，本次未做。

## 5. 测试

- `test/ssh_algorithms_test.dart`：ChaCha20 必须第一，AES-CTR 在 AES-GCM 前，CBC 最后。
- `test/adaptive_concurrency_test.dart`：初始分档、连续失败减半、成功后恢复、固定模式不抖动。
- `test/upload_lock_test.dart`：同 key 串行、等待时取消、不同 key 独立。
- `test/transfer_e2e_test.dart` 在本地 OpenSSH 容器 10/10 通过（单文件、目录递归/空目录/exclude、特殊字符、失败路径、编排上传、**目录上传取消**）。
- `flutter analyze`：33 issues / 0 errors（既有基线）。
- `flutter test`：855 passed / 24 skipped。
- 本地 Docker OpenSSH 真机基准：见 §3、§4.3；临时容器/测试文件已清理，不进入仓库。

## 6. 已知边界

- 如果服务器只支持 AES-GCM（不支持 ChaCha/AES-CTR），仍会落回慢路径；此时需要换 native 传输或等待 dartssh2 的 AES-GCM 优化。
- 基准是在 Windows 本机 + 本地容器测得，不含用户服务器的 CPU/加密套件差异；但“默认 AES-GCM 慢、ChaCha 快”的排序来自实现，不是网络。
- 目录上传的并发是**文件级**的；单个大文件仍然是一条 SFTP 流。8 路并发对海量小文件收益最大，对少量超大文件不会把单文件拆段。
- 目录下载尚未做同样的文件级并发，仍是串行。

