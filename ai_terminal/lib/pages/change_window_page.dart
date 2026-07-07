import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/change_window_service.dart';

/// 变更窗口/封网期设置页
///
/// 启用后，仅允许在配置的时间窗口内执行修改性命令。
/// safe 级（只读）命令不受限制。
class ChangeWindowPage extends StatefulWidget {
  const ChangeWindowPage({super.key});

  @override
  State<ChangeWindowPage> createState() => _ChangeWindowPageState();
}

class _ChangeWindowPageState extends State<ChangeWindowPage> {
  late bool _enabled;
  late int _startHour;
  late int _endHour;
  late Set<int> _selectedWeekdays;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final cfg = ChangeWindowService.config;
    _enabled = cfg.enabled;
    _startHour = cfg.startHour;
    _endHour = cfg.endHour;
    _selectedWeekdays = Set<int>.from(cfg.allowedWeekdays);
    _loading = false;
  }

  Future<void> _save() async {
    final cfg = ChangeWindowConfig(
      enabled: _enabled,
      startHour: _startHour,
      endHour: _endHour,
      allowedWeekdays: _selectedWeekdays.toList()..sort(),
    );
    try {
      await ChangeWindowService.save(cfg);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('封网期配置已保存'),
          backgroundColor: cSuccess,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: $e'),
          backgroundColor: cDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _fmtHour(int h) => '${h.toString().padLeft(2, '0')}:00';

  String _describeWindow() {
    final start = _fmtHour(_startHour);
    final end = _fmtHour(_endHour);
    if (_startHour == _endHour) return '全天允许';
    String window;
    if (_startHour < _endHour) {
      window = '$start - $end（同日）';
    } else {
      window = '$start - 次日 $end（跨夜）';
    }
    if (_selectedWeekdays.isEmpty) {
      return '$window，每天';
    }
    const names = {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六', 7: '日'};
    final days = _selectedWeekdays.toList()..sort();
    final dayStr = days.map((d) => '周${names[d]}').join('、');
    return '$window，仅 $dayStr';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('变更窗口 / 封网期')),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // 启用开关
          Card(
            color: tc.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_enabled ? Icons.lock_clock : Icons.lock_open, color: _enabled ? cWarning : tc.textSub),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('启用封网期', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                            Text('启用后，仅允许在配置窗口内执行修改性命令',
                                style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                          ],
                        ),
                      ),
                      Switch(
                        value: _enabled,
                        activeColor: cWarning,
                        onChanged: (v) => setState(() => _enabled = v),
                      ),
                    ],
                  ),
                  if (_enabled) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cWarning.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cWarning.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 14, color: cWarning),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '当前窗口：${_describeWindow()}\n窗口外时间，AI 执行修改性命令将被拒绝（只读命令不受影响）。',
                              style: TextStyle(color: tc.textBody, fontSize: fMicro, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (_enabled) ...[
            const SizedBox(height: 16),

            // 时间窗口
            _buildSectionTitle('时间窗口'),
            Card(
              color: tc.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
              child: Padding(
                padding: const EdgeInsets.all(pStandard),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('允许变更的开始时间', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _startHour.toDouble(),
                            min: 0,
                            max: 23,
                            divisions: 23,
                            label: _fmtHour(_startHour),
                            activeColor: cPrimary,
                            onChanged: (v) => setState(() => _startHour = v.toInt()),
                          ),
                        ),
                        Container(
                          width: 60,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: cPrimary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(rSmall),
                          ),
                          child: Text(
                            _fmtHour(_startHour),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cPrimary, fontWeight: FontWeight.w600, fontSize: fBody),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('允许变更的结束时间', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _endHour.toDouble(),
                            min: 0,
                            max: 23,
                            divisions: 23,
                            label: _fmtHour(_endHour),
                            activeColor: cPrimary,
                            onChanged: (v) => setState(() => _endHour = v.toInt()),
                          ),
                        ),
                        Container(
                          width: 60,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: cPrimary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(rSmall),
                          ),
                          child: Text(
                            _fmtHour(_endHour),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cPrimary, fontWeight: FontWeight.w600, fontSize: fBody),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('提示：开始 > 结束 表示跨夜窗口（如 22:00 - 次日 06:00）',
                        style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 星期选择
            _buildSectionTitle('允许的星期（不选 = 每天）'),
            Card(
              color: tc.card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard)),
              child: Padding(
                padding: const EdgeInsets.all(pStandard),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(7, (i) {
                    final day = i + 1;
                    const names = {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六', 7: '日'};
                    final selected = _selectedWeekdays.contains(day);
                    return FilterChip(
                      label: Text('周${names[day]}'),
                      selected: selected,
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _selectedWeekdays.add(day);
                          } else {
                            _selectedWeekdays.remove(day);
                          }
                        });
                      },
                      selectedColor: cPrimary,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : tc.textBody,
                        fontSize: fSmall,
                      ),
                      backgroundColor: tc.bg,
                      side: BorderSide(color: selected ? cPrimary : tc.border),
                    );
                  }),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // 保存按钮
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save, size: 16),
            label: const Text('保存配置'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: cPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: fTitle,
          fontWeight: FontWeight.w600,
          color: tc.textMain,
        ),
      ),
    );
  }
}
