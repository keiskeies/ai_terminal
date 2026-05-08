import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../widgets/sftp_panel.dart';

/// SFTP 独立页面（移动端使用）
class SftpPage extends StatelessWidget {
  final String hostId;

  const SftpPage({super.key, required this.hostId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SFTP'),
      ),
      body: SftpPanel(hostId: hostId),
    );
  }
}
