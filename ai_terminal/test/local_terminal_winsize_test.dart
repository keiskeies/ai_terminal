// 本地 PTY 的窗口尺寸（winsize）回归测试。
//
// 出过的问题：PTY 一律按默认 80×24 起，shell 的第一条提示符就打在这个从没
// 出现过的宽度上，之后才被视图实测列数改过去。readline 的换行/光标推算停在
// 旧宽度，表现为回显盖到相邻行、长命令看着像重复了一屏。
// 因此「视图实测尺寸必须进到 Pty.start」是要守住的约定。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/providers/terminal_provider.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';

/// 记录 resize 调用的假 PTY。`Pty.start` 的 columns/rows 到不了假对象，所以
/// 尺寸断言落在 service 自己记录的 winsize 上（见 winsizeColumnsForTesting）。
class _RecordingPty implements Pty {
  final outputController = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();

  /// 每次 resize 的 (rows, cols)，用于核对实参顺序没有传反
  final resizes = <(int, int)>[];

  @override
  Stream<Uint8List> get output => outputController.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int rows, int cols) => resizes.add((rows, cols));

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(-1);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  late ProviderContainer container;
  late TerminalNotifier notifier;
  final createdServices = <LocalTerminalService>[];
  final createdPtys = <_RecordingPty>[];

  /// 每次构造都新建一个带假 PTY 的 service：重连路径本来就要换新对象，
  /// 复用同一个会让「尺寸落在新 PTY 上」这类断言恒真。
  void useFakeServices() {
    notifier.localServiceFactoryForTesting = () {
      final pty = _RecordingPty();
      createdPtys.add(pty);
      final service = LocalTerminalService()
        ..ptyForTesting = pty
        ..powerShellProbeForTesting = () async => false;
      createdServices.add(service);
      return service;
    };
  }

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(terminalProvider.notifier);
  });

  tearDown(() {
    notifier.localServiceFactoryForTesting = null;
    for (final service in createdServices) {
      service.dispose();
    }
    createdServices.clear();
    createdPtys.clear();
    container.dispose();
  });

  test('connectLocalTab 把实测尺寸带进 PTY 启动', () async {
    useFakeServices();
    final tab = notifier.registerLocalTab()!;

    final connected =
        await notifier.connectLocalTab(tab, columns: 65, rows: 28);

    expect(connected, isNotNull);
    final service = connected!.localService!;
    expect(service.winsizeColumnsForTesting, 65);
    expect(service.winsizeRowsForTesting, 28);
  });

  test('不传尺寸时退回 80×24，而不是 0 之类无意义的值', () async {
    useFakeServices();
    final tab = notifier.registerLocalTab()!;

    final connected = await notifier.connectLocalTab(tab);

    expect(connected, isNotNull);
    expect(connected!.localService!.winsizeColumnsForTesting, 80);
    expect(connected.localService!.winsizeRowsForTesting, 24);
  });

  test('reconnectLocal 把尺寸透传给换上的新 PTY', () async {
    useFakeServices();
    final tab = notifier.registerLocalTab()!;
    final first = await notifier.connectLocalTab(tab, columns: 65, rows: 28);
    expect(first, isNotNull);
    // TerminalTab 是原地改的，必须先把旧 service 取出来，否则比对的是换完之后的值
    final oldService = first!.localService;

    final reconnected =
        await notifier.reconnectLocal(tab.id, columns: 130, rows: 28);

    expect(reconnected, isNotNull);
    final next = reconnected!.localService!;
    // 重连换的是新 service，尺寸必须落在新对象上而不是旧的那个
    expect(identical(next, oldService), isFalse);
    expect(next.winsizeColumnsForTesting, 130);
    expect(next.winsizeRowsForTesting, 28);
    expect(oldService!.winsizeColumnsForTesting, 65);
  });

  test('resize 跟随视图更新，非法尺寸整体忽略', () async {
    useFakeServices();
    final tab = notifier.registerLocalTab()!;
    final connected = await notifier.connectLocalTab(tab, columns: 65, rows: 28);
    final service = connected!.localService!;

    service.resize(130, 20);
    expect(service.winsizeColumnsForTesting, 130);
    expect(service.winsizeRowsForTesting, 20);

    // 半更新会让列与行来自不同时刻，必须整体不生效
    service.resize(0, 40);
    service.resize(80, -1);
    expect(service.winsizeColumnsForTesting, 130);
    expect(service.winsizeRowsForTesting, 20);

    // flutter_pty 的签名是 resize(rows, cols)，与 service 的 (columns, rows) 相反
    expect(createdPtys.single.resizes, [(20, 130)]);
  });
}
