/// 一个标签内的分屏布局模型（纯数据，不碰 session、不碰 widget）。
///
/// 为什么做成「一维平铺 + 比例」而不是一棵二分树：树能表达任意布局，但每次
/// 增删都要重算父子比例，而用户实际只用得上一维的并排/上下。iTerm2 的
/// 「同一方向继续切」覆盖 99% 场景，模型小一个数量级，也就没有树的重平衡 bug。
///
/// 关键约定：**第一个 pane 就是这个标签自己**（id 为 [primaryPaneId]，等于 tabId）。
/// 页面里已有的 Terminal/service/tracker 全部挂在 tabId 上，第一条会话不动它 ——
/// AI 绑定的 executor 也就自然留在这个 pane（文档 §4 方案 B 的默认绑定 = 第一个
/// 屏）。额外的 pane 是纯用户终端，永不注册 executor。
library;

import 'package:flutter/foundation.dart';

/// 切分方向。命名按「分隔条的方向」而不是「排列方向」，避免 horizontal/vertical
/// 两种读法互相打架：[SplitDirection.vertical] = 分隔条是竖的 = 左右并排。
enum SplitDirection {
  vertical('vertical', '左右分屏', 'Split left/right'),
  horizontal('horizontal', '上下分屏', 'Split top/bottom');

  const SplitDirection(this.id, this.labelZh, this.labelEn);
  final String id;
  final String labelZh;
  final String labelEn;

  String label({required bool isZh}) => isZh ? labelZh : labelEn;

  bool get isSideBySide => this == vertical;

  static SplitDirection byId(String? id) =>
      values.firstWhere((d) => d.id == id, orElse: () => vertical);
}

/// 额外 pane 的 id：带 tabId 前缀，避免不同标签的 pane 撞车，
/// 也让页面直接用 id 当 Map 键，不必组复合键。
/// 第一个 pane 的 id 就是 tabId 本身（见文件头约定）。
String nextPaneId(String tabId, int ordinal) => '$tabId#p$ordinal';

/// 某个标签的分屏状态。不可变；所有变更返回新实例。
class PaneLayout {
  const PaneLayout({
    required this.tabId,
    required this.paneIds,
    this.direction = SplitDirection.vertical,
    required this.ratios,
    this.activePaneId,
  });

  /// 只有一个 pane（没分屏）时的构造
  factory PaneLayout.single(String tabId) => PaneLayout(
        tabId: tabId,
        paneIds: [tabId],
        ratios: const [1],
        activePaneId: tabId,
      );

  final String tabId;
  final List<String> paneIds;

  /// 与 [paneIds] 一一对应的宽度（或高度）占比，总和为 1。
  final List<double> ratios;

  final SplitDirection direction;

  /// 当前接收键盘的 pane。为 null 时按 [primaryPaneId] 处理。
  final String? activePaneId;

  String get primaryPaneId => tabId;

  int get count => paneIds.length;

  bool get isSplit => paneIds.length > 1;

  /// 上限：每多一个本地 pane 就是一个真实 PTY 进程，不能无限开。
  static const int maxPanes = 4;

  bool get canSplit => paneIds.length < maxPanes;

  String get activeOrPrimary => activePaneId ?? primaryPaneId;

  int indexOf(String paneId) => paneIds.indexOf(paneId);

  double ratioOf(String paneId) {
    final i = indexOf(paneId);
    return i < 0 ? 0 : ratios[i];
  }

  PaneLayout copyWith({
    List<String>? paneIds,
    List<double>? ratios,
    SplitDirection? direction,
    String? activePaneId,
  }) =>
      PaneLayout(
        tabId: tabId,
        paneIds: paneIds ?? this.paneIds,
        ratios: ratios ?? this.ratios,
        direction: direction ?? this.direction,
        activePaneId: activePaneId ?? this.activePaneId,
      );
}

