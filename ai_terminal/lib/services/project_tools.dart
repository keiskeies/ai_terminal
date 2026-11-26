import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'agent_tool.dart';
import 'command_executor.dart';
import 'local_terminal_service.dart';
import 'local_file_policy.dart';
import 'local_access.dart';
import '../core/safety_guard.dart';
import '../core/ui_text.dart';
import '../utils/command_heuristics.dart';
import '../utils/tool_args_parser.dart';
import '../core/l10n_holder.dart';
import '../utils/local_shell.dart';

/// 本地项目构建锁 — 全局单例，保证同一时刻只有一个构建任务在运行
/// 遵循用户决策：单项目串行，避免本地资源争抢
class BuildLock {
  BuildLock._();
  static final BuildLock _instance = BuildLock._();
  static BuildLock get instance => _instance;

  Completer<void>? _current;

  /// 获取构建锁（阻塞至获取成功）
  /// [cancelToken] 可选取消令牌，complete 时抛出 CancellationException
  Future<void> acquire({Completer<void>? cancelToken}) async {
    while (_current != null) {
      try {
        await Future.any([
          _current!.future,
          if (cancelToken != null)
            cancelToken.future
                .then((_) => throw CancellationException('构建锁等待被取消')),
        ]);
      } on CancellationException {
        rethrow;
      } catch (_) {
        // 前一个构建异常释放锁，继续尝试获取
      }
    }
    _current = Completer<void>();
  }

  /// 释放构建锁
  void release() {
    final c = _current;
    _current = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  bool get isLocked => _current != null;
}

class CancellationException implements Exception {
  final String message;
  CancellationException(this.message);
  @override
  String toString() => message;
}

/// ════════════════════════════════════════════════════════════════
/// 项目分析工具 — 读取项目元数据，识别类型、构建命令、入口
/// ════════════════════════════════════════════════════════════════
/// 参数:
///   - path: 项目根目录绝对路径（必填）
///
/// 读取策略（分层渐进，L1）:
///   - 项目元数据: package.json / pubspec.yaml / pom.xml / Cargo.toml / go.mod / requirements.txt / pyproject.toml / Gemfile / composer.json / *.csproj
///   - 项目说明: README.md / README.rst / README.txt / AGENTS.md / CLAUDE.md
///   - 部署配置: Dockerfile / docker-compose.yml / docker-compose.yaml / .env.example / Makefile / justfile
///   - CI 配置: .github/workflows/*.yml（仅文件名列表，不读内容）
///
/// 不读取源码文件（需 L3 授权，使用 local_file_read 工具）
class ProjectAnalyzeTool extends AgentTool {
  final LocalFilePolicy Function() _policyLoader;

  ProjectAnalyzeTool({LocalFilePolicy Function()? policyLoader})
      : _policyLoader = policyLoader ?? LocalFilePolicy.load;

  @override
  String get name => 'project_analyze';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description =>
      '分析本地项目目录，识别项目类型（Node/Flutter/Java/Rust/Python/Go等）、'
      '构建命令、入口文件、依赖管理器、部署配置。仅读取项目元数据文件（package.json/pubspec.yaml等）和'
      'README/AGENTS.md/CLAUDE.md，不读取源码。用于"本地项目部署到服务器"工作流的第一步。'
      '必须先调用此工具了解项目，再决定构建命令。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 项目根目录绝对路径（必填）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    if (rawPath.isEmpty) {
      return ToolResult.failure(
          UiText.t('参数缺失: path 为必填项', 'Missing parameter: path is required'));
    }

    final policy = _policyLoader();
    final authorization = await authorizeLocalPath(
      rawPath: rawPath,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: policy,
      reason: 'project_analyze 需要读取项目元数据：$rawPath',
    );
    if (!authorization.isAllowed) {
      return ToolResult.failure('项目路径未授权读取: ${authorization.reason}');
    }
    if (isTaskActive?.call() == false) {
      return ToolResult.failure('任务已取消或暂停，项目分析未执行。');
    }
    final path = authorization.resolved;
    final dir = Directory(path);
    if (!await dir.exists()) {
      return ToolResult.failure(L10n.str.ut_b01822a097(path));
    }

    onProgress?.call(UiText.t('正在分析项目结构...', 'Analyzing project structure...'));

    final result = StringBuffer();
    result
        .writeln(UiText.t('=== 项目分析报告 ===', '=== Project analysis report ==='));
    result.writeln(L10n.str.ut_f1acec8e02(dir.absolute.path));
    result.writeln();

