import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/sftp_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sftp_resume_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String makePart(String localPath, String token, int bytes) {
    final f = File(SftpService.partPathFor(localPath, token));
    f.writeAsBytesSync(List.filled(bytes, 0x61));
    return f.path;
  }

  group('resumeToken', () {
    test('同路径+大小+mtime 得同指纹', () {
      expect(SftpService.resumeToken('/a/x.log', 100, 1700000000),
          SftpService.resumeToken('/a/x.log', 100, 1700000000));
    });

    test('大小或 mtime 变化则指纹变化（远程被改 → 强制重下）', () {
      final base = SftpService.resumeToken('/a/x.log', 100, 1700000000);
      expect(SftpService.resumeToken('/a/x.log', 101, 1700000000), isNot(base));
      expect(SftpService.resumeToken('/a/x.log', 100, 1700000001), isNot(base));
      expect(SftpService.resumeToken('/a/y.log', 100, 1700000000), isNot(base));
    });

    test('mtime 缺失用哨兵值，仍稳定', () {
      expect(SftpService.resumeToken('/a', 5, null),
          SftpService.resumeToken('/a', 5, null));
      expect(SftpService.resumeToken('/a', 5, null),
          isNot(SftpService.resumeToken('/a', 5, 0)));
    });
  });

  group('pickResumePart', () {
    test('无残留时 resume=null', () {
      final r = SftpService.pickResumePart(const [], '/d/f.bin', 'tok', 1000);
      expect(r.resume, isNull);
      expect(r.stale, isEmpty);
    });

    test('同指纹且未满的残留可续传', () {
      final part = makePart('${tmp.path}/f.bin', 'tok', 400);
      final r = SftpService.pickResumePart([part], '${tmp.path}/f.bin', 'tok', 1000);
      expect(r.resume, part);
      expect(r.stale, isEmpty);
    });

    test('不同指纹（换了远程源/文件被改）判为陈旧', () {
      final part = makePart('${tmp.path}/f.bin', 'oldtok', 400);
      final r =
          SftpService.pickResumePart([part], '${tmp.path}/f.bin', 'tok', 1000);
      expect(r.resume, isNull);
      expect(r.stale, [part]);
    });

    test('大小已满的残留判为陈旧（防止把截断产物当完整文件）', () {
      final part = makePart('${tmp.path}/f.bin', 'tok', 1000);
      final r =
          SftpService.pickResumePart([part], '${tmp.path}/f.bin', 'tok', 1000);
      expect(r.resume, isNull);
      expect(r.stale, [part]);
    });

    test('同前缀不同后缀的文件不被误认（非本模块的临时文件）', () {
      final other = '${tmp.path}/f.bin.ai-download-tok.bak';
      File(other).writeAsStringSync('x');
      final r =
          SftpService.pickResumePart([other], '${tmp.path}/f.bin', 'tok', 1000);
      expect(r.resume, isNull);
      expect(r.stale, isEmpty);
    });

    test('残留文件读不到时判陈旧而非抛异常', () {
      final ghost = '${tmp.path}/f.bin.ai-download-tok.part';
      final r = SftpService.pickResumePart([ghost], '${tmp.path}/f.bin', 'tok', 10);
      expect(r.resume, isNull);
      expect(r.stale, [ghost]);
    });

    test('多个残留：同指纹续传，其余清理', () {
      final dir = tmp.path;
      makePart('$dir/f.bin', 'stale1', 100);
      final keep = makePart('$dir/f.bin', 'tok', 700);
      final r = SftpService.pickResumePart(
          [keep, '$dir/f.bin.ai-download-stale1.part'], '$dir/f.bin', 'tok', 5000);
      expect(r.resume, keep);
      expect(r.stale, ['$dir/f.bin.ai-download-stale1.part']);
    });
  });

  group('partPathFor', () {
    test('包含指纹且以 .part 结尾', () {
      final p = SftpService.partPathFor('/d/f.bin', 'abc123');
      expect(p, '/d/f.bin.ai-download-abc123.part');
    });
  });
}