/// 在 [afterPaneId] 之后插入一个新 pane，并均分空间。
/// 新 pane 成为活动 pane（用户刚点开分屏，注意力就在它上面）。
/// 已达上限时返回 null，调用方据此禁用入口。
({PaneLayout layout, String newPaneId})? splitAfter(
  PaneLayout layout, {
  String? afterPaneId,
}) {
  if (!layout.canSplit) return null;
  final anchor = layout.indexOf(
      afterPaneId != null && layout.indexOf(afterPaneId) >= 0
          ? afterPaneId
          : layout.activeOrPrimary);
  final at = anchor < 0 ? layout.paneIds.length - 1 : anchor + 1;
  final id = nextPaneId(layout.tabId, _nextOrdinal(layout));
  final paneIds = [...layout.paneIds]..insert(at, id);
  return (
    layout: PaneLayout(
      tabId: layout.tabId,
      paneIds: paneIds,
      // 分屏后一律均分：保留原比例会让新 pane 挤成一条缝
      ratios: List.filled(paneIds.length, 1 / paneIds.length),
      direction: layout.direction,
      activePaneId: id,
    ),
    newPaneId: id,
  );
}

/// 已用过的最大序号 + 1。删掉中间的 pane 后序号不复用，
/// 否则旧 id 会和新 pane 撞上（页面里它正是 Map 的键）。
int _nextOrdinal(PaneLayout layout) {
  var max = 0;
  final prefix = '${layout.tabId}#p';
  for (final id in layout.paneIds) {
    if (!id.startsWith(prefix)) continue;
    final n = int.tryParse(id.substring(prefix.length));
    if (n != null && n > max) max = n;
  }
  return max + 1;
}

/// 关掉一个 pane，把它的位置让给左边/上边的邻居（iTerm2 的习惯：
/// 关闭后焦点回到相邻 pane）。关到只剩一个 pane 即回到未分屏状态。
/// 关掉的是最后一个 pane 时焦点回退到新的最后一个。
PaneLayout closePane(PaneLayout layout, String paneId) {
  final i = layout.indexOf(paneId);
  if (i < 0) return layout;
  if (layout.paneIds.length == 1) return layout;
  final paneIds = [...layout.paneIds]..removeAt(i);
  final ratios = _normalize([...layout.ratios]..removeAt(i));
  final focusIndex = i > 0 ? i - 1 : 0;
  return PaneLayout(
    tabId: layout.tabId,
    paneIds: paneIds,
    ratios: ratios,
    direction: layout.direction,
    activePaneId: paneIds[focusIndex],
  );
}

/// 换方向重排：现有 pane 顺序不变，比例保留（长度不一致时兜底均分）。
PaneLayout setDirection(PaneLayout layout, SplitDirection direction) =>
    PaneLayout(
      tabId: layout.tabId,
      paneIds: layout.paneIds,
      ratios: layout.ratios.length == layout.paneIds.length
          ? List.of(layout.ratios)
          : List.filled(layout.paneIds.length, 1 / layout.paneIds.length),
      direction: direction,
      activePaneId: layout.activePaneId,
    );

PaneLayout setActive(PaneLayout layout, String paneId) =>
    layout.indexOf(paneId) < 0 ? layout : layout.copyWith(activePaneId: paneId);

/// 拖动 [index] 与 [index+1] 之间的分隔条。[deltaRatio] 以「占比」为单位
/// （像素要由调用方按视口尺寸换算，模型不认识像素）。
///
/// 两条下限：**每一侧都不得小于 [_minRatio]**。少了这一条，一次惯性拖动会把
/// 某个 pane 拖成 0 宽，用户看不到也点不回来，只能关掉重开。
PaneLayout dragDivider(PaneLayout layout, int index, double deltaRatio) {
  if (index < 0 || index >= layout.paneIds.length - 1) return layout;
  if (layout.ratios.length != layout.paneIds.length) return layout;
  final ratios = List.of(layout.ratios);
  final pair = ratios[index] + ratios[index + 1];
  const lo = _minRatio;
  final hi = pair - _minRatio;
  // 两pane 合计已不到 2*下限时无解：夹在两条下限之间，取中点
  final left = hi <= lo
      ? pair / 2
      : (ratios[index] + deltaRatio).clamp(lo, hi).toDouble();
  ratios[index] = left;
  ratios[index + 1] = pair - left;
  return layout.copyWith(ratios: ratios);
}