    // 收集项目根目录下的文件
    final rootDenial = _verifyProjectRead(
      rawPath: rawPath,
      policy: policy,
      access: localAccess,
    );
    if (rootDenial != null) {
      return ToolResult.failure('项目路径授权已变化: ${rootDenial.reason}');
    }
    final entities =
        await dir.list(recursive: false, followLinks: false).toList();
    final fileNames = <String>{};
    final dirNames = <String>{};
    for (final e in entities) {
      final name = p.basename(e.path);
      if (e is File) {
        fileNames.add(name);
      } else if (e is Directory) {
        dirNames.add(name);
      }
    }

    // 1. 识别项目类型 + 构建命令
    result.writeln('--- 项目类型识别 ---');
    final projectType =
        await _detectProjectType(path, fileNames, dirNames, policy);
    result.writeln('类型: ${projectType.type}');
    if (projectType.buildCommand != null) {
      result.writeln('推荐构建命令: ${projectType.buildCommand}');
    }
    if (projectType.buildOutput != null) {
      result.writeln('构建产物目录: ${projectType.buildOutput}');
    }
    if (projectType.packageManager != null) {
      result.writeln('包管理器: ${projectType.packageManager}');
    }
    if (projectType.entryFile != null) {
      result.writeln('入口文件: ${projectType.entryFile}');
    }
    result.writeln();

    // 2. 读取项目元数据文件
    result.writeln('--- 项目元数据 ---');
    final metadataFiles = <String>[
      'package.json',
      'pubspec.yaml',
      'pubspec.yml',
      'pom.xml',
      'build.gradle',
      'build.gradle.kts',
      'Cargo.toml',
      'go.mod',
      'requirements.txt',
      'pyproject.toml',
      'setup.py',
      'Gemfile',
      'composer.json',
      'Package.swift',
      'mix.exs',
      'project.clj',
    ];
    for (final name in metadataFiles) {
      if (fileNames.contains(name)) {
        final content = await _readFileSafely(p.join(path, name),
            maxSize: 20000, projectRoot: path, policy: policy);
        if (content != null) {
          result.writeln('[$name]');
          result.writeln(content);
          result.writeln();
        }
      }
    }

    // 3. 读取说明文件
    result.writeln('--- 项目说明 ---');
    final readmeFiles = [
      'README.md',
      'README.rst',
      'README.txt',
      'README',
      'AGENTS.md',
      'CLAUDE.md'
    ];
    for (final name in readmeFiles) {
      if (fileNames.contains(name)) {
        final content = await _readFileSafely(p.join(path, name),
            maxSize: 30000, projectRoot: path, policy: policy);
        if (content != null) {
          result.writeln('[$name]');
          result.writeln(content);
          result.writeln();
        }
      }
    }

    // 4. 读取部署配置
    result.writeln('--- 部署配置 ---');
    final deployFiles = [
      'Dockerfile',
      'docker-compose.yml',
      'docker-compose.yaml',
      '.env.example',
      'Makefile',
      'justfile',
      'Procfile'
    ];
    for (final name in deployFiles) {
      if (fileNames.contains(name)) {
        final content = await _readFileSafely(p.join(path, name),
            maxSize: 15000, projectRoot: path, policy: policy);
        if (content != null) {
          result.writeln('[$name]');
          result.writeln(content);
          result.writeln();
        }
      }
    }

    // 5. CI 配置（仅文件名列表，避免 token 爆炸）
    final githubWorkflowsDir = Directory(p.join(path, '.github', 'workflows'));
    final workflowDenial = _verifyProjectRead(
      rawPath: githubWorkflowsDir.path,
      policy: policy,
      access: localAccess,
    );
    if (workflowDenial == null && await githubWorkflowsDir.exists()) {
      result.writeln('--- CI 配置 ---');
      try {
        final workflows = githubWorkflowsDir.list();
        final workflowNames = <String>[];
        await for (final w in workflows) {
          workflowNames.add(p.basename(w.path));
        }
        if (workflowNames.isNotEmpty) {
          result.writeln('.github/workflows/: ${workflowNames.join(", ")}');
          result.writeln(
              '（如需查看具体 CI 配置，请用 execute 动作 cat .github/workflows/xxx.yml）');
        }
      } catch (e) {
        debugPrint('[ProjectAnalyze] 读取 CI 配置失败: $e');
      }
      result.writeln();
    }

