import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/constants.dart';

/// sRGB 相对亮度（WCAG 定义）
double _lin(double v) => v <= 0.03928
    ? v / 12.92
    : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double _contrast(Color a, Color b) {
  final hi = _luminance(a);
  final lo = _luminance(b);
  return (math.max(hi, lo) + 0.05) / (math.min(hi, lo) + 0.05);
}

void main() {
  group('暗色表面阶梯', () {
    test('终端 < 窗口 < 内联输出 < 卡片 < 面板 < 控件', () {
      final steps = [cTerminalBg, cBg, cTerminalOutput, cCard, cCardElevated, cSurface];
      final names = ['terminalBg', 'bg', 'terminalOutput', 'card', 'cardElevated', 'surface'];
      for (var i = 1; i < steps.length; i++) {
        expect(_luminance(steps[i]) > _luminance(steps[i - 1]), isTrue,
            reason: '${names[i]} 没有比 ${names[i - 1]} 更亮');
      }
    });

    test('面板与卡片、卡片与代码层的差足够肉眼分辨', () {
      // 旧值这两处只差 0.0035 左右，四层层层贴在一起，只能靠描边撑层级
      expect(_luminance(cCardElevated) - _luminance(cCard),
          greaterThanOrEqualTo(0.005));
      expect(_luminance(cCard) - _luminance(cTerminalBg),
          greaterThanOrEqualTo(0.005));
      expect(_luminance(cSurface) - _luminance(cCardElevated),
          greaterThanOrEqualTo(0.008));
    });

    test('最弱一档灰字在卡片和面板上仍够 4:1', () {
      expect(_contrast(cTextMuted, cCard), greaterThanOrEqualTo(4.0));
      expect(_contrast(cTextMuted, cCardElevated), greaterThanOrEqualTo(4.0));
      expect(_contrast(cTextSub, cCardElevated), greaterThanOrEqualTo(4.5));
    });

    test('数据卡片比所在气泡明显高一档，且不撞控件色', () {
      // 执行清单 / 结论 / 变更行原来用 cCard，和气泡同色，只剩一圈边框
      expect(_luminance(cCardData) - _luminance(cCard), greaterThanOrEqualTo(0.012));
      expect(_luminance(cCardData) < _luminance(cSurface), isTrue);
      // 深色里只靠亮度差不够，色相要偏一点
      expect(cCardData.g, greaterThan(cCardData.r));
      expect(_contrast(cTextBody, cCardData), greaterThanOrEqualTo(4.5));
    });
  });

  group('浅色表面阶梯', () {
    test('代码层比它的容器暗，不再与面板同为纯白', () {
      expect(_luminance(cTerminalBgLight) < _luminance(cCardLight), isTrue);
      expect(_luminance(cTerminalOutputLight) < _luminance(cTerminalBgLight), isTrue);
      expect(_luminance(cCardLight) < _luminance(cCardElevatedLight), isTrue);
      expect(_luminance(cSurfaceLight) < _luminance(cBgLight), isTrue);
      expect(_luminance(cCardLight) - _luminance(cTerminalBgLight),
          greaterThanOrEqualTo(0.03));
    });

    test('正文与次级文字在卡片、控件底上都够 4:1', () {
      expect(_contrast(cTextMainLight, cCardLight), greaterThanOrEqualTo(7.0));
      expect(_contrast(cTextSubLight, cCardLight), greaterThanOrEqualTo(4.5));
      expect(_contrast(cTextSubLight, cSurfaceLight), greaterThanOrEqualTo(4.0));
    });

    test('浅色数据卡片靠凹陷区分，且小字仍够 4.5:1', () {
      expect(_luminance(cCardLight) - _luminance(cCardDataLight),
          greaterThanOrEqualTo(0.04));
      expect(_contrast(cTextSubLight, cCardDataLight), greaterThanOrEqualTo(4.5));
    });
  });
}