/// 单个 pane 的最小占比。太窄时一屏放不下几个字符，等于废掉。
const double _minRatio = 0.15;

double get minPaneRatio => _minRatio;

/// 键盘在 pane 之间移动焦点。[forward] 为真 = 向右 / 向下。
/// 已经到头时返回 null，调用方据此什么都不做（不要绕圈：
/// 绕一圈会让用户以为终端吞了键，而焦点其实跳到了屏幕另一边）。
String? neighborPane(PaneLayout layout, String paneId, {required bool forward}) {
  final i = layout.indexOf(paneId);
  if (i < 0 || layout.paneIds.length < 2) return null;
  final next = forward ? i + 1 : i - 1;
  if (next < 0 || next >= layout.paneIds.length) return null;
  return layout.paneIds[next];
}

/// 比例归一：总和归到 1，且逐项不低于下限（钳完再归一，避免小数误差累积）。
List<double> _normalize(List<double> ratios) {
  if (ratios.isEmpty) return const [];
  if (ratios.length == 1) return const [1];
  var sum = ratios.fold<double>(0, (a, b) => a + b);
  if (sum <= 0 || !sum.isFinite) {
    return List.filled(ratios.length, 1 / ratios.length);
  }
  var out = ratios.map((r) => r / sum).toList();
  // 下限在数量上还放得下时才钳，否则钳完反而更偏离 1
  if (_minRatio * ratios.length < 1 && out.any((r) => r < _minRatio)) {
    out = out.map((r) => r < _minRatio ? _minRatio : r).toList();
    sum = out.fold<double>(0, (a, b) => a + b);
    out = out.map((r) => r / sum).toList();
  }
  return out;
}

/// 占比换算成 `Expanded(flex:)` 的整数权重。
///
/// 用 flex 而不是 FractionallySizedBox：flex 由布局引擎保证「分完且不重叠」，
/// 浮点比例直接换宽度会出现 0.5px 缝隙；且 flex 最小为 1，
/// 任何比例都不会把某个 pane 收成 0 宽（收成 0 宽 = 用户再也点不回来）。
List<int> ratiosToFlex(List<double> ratios) {
  if (ratios.isEmpty) return const [];
  var flex = ratios.map((r) => (r * 1000).round().clamp(1, 1000)).toList();
  var sum = flex.fold<int>(0, (a, b) => a + b);
  if (sum <= 0) return List.filled(ratios.length, 1);
  // 归一到 1000：拖动过程中各项被 clamp 后总和会漂，不归一会越来越胖
  if (sum != 1000) {
    flex = flex.map((f) => (f * 1000 / sum).round().clamp(1, 1000)).toList();
  }
  return flex;
}

/// 终端 widget 能请求页面做的分屏动作。
///
/// 为什么不把布局放进 widget：pane 的会话（PTY/SSH shell）与布局必须同生命周期，
/// 而它们属于页面（页面已经有 per-tab 的 service 表）。widget 只负责「谁按了键/
/// 菜单点了哪项」，把动作转发过来；布局、会话、AI 绑定的真相始终只有一处。
class TerminalPaneActions {
  const TerminalPaneActions({
    required this.paneId,
    required this.isPrimary,
    required this.isSplit,
    required this.canSplit,
    required this.onSplit,
    required this.onClose,
    required this.onFocusNeighbor,
    required this.onFocus,
  });

  final String paneId;

  /// 首屏 = 标签本身 = AI 绑定的那一屏（文档 §4 方案 B 的默认绑定）
  final bool isPrimary;

  final bool isSplit;
  final bool canSplit;

  /// [direction] 为切分方向：vertical = 左右并排
  final void Function(SplitDirection direction) onSplit;

  final VoidCallback onClose;

  /// forward = 向右 / 向下；到边界时页面自己决定不动
  final void Function(bool forward) onFocusNeighbor;

  /// 这一屏拿到键盘焦点（xterm 点谁谁聚焦）。页面据此记活动 pane：
  /// 新 pane 插在哪、焦点往哪移都以它为准，而 AI 绑定始终跟着 [isPrimary]，
  /// 不随这里的焦点漂移（AGENTS.md R3 同源规则）。
  final VoidCallback onFocus;
}