    // 6. 项目结构概览（一级目录，最多30个）
    result.writeln('--- 目录结构（一级） ---');
    final sortedDirs = dirNames.toList()..sort();
    final sortedFiles = fileNames.toList()..sort();
    final showDirs = sortedDirs.take(30).toList();
    final showFiles = sortedFiles.take(30).toList();
    for (final d in showDirs) {
      result.writeln('📁 $d/');
    }
    for (final f in showFiles) {
      result.writeln('📄 $f');
    }
    if (sortedDirs.length > 30) {
      result.writeln('... (省略 ${sortedDirs.length - 30} 个目录)');
    }
    if (sortedFiles.length > 30) {
      result.writeln('... (省略 ${sortedFiles.length - 30} 个文件)');
    }
    result.writeln();

    // 7. 构建产物检查
    result.writeln('--- 已有构建产物 ---');
    final outputDirs = [
      'build',
      'dist',
      'target',
      'out',
      '.next',
      '.nuxt',
      'bin',
      'obj',
      'Release',
      'Debug',
      '__pycache__',
      'node_modules'
    ];
    for (final d in outputDirs) {
      if (dirNames.contains(d)) {
        final outputDir = Directory(p.join(path, d));
        final outputDenial = _verifyProjectRead(
          rawPath: outputDir.path,
          policy: policy,
          access: localAccess,
        );
        if (outputDenial != null) continue;
        try {
          final stat = await outputDir.stat();
          result.writeln(
              '✓ $d/ (类型: ${_typeLabel(stat.type)}, 修改: ${stat.modified.toIso8601String().substring(0, 19)})');
        } catch (_) {}
      }
    }
    result.writeln();

    result.writeln('=== 分析完成 ===');
    result.writeln('提示: 若需读取源码文件，请用 execute 动作 cat <相对路径>。'
        '构建请用 build_project 工具，打包请用 package_project 工具。');

