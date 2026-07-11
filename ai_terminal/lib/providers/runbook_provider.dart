import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../services/daos.dart';
import '../models/runbook.dart';
import '../core/l10n_holder.dart';

const _uuid = Uuid();

// ===== 运维工作流 Provider =====
final runbooksProvider =
    StateNotifierProvider<RunbookNotifier, List<Runbook>>((ref) {
  return RunbookNotifier();
});

class RunbookNotifier extends StateNotifier<List<Runbook>> {
  RunbookNotifier() : super([]) {
    _loadFromBox();
  }

  /// 从 RunbooksDao.cached 读取全部工作流并刷新 state
  void _loadFromBox() {
    final list = RunbooksDao.cached.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = list;
  }

  /// 获取所有工作流（数据来源：RunbooksDao，已同步至 state）
  List<Runbook> getAll() {
    return state;
  }

  /// 新增工作流
  Future<void> addRunbook(Runbook rb) async {
    await RunbooksDao.upsert(rb);
    _loadFromBox();
  }

  /// 更新工作流（同步刷新 updatedAt）
  Future<void> updateRunbook(Runbook rb) async {
    rb.updatedAt = DateTime.now();
    await RunbooksDao.upsert(rb);
    _loadFromBox();
  }

  /// 删除工作流（内置模板不可删除）
  Future<void> deleteRunbook(String id) async {
    final rb = RunbooksDao.getCachedById(id);
    if (rb != null && rb.isBuiltin) {
      return;
    }
    await RunbooksDao.delete(id);
    _loadFromBox();
  }

  /// 执行次数 +1，并更新 lastRunAt
  Future<void> incrementRunCount(String id) async {
    await RunbooksDao.incrementRunCount(id);
    _loadFromBox();
  }

  /// 克隆内置模板为自定义工作流
  /// 分配新 id，名字加 "(副本)"，category=custom，isBuiltin=false
  Future<Runbook?> cloneRunbook(String id) async {
    final rb = RunbooksDao.getCachedById(id);
    if (rb == null) return null;
    final cloned = rb.clone();
    cloned.id = _uuid.v4();
    await RunbooksDao.upsert(cloned);
    _loadFromBox();
    return cloned;
  }

  /// 从 JSON 字符串批量导入工作流
  ///
  /// JSON 格式（数组）：
  /// [{ "name": "...", "icon": "...", "type": "agent|command",
  ///    "category": "inspection|security|deployment|troubleshooting|maintenance|custom",
  ///    "description": "...", "content": "..." }]
  ///
  /// 容错：单个模板解析失败跳过，不影响其他。
  /// 导入的工作流 isBuiltin = false。
  /// 返回导入成功数量。
  Future<int> importFromJson(String jsonStr) async {
    // 顶层 JSON 解析失败直接抛出，交由调用方提示用户
    final dynamic decoded = jsonDecode(jsonStr);
    if (decoded is! List) {
      throw FormatException(L10n.str.runbookJsonTopLevelArray);
    }

    int successCount = 0;
    for (final item in decoded) {
      try {
        if (item is! Map<String, dynamic>) continue;
        final name = (item['name'] ?? '').toString().trim();
        final content = (item['content'] ?? '').toString().trim();
        if (name.isEmpty || content.isEmpty) continue;

        // type 映射
        final typeStr = (item['type'] ?? 'agent').toString().toLowerCase();
        final RunbookType type;
        if (typeStr == 'command') {
          type = RunbookType.command;
        } else {
          type = RunbookType.agent;
        }

        // category 映射
        final catStr =
            (item['category'] ?? 'custom').toString().toLowerCase();
        final RunbookCategory category;
        switch (catStr) {
          case 'inspection':
            category = RunbookCategory.inspection;
            break;
          case 'security':
            category = RunbookCategory.security;
            break;
          case 'deployment':
            category = RunbookCategory.deployment;
            break;
          case 'troubleshooting':
            category = RunbookCategory.troubleshooting;
            break;
          case 'maintenance':
            category = RunbookCategory.maintenance;
            break;
          default:
            category = RunbookCategory.custom;
        }

        // icon 默认 📋
        final iconStr = (item['icon'] ?? '').toString().trim();
        final icon = iconStr.isEmpty ? '📋' : iconStr;

        // description 可选
        final descStr = (item['description'] ?? '').toString().trim();
        final description = descStr.isEmpty ? null : descStr;

        final rb = Runbook.create(
          id: _uuid.v4(),
          name: name,
          icon: icon,
          type: type,
          category: category,
          content: content,
          description: description,
          isBuiltin: false,
        );
        await RunbooksDao.upsert(rb);
        successCount++;
      } catch (_) {
        // 单个解析失败跳过
        continue;
      }
    }

    if (successCount > 0) {
      _loadFromBox();
    }
    return successCount;
  }
}
