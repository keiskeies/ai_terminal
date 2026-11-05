/// 判断一条命令是否“看起来像本机 Windows 命令”。
///
/// 只用于 SSH 远程会话的提前提示：远程 Linux 收到 `D:\...` 或 PowerShell
/// 语法时，先给模型一个可读的失败观测，让它改用 local_exec，而不是把
/// PowerShell 原样发给 bash 再报一堆语法错误。
///
/// 这是启发式而非安全边界：宁可少报（漏掉的由 local_exec 提示词兜底），
/// 也不要把 `grep "D:\\" file` 这类合法远程命令全部误杀。
bool looksLikeLocalWindowsCommand(String command) {
  final text = command.trim();
  if (text.isEmpty) return false;

  // 盘符路径：D:\ / C:/，允许出现在引号、空格、=、括号之后
  final hasDrivePath =
      RegExp(r'''(^|[\s"''=(])[A-Za-z]:[\\/]''').hasMatch(text);
  // 命令以盘符路径开头（如 D:\tools\docker.exe ps）
  final startsWithDrivePath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(text);
  // PowerShell 强特征：$var=、$env:、常见 cmdlet
  final hasPowerShellConstruct = RegExp(
    r'(\$\w+\s*=|\$env:|\b(Select-Object|ForEach-Object|Where-Object|'
    r'Get-[A-Za-z]+|Set-[A-Za-z]+|New-Item|Remove-Item|Copy-Item|Move-Item|'
    r'Test-Path|Join-Path|Start-Process|Stop-Process|Write-Host|Out-File)\b)',
    caseSensitive: false,
  ).hasMatch(text);
  // 命令以 PowerShell 赋值/变量/cmdlet 开头（如 $dst=...、Get-Process ...）
  final startsWithPowerShell = RegExp(
    r'^(\$\w+\s*=|\$env:|\b(Select-Object|ForEach-Object|Where-Object|'
    r'Get-[A-Za-z]+|Set-[A-Za-z]+|New-Item|Remove-Item|Copy-Item|Move-Item|'
    r'Test-Path|Join-Path|Start-Process|Stop-Process|Write-Host|Out-File)\b)',
    caseSensitive: false,
  ).hasMatch(text);

  return (hasDrivePath && hasPowerShellConstruct) ||
      startsWithDrivePath ||
      startsWithPowerShell;
}