    return ToolResult.success(result.toString());
  }

  /// 检测项目类型
  Future<_ProjectTypeInfo> _detectProjectType(
    String projectPath,
    Set<String> files,
    Set<String> dirs,
    LocalFilePolicy policy,
  ) async {
    // Flutter / Dart
    if (files.contains('pubspec.yaml')) {
      // 区分 Flutter 和纯 Dart
      try {
        final content = await _readFileSafely(
          p.join(projectPath, 'pubspec.yaml'),
          maxSize: 20000,
          projectRoot: projectPath,
          policy: policy,
        );
        if (content != null &&
            content.contains('flutter:') &&
            !content.contains('sdk: dart')) {
          return const _ProjectTypeInfo(
            type: 'Flutter',
            buildCommand: 'flutter build web',
            buildOutput: 'build/web',
            packageManager: 'pub',
            entryFile: 'lib/main.dart',
          );
        }
      } catch (_) {}
      return const _ProjectTypeInfo(
        type: 'Dart',
        buildCommand: 'dart compile exe bin/main.dart',
        buildOutput: 'bin',
        packageManager: 'pub',
        entryFile: 'bin/main.dart',
      );
    }

    // Node.js
    if (files.contains('package.json')) {
      // 检查是否 Next.js / Nuxt / React / Vue
      if (dirs.contains('.next') ||
          files.contains('next.config.js') ||
          files.contains('next.config.mjs')) {
        return const _ProjectTypeInfo(
            type: 'Next.js',
            buildCommand: 'npm run build',
            buildOutput: '.next',
            packageManager: 'npm');
      }
      if (dirs.contains('.nuxt') ||
          files.contains('nuxt.config.ts') ||
          files.contains('nuxt.config.js')) {
        return const _ProjectTypeInfo(
            type: 'Nuxt',
            buildCommand: 'npm run build',
            buildOutput: '.output',
            packageManager: 'npm');
      }
      // 检查 package.json scripts
      try {
        final content = await _readFileSafely(
          p.join(projectPath, 'package.json'),
          maxSize: 20000,
          projectRoot: projectPath,
          policy: policy,
        );
        if (content != null) {
          final pkg = jsonDecode(content) as Map<String, dynamic>;
          final scripts = pkg['scripts'] as Map<String, dynamic>?;
          if (scripts != null) {
            if (scripts.containsKey('build')) {
              final buildCmd = scripts['build'].toString();
              return _ProjectTypeInfo(
                type: 'Node.js',
                buildCommand: 'npm run build',
                buildOutput: _inferBuildOutput(buildCmd, dirs),
                packageManager: pkg.containsKey('packageManager')
                    ? pkg['packageManager'].toString().split('@').first
                    : 'npm',
              );
            }
          }
        }
      } catch (_) {}
      return const _ProjectTypeInfo(type: 'Node.js', packageManager: 'npm');
    }

    // Rust
    if (files.contains('Cargo.toml')) {
      return const _ProjectTypeInfo(
        type: 'Rust',
        buildCommand: 'cargo build --release',
        buildOutput: 'target/release',
        packageManager: 'cargo',
      );
    }

    // Go
    if (files.contains('go.mod')) {
      return const _ProjectTypeInfo(
        type: 'Go',
        buildCommand: 'go build -o bin/app .',
        buildOutput: 'bin',
        packageManager: 'go modules',
      );
    }

    // Java Maven
    if (files.contains('pom.xml')) {
      return const _ProjectTypeInfo(
        type: 'Java (Maven)',
        buildCommand: 'mvn clean package -DskipTests',
        buildOutput: 'target',
        packageManager: 'maven',
      );
    }

    // Java Gradle
    if (files.contains('build.gradle') || files.contains('build.gradle.kts')) {
      return const _ProjectTypeInfo(
        type: 'Java (Gradle)',
        buildCommand: './gradlew build -x test',
        buildOutput: 'build/libs',
        packageManager: 'gradle',
      );
    }

    // Python
    if (files.contains('requirements.txt') ||
        files.contains('pyproject.toml') ||
        files.contains('setup.py')) {
      return _ProjectTypeInfo(
        type: 'Python',
        packageManager: files.contains('pyproject.toml') ? 'pip/poetry' : 'pip',
      );
    }

    // Ruby
    if (files.contains('Gemfile')) {
      return const _ProjectTypeInfo(type: 'Ruby', packageManager: 'bundler');
    }

    // PHP
    if (files.contains('composer.json')) {
      return const _ProjectTypeInfo(type: 'PHP', packageManager: 'composer');
    }

    return const _ProjectTypeInfo(type: '未知');
  }

  String? _inferBuildOutput(String buildCmd, Set<String> dirs) {
    if (buildCmd.contains('vite')) return 'dist';
    if (buildCmd.contains('webpack')) return 'dist';
    if (buildCmd.contains('tsc')) return 'dist';
    if (dirs.contains('dist')) return 'dist';
    if (dirs.contains('build')) return 'build';
    return null;
  }

  String _typeLabel(FileSystemEntityType type) {
    switch (type) {
      case FileSystemEntityType.directory:
        return '目录';
      case FileSystemEntityType.file:
        return '文件';
      case FileSystemEntityType.link:
        return '链接';
      default:
        return '未知';
    }
  }

  /// 安全读取文件（带路径检查 + 大小限制）
  Future<String?> _readFileSafely(
    String filePath, {
    required int maxSize,
    required String projectRoot,
    required LocalFilePolicy policy,
  }) async {
    try {
      final denial = _verifyProjectRead(
        rawPath: filePath,
        policy: policy,
        access: localAccess,
      );
      if (denial != null) {
        debugPrint('[ProjectAnalyze] 跳过未授权文件: $filePath (${denial.reason})');
        return null;
      }
      final check =
          SafetyGuard.checkReadPath(filePath, projectRoot: projectRoot);
      if (check.level == SafetyLevel.blocked) {
        debugPrint('[ProjectAnalyze] 跳过敏感文件: $filePath (${check.reason})');
        return null;
      }
      final file = File(filePath);
      if (!await file.exists()) return null;
      final afterExists = _verifyProjectRead(
        rawPath: filePath,
        policy: policy,
        access: localAccess,
      );
      if (afterExists != null) return null;
      final stat = await file.stat();
      final beforeRead = _verifyProjectRead(
        rawPath: filePath,
        policy: policy,
        access: localAccess,
      );
      if (beforeRead != null) return null;
      if (stat.size > maxSize) {
        // 只读前缀，别把整个大文件先读进内存再截断
        final prefix = await file
            .openRead(0, maxSize)
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        return '(文件过大 ${stat.size} 字节，仅显示前 $maxSize 字节)\n$prefix\n...(截断)';
      }
      return await file.readAsString();
    } catch (e) {
      debugPrint('[ProjectAnalyze] 读取文件失败 $filePath: $e');
      return null;
    }
  }
}

LocalPathDecision? _verifyProjectRead({
  required String rawPath,
  required LocalFilePolicy policy,
  required LocalAccessService? access,
}) {
  final initial = policy.decide(rawPath);
  if (initial.verdict == LocalPathVerdict.sensitive ||
      initial.verdict == LocalPathVerdict.reserved ||
      initial.verdict == LocalPathVerdict.escape) {
    return initial;
  }
  final current = verifyLocalPathAccess(
    rawPath: rawPath,
    expectedResolved: initial.resolved,
    mode: LocalAccessMode.read,
    access: access,
    policy: policy,
  );
  return current.isAllowed ? null : current;
}

