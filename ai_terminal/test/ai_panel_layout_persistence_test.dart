import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/pages/terminal_page.dart';
import 'package:ai_terminal/services/daos.dart';

/// P0：agent 面板方向与比例的存盘契约。
///
/// 此前方向与比例都不落盘，每次启动回到默认值；这里锁住补齐后的写入约定。
/// 用例自行预置初始值，不依赖跨用例的缓存隔离。
void main() {
  group('saveAiPanelLayout', () {
    test('桌面切换方向时同时写方向与比例', () {
      saveAiPanelLayout(
        isMobile: false,
        savePosition: true,
        position: 'right',
        ratio: 0.42,
      );

      expect(SettingsDao.getCached('aiPanelPosition'), 'right');
      expect(SettingsDao.getCached('aiPanelRatio'), 0.42);
    });

    test('移动端请求保存方向时保留原值，只更新比例', () {
      // 桌面端此前已选过 bottom：移动端切到 right 显示不能把这个选择覆盖掉，
      // 否则回到桌面会被"每帧按屏幕方向算出来的值"翻转用户的显式选择
      saveAiPanelLayout(
        isMobile: false,
        savePosition: true,
        position: 'bottom',
        ratio: 0.4,
      );

      saveAiPanelLayout(
        isMobile: true,
        savePosition: true,
        position: 'right',
        ratio: 0.31,
      );

      expect(SettingsDao.getCached('aiPanelPosition'), 'bottom');
      expect(SettingsDao.getCached('aiPanelRatio'), 0.31);
    });

    test('拖拽只改比例，不动已存的方向', () {
      saveAiPanelLayout(
        isMobile: false,
        savePosition: true,
        position: 'bottom',
        ratio: 0.4,
      );

      saveAiPanelLayout(
        isMobile: false,
        savePosition: false,
        position: 'right',
        ratio: 0.55,
      );

      expect(SettingsDao.getCached('aiPanelPosition'), 'bottom');
      expect(SettingsDao.getCached('aiPanelRatio'), 0.55);
    });
  });

  group('resolveAiPanelLayout', () {
    test('没存过才用新默认 right', () {
      final r = _resolve();
      expect(r.position, 'right');
      expect(r.ratio, 0.4);
    });

    test('显式存过 bottom 的老用户不被新默认翻回去', () {
      expect(_resolve(position: 'bottom').position, 'bottom');
    });

    test('脏方向值回落到默认而不是崩', () {
      expect(_resolve(position: 'left').position, 'right');
      expect(_resolve(position: 42).position, 'right');
      expect(_resolve(position: null).position, 'right');
    });

    test('比例夹回合法区间', () {
      expect(_resolve(ratio: 0.02).ratio, 0.15);
      expect(_resolve(ratio: 0.95).ratio, 0.7);
      expect(_resolve(ratio: 0.5).ratio, 0.5);
    });

    test('非数字比例用默认值', () {
      expect(_resolve(ratio: '0.5').ratio, 0.4);
      expect(_resolve(ratio: null).ratio, 0.4);
    });
  });
}

({String position, double ratio}) _resolve({Object? position, Object? ratio}) =>
    resolveAiPanelLayout(
      storedPosition: position,
      storedRatio: ratio,
      defaultPosition: 'right',
      defaultRatio: 0.4,
      minRatio: 0.15,
      maxRatio: 0.7,
    );