class _ProjectTypeInfo {
  final String type;
  final String? buildCommand;
  final String? buildOutput;
  final String? packageManager;
  final String? entryFile;
  const _ProjectTypeInfo({
    required this.type,
    this.buildCommand,
    this.buildOutput,
    this.packageManager,
    this.entryFile,
  });
}

/// ════════════════════════════════════════════════════════════════
/// 项目构建工具 — 在本地执行构建命令
/// ════════════════════════════════════════════════════════════════
/// 参数:
///   - path: 项目根目录绝对路径（必填）
///   - command: 构建命令（可选，不填则用项目分析时识别的默认命令）
///
/// 通过 LocalTerminalService 在本地执行，自动 cd 到项目目录
/// 构建失败时返回失败结果，由 AI 决定是否 ask 用户"修复还是停止"
class BuildProjectTool extends AgentTool {
  final LocalFilePolicy Function() _policyLoader;
  final LocalCommandRunner? _runner;

  BuildProjectTool({
    LocalFilePolicy Function()? policyLoader,
    LocalCommandRunner? runner,
  })  : _policyLoader = policyLoader ?? LocalFilePolicy.load,
        _runner = runner;

  @override
  String get name => 'build_project';

  @override
  ToolKind get kind => ToolKind.destructive;

  @override
  // 构建/打包改的是产物目录，不是可逐文件回滚的配置变更；台账只收文件级变更
  bool get recordsChanges => false;

  @override
  String get description =>
      '在本地执行项目构建命令（如 npm run build / flutter build web / cargo build --release）。'
      '自动 cd 到项目目录，使用本地终端执行。构建失败时返回错误日志，请用 ask 动作询问用户"要我尝试修复吗"。'
      '同一时刻只允许一个构建任务运行（串行）。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 项目根目录绝对路径（必填）\n'
      '  command: 构建命令（可选，默认按项目类型自动选择）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final suppliedCommand = args.getString('command');

    if (rawPath.isEmpty) {
      return ToolResult.failure(
          UiText.t('参数缺失: path 为必填项', 'Missing parameter: path is required'));
    }

    if (executor is! LocalTerminalService) {
      return ToolResult.failure(
          'build_project 仅支持本地终端会话，当前为 SSH 远程会话。请切换到本地终端标签页。');
    }
    if (!executor.isConnected) {
      return ToolResult.failure('本地终端未连接');
    }

    final policy = _policyLoader();
    final authorization = await authorizeLocalPath(
      rawPath: rawPath,
      mode: LocalAccessMode.execute,
      access: localAccess,
      policy: policy,
      reason: 'build_project 将在项目目录执行构建命令'
          '${suppliedCommand.isEmpty ? '（自动推断）' : '：$suppliedCommand'}；'
          '构建命令可能读取或修改项目内外的文件，执行授权不是操作系统沙箱。',
    );
    if (!authorization.isAllowed) {
      return ToolResult.failure('项目目录未授权执行: ${authorization.reason}');
    }
    if (isTaskActive?.call() == false) {
      return ToolResult.failure('任务已取消或暂停，构建未执行。');
    }
    final path = authorization.resolved;
    final dir = Directory(path);
    if (!await dir.exists()) {
      return ToolResult.failure('项目目录不存在: $rawPath');
    }

    final inferredCommand = suppliedCommand.isEmpty;
    String buildCmd = suppliedCommand;
    if (buildCmd.isEmpty) {
      final readAuthorization = await authorizeLocalPath(
        rawPath: rawPath,
        mode: LocalAccessMode.read,
        access: localAccess,
        policy: policy,
        reason: 'build_project 需要读取项目元数据以推断构建命令：$rawPath',
      );
      if (!readAuthorization.isAllowed) {
        return ToolResult.failure('项目元数据未授权读取: ${readAuthorization.reason}');
      }
      buildCmd = await _inferBuildCommand(path, policy);
      if (buildCmd.isEmpty) {
        return ToolResult.failure(
            '未提供构建命令，且无法自动识别项目类型。请提供 command 参数（如 npm run build）');
      }
      onProgress?.call(L10n.str.ut_8a884e053e(buildCmd));
    }

    final cmdSafety = SafetyGuard.check(buildCmd);
    if (cmdSafety == SafetyLevel.blocked) {
      return ToolResult.failure(
          L10n.str.ut_5ab7922da3(SafetyGuard.getReason(buildCmd) ?? ''));
    }
    final shell = resolveDefaultLocalShell();
    if (shell == null) {
      return ToolResult.failure('当前平台不支持本地构建命令');
    }

    onProgress?.call(UiText.t('等待构建锁...', 'Waiting for build lock...'));
    try {
      await BuildLock.instance.acquire(cancelToken: cancelToken);
    } on CancellationException {
      return ToolResult.failure(
          UiText.t('等待构建锁时被取消', 'Cancelled while waiting for the build lock'));
    }

    try {
      if (isTaskActive?.call() == false) {
        return ToolResult.failure('任务已取消或暂停，构建未执行。');
      }
      bool authorizationStillValid() {
        final executeCheck = verifyLocalPathAccess(
          rawPath: rawPath,
          expectedResolved: path,
          mode: LocalAccessMode.execute,
          access: localAccess,
          policy: policy,
        );
        if (!executeCheck.isAllowed) return false;
        if (!inferredCommand) return true;
        final readCheck = _verifyProjectRead(
          rawPath: rawPath,
          policy: policy,
          access: localAccess,
        );
        return readCheck == null;
      }

      if (!authorizationStillValid()) {
        return ToolResult.failure('构建授权已过期或路径状态发生变化，构建未执行。');
      }
      onProgress?.call(L10n.str.ut_323ecc4b40(buildCmd));
      debugPrint('[BuildProject] 在 $path 执行: $buildCmd');

      final timeout = getCommandTimeout(buildCmd);
      final run = _runner ?? runLocalCommand;
      final result = await run(
        command: buildCmd,
        cwd: path,
        shell: shell,
        timeout: timeout,
        cancelToken: cancelToken,
      );

      final output = result.stdout;
      final stderr = result.stderr;

      if (result.success) {
        final summary =
            L10n.str.ut_dd547aa71c(result.duration.inSeconds, output);
        onProgress?.call(UiText.t('构建成功', 'Build succeeded'));
        return ToolResult.success(summary);
      } else {
        final errorDetail = StringBuffer();
        errorDetail.writeln(
            L10n.str.ut_fe98a458a9(result.exitCode, result.duration.inSeconds));
        if (result.timedOut) {
          errorDetail.writeln('⏱ 构建超时');
        }
        errorDetail.writeln();
        errorDetail.writeln('--- stdout ---');
        errorDetail.writeln(output);
        if (stderr.isNotEmpty) {
          errorDetail.writeln();
          errorDetail.writeln('--- stderr ---');
          errorDetail.writeln(stderr);
        }
        errorDetail.writeln();
        errorDetail.writeln('请用 ask 动作询问用户: "构建失败，要我尝试修复吗？还是停下来等您处理？"');
        return ToolResult.failure(errorDetail.toString(), output: output);
      }
    } finally {
      BuildLock.instance.release();
    }
  }

  Future<String> _inferBuildCommand(
    String path,
    LocalFilePolicy policy,
  ) async {
    try {
      final entities = await Directory(path)
          .list(recursive: false, followLinks: false)
          .toList();
      final fileNames =
          entities.whereType<File>().map((e) => p.basename(e.path)).toSet();

      if (fileNames.contains('pubspec.yaml')) {
        final content = await _readBuildMetadata(
          p.join(path, 'pubspec.yaml'),
          policy,
        );
        if (content != null) {
          return content.contains('flutter:')
              ? 'flutter build web --release'
              : 'dart compile exe bin/main.dart';
        }
      }

      if (fileNames.contains('package.json')) {
        final content = await _readBuildMetadata(
          p.join(path, 'package.json'),
          policy,
        );
        if (content != null) {
          final pkg = jsonDecode(content) as Map<String, dynamic>;
          final scripts = pkg['scripts'] as Map<String, dynamic>?;
          if (scripts != null && scripts.containsKey('build')) {
            return 'npm run build';
          }
        }
      }

      if (fileNames.contains('Cargo.toml')) return 'cargo build --release';
      if (fileNames.contains('go.mod')) return 'go build -o bin/app .';
      if (fileNames.contains('pom.xml')) return 'mvn clean package -DskipTests';
      if (fileNames.contains('build.gradle') ||
          fileNames.contains('build.gradle.kts')) {
        return './gradlew build -x test';
      }
    } catch (e) {
      debugPrint('[BuildProject] 推断构建命令失败: $e');
    }
    return '';
  }

  Future<String?> _readBuildMetadata(
    String filePath,
    LocalFilePolicy policy,
  ) async {
    final denial = _verifyProjectRead(
      rawPath: filePath,
      policy: policy,
      access: localAccess,
    );
    if (denial != null) return null;
    final file = File(filePath);
    if (!await file.exists()) return null;
    final stat = await file.length();
    if (stat > 1024 * 1024) return null;
    final beforeRead = _verifyProjectRead(
      rawPath: filePath,
      policy: policy,
      access: localAccess,
    );
    if (beforeRead != null) return null;
    return file.readAsString();
  }
}

/// ════════════════════════════════════════════════════════════════
/// 项目打包工具 — 将构建产物打包为 tar.gz 或 zip
/// ════════════════════════════════════════════════════════════════
/// 参数:
///   - path: 项目根目录绝对路径（必填）
///   - artifact_dir: 构建产物目录相对路径（必填，如 build/web / dist / target/release）
///   - output: 输出文件路径（可选，默认 /tmp/<basename>-<timestamp>.tar.gz）
///   - format: 格式 tar.gz 或 zip（可选，默认 tar.gz）
///   - exclude: 排除的文件名（可选，逗号分隔）
class PackageProjectTool extends AgentTool {
  final LocalFilePolicy Function() _policyLoader;
  final LocalProcessRunner? _runner;

  PackageProjectTool({
    LocalFilePolicy Function()? policyLoader,
    LocalProcessRunner? runner,
  })  : _policyLoader = policyLoader ?? LocalFilePolicy.load,
        _runner = runner;

  @override
  String get name => 'package_project';

  @override
  ToolKind get kind => ToolKind.destructive;

  @override
  // 构建/打包改的是产物目录，不是可逐文件回滚的配置变更；台账只收文件级变更
  bool get recordsChanges => false;

  @override
  String get description => '将构建产物目录打包为 tar.gz 或 zip，便于上传到服务器部署。'
      '在本地执行，使用 tar 或 zip 命令。打包完成后返回文件路径，可用 sftp_upload 上传。'
      '默认排除 .DS_Store / node_modules / .git 等无关文件。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 项目根目录绝对路径（必填）\n'
      '  artifact_dir: 构建产物目录相对路径（必填，如 build/web 或 dist）\n'
      '  output: 输出文件绝对路径（可选，默认使用系统临时目录）\n'
      '  format: 格式 tar.gz 或 zip（可选，默认 tar.gz）\n'
      '  exclude: 排除项（可选，逗号分隔）';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final artifactDir = args.getString('artifact_dir');
    final output = args.getString('output');
    final format =
        args.getString('format', defaultValue: 'tar.gz').toLowerCase();

    if (rawPath.isEmpty || artifactDir.isEmpty) {
      return ToolResult.failure('参数缺失: path 和 artifact_dir 为必填项');
    }
    if (format != 'zip' && format != 'tar.gz') {
      return ToolResult.failure('format 仅支持 zip 或 tar.gz');
    }
    if (executor is! LocalTerminalService) {
      return ToolResult.failure('package_project 仅支持本地终端会话');
    }
    if (!executor.isConnected) {
      return ToolResult.failure('本地终端未连接');
    }

    final policy = _policyLoader();
    final projectDecision = policy.decide(rawPath);
    if (projectDecision.verdict == LocalPathVerdict.sensitive ||
        projectDecision.verdict == LocalPathVerdict.reserved ||
        projectDecision.verdict == LocalPathVerdict.escape) {
      return ToolResult.failure('项目路径被安全策略拦截: ${projectDecision.reason}');
    }
    final projectPath = projectDecision.resolved;
    final artifactAbsPath = p.normalize(p.join(projectPath, artifactDir));
    if (artifactAbsPath != projectPath &&
        !p.isWithin(projectPath, artifactAbsPath)) {
      return ToolResult.failure('artifact_dir 不能跳出项目根目录');
    }

    final readAuthorization = await authorizeLocalPath(
      rawPath: artifactAbsPath,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: policy,
      reason: 'package_project 需要读取构建产物：$artifactAbsPath',
    );
    if (!readAuthorization.isAllowed) {
      return ToolResult.failure('构建产物未授权读取: ${readAuthorization.reason}');
    }
    if (isTaskActive?.call() == false) {
      return ToolResult.failure('任务已取消或暂停，打包未执行。');
    }
    final resolvedArtifact = readAuthorization.resolved;
    final artifactDirectory = Directory(resolvedArtifact);
    if (!await artifactDirectory.exists()) {
      return ToolResult.failure(
          '构建产物目录不存在: $artifactAbsPath。请先调用 build_project 工具构建项目。');
    }

    final projectName = p.basename(projectPath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final defaultExt = format == 'zip' ? 'zip' : 'tar.gz';
    final outputPath = output.isNotEmpty
        ? output
        : p.join(
            Directory.systemTemp.path, '$projectName-$timestamp.$defaultExt');
    if (!p.isAbsolute(outputPath)) {
      return ToolResult.failure('output 必须是绝对路径');
    }
    if (p.equals(resolvedArtifact, p.normalize(outputPath)) ||
        p.isWithin(resolvedArtifact, p.normalize(outputPath))) {
      return ToolResult.failure('output 不能放在构建产物目录内，以免打包自身');
    }
    if (!await Directory(p.dirname(outputPath)).exists()) {
      return ToolResult.failure('输出目录不存在: ${p.dirname(outputPath)}');
    }

    final writeAuthorization = await authorizeLocalPath(
      rawPath: outputPath,
      mode: LocalAccessMode.write,
      access: localAccess,
      policy: policy,
      reason: 'package_project 需要写入或覆盖打包文件：$outputPath',
    );
    if (!writeAuthorization.isAllowed) {
      return ToolResult.failure('打包输出未授权写入: ${writeAuthorization.reason}');
    }
    final resolvedOutput = writeAuthorization.resolved;
    if (p.equals(resolvedArtifact, resolvedOutput) ||
        p.isWithin(resolvedArtifact, resolvedOutput)) {
      return ToolResult.failure('output 不能放在构建产物目录内，以免打包自身');
    }

    // 解析排除列表
    final excludes = args.getStringList(
      'exclude',
      defaultValue: const ['.DS_Store', '.git', 'node_modules', '.svn'],
    );

    final executable = format == 'zip' ? 'zip' : 'tar';
    final packageArgs = <String>[
      if (format == 'zip') ...[
        '-r',
        resolvedOutput,
        '.'
      ] else ...[
        '-czf',
        resolvedOutput
      ],
      for (final exclude in excludes)
        if (format == 'zip') ...['-x', './$exclude', '-x', './$exclude/*'] else
          '--exclude=./$exclude',
      if (format == 'tar.gz') '.',
    ];

    final readCheck = verifyLocalPathAccess(
      rawPath: resolvedArtifact,
      expectedResolved: resolvedArtifact,
      mode: LocalAccessMode.read,
      access: localAccess,
      policy: policy,
    );
    final writeCheck = verifyLocalPathAccess(
      rawPath: outputPath,
      expectedResolved: resolvedOutput,
      mode: LocalAccessMode.write,
      access: localAccess,
      policy: policy,
    );
    if (!readCheck.isAllowed || !writeCheck.isAllowed) {
      return ToolResult.failure('打包授权已过期或路径状态发生变化，打包未执行。');
    }

    onProgress?.call(L10n.str.ut_5e9fa40ae2(artifactDir, resolvedOutput));
    debugPrint('[PackageProject] 执行: $executable $packageArgs');

    try {
      final run = _runner ?? runLocalProcess;
      final result = await run(
        executable: executable,
        args: packageArgs,
        cwd: resolvedArtifact,
        timeout: const Duration(minutes: 3),
        cancelToken: cancelToken,
      );

      if (result.success) {
        final finalReadCheck = verifyLocalPathAccess(
          rawPath: resolvedArtifact,
          expectedResolved: resolvedArtifact,
          mode: LocalAccessMode.read,
          access: localAccess,
          policy: policy,
        );
        final finalWriteCheck = verifyLocalPathAccess(
          rawPath: outputPath,
          expectedResolved: resolvedOutput,
          mode: LocalAccessMode.write,
          access: localAccess,
          policy: policy,
        );
        if (!finalReadCheck.isAllowed || !finalWriteCheck.isAllowed) {
          return ToolResult.failure('打包后授权状态或输出路径已变化。');
        }
        final outputFileObj = File(resolvedOutput);
        if (!await outputFileObj.exists()) {
          return ToolResult.failure(
              '打包命令执行成功，但输出文件不存在: $resolvedOutput\n输出: ${result.stdout}');
        }
        final fileSize = await outputFileObj.length();
        final sizeStr = _formatFileSize(fileSize);
        final summary = L10n.str.ut_9c3df15635(resolvedOutput, sizeStr);
        onProgress?.call(L10n.str.ut_7884351654(sizeStr));
        return ToolResult.success(summary);
      } else {
        return ToolResult.failure(
          L10n.str.ut_0a71fe6a29(result.exitCode, result.stdout, result.stderr),
          output: result.stdout,
        );
      }
    } catch (e) {
      return ToolResult.failure('打包异常: $e');
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
