import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../backup_service.dart';

String _size(int bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).round()} KB';

String _when(DateTime d) {
  String t(int v) => v.toString().padLeft(2, '0');
  return '${t(d.day)}.${t(d.month)}.${d.year} ${t(d.hour)}:${t(d.minute)}';
}

/// Backups of the database, restoring one, and exporting your data as CSV.
class BackupPanel extends StatefulWidget {
  const BackupPanel({super.key});

  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  List<BackupFile> _backups = [];
  String _folder = '';
  bool _busy = false;
  String _status = '';

  bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await BackupService.folder();
    final list = await BackupService.list();
    if (!mounted) return;
    setState(() {
      _folder = dir.path;
      _backups = list;
    });
  }

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _status = 'Making a backup...';
    });
    try {
      final path = await BackupService.backupNow();
      if (!mounted) return;
      setState(() => _status = 'Backup saved: ${path.split(Platform.pathSeparator).last}');
    } catch (e) {
      if (mounted) setState(() => _status = 'The backup failed: $e');
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _status = 'Exporting...';
    });
    try {
      final r = await BackupService.exportCsv();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Export finished.';
      });
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Export finished'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('These files were written to:'),
              SelectableText(r.folder, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              for (final e in r.rows.entries) Text('${e.key}: ${e.value} rows'),
            ],
          ),
          actions: [
            if (_desktop)
              TextButton(
                  onPressed: () => BackupService.openFolder(r.folder),
                  child: const Text('Open folder')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'The export failed: $e';
        });
      }
    }
    _load();
  }

  Future<void> _afterSchedule(String? error) async {
    if (!mounted) return;
    if (error != null) {
      setState(() => _status = error);
      return;
    }
    setState(() => _status = '');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore is ready'),
        content: const Text(
            'Close the app completely and open it again. The backup is put in place '
            'when the app starts. A copy of your current data was saved first, as '
            '"before_restore_...".'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    _load();
  }

  Future<void> _restoreBackup(BackupFile b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text('${b.name}\n${_when(b.modified)}\n\n'
            'Everything you entered after this backup will be replaced when the '
            'app restarts. A copy of the current data is saved first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _status = 'Preparing the restore...';
    });
    final err = await BackupService.scheduleRestoreFromFile(b.path);
    if (mounted) setState(() => _busy = false);
    await _afterSchedule(err);
  }

  Future<void> _restoreFromFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
    );
    if (files.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Reading the file...';
    });
    final bytes = await files.first.readAsBytes();
    final err = await BackupService.scheduleRestoreFromBytes(bytes);
    if (mounted) setState(() => _busy = false);
    await _afterSchedule(err);
  }

  Future<void> _delete(BackupFile b) async {
    BackupService.delete(b);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (BackupService.restorePending)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('A restore is waiting'),
              subtitle: const Text('Close the app completely and open it again to finish.'),
              trailing: TextButton(
                onPressed: () {
                  BackupService.cancelRestore();
                  setState(() {});
                },
                child: const Text('Cancel'),
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backup', style: title),
                const SizedBox(height: 4),
                const Text(
                    'A copy of everything in the app (food, workouts, weight, sleep, ...). '
                    'The app also makes one copy a day by itself and keeps the 7 newest '
                    'of those.',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _backup,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Back up now'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _export,
                      icon: const Icon(Icons.table_view),
                      label: const Text('Export as CSV'),
                    ),
                    if (_desktop && _folder.isNotEmpty)
                      TextButton(
                          onPressed: () => BackupService.openFolder(_folder),
                          child: const Text('Open folder')),
                  ],
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (_status.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status)),
                if (_folder.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Saved in:', style: TextStyle(fontSize: 12)),
                  SelectableText(_folder, style: const TextStyle(fontSize: 12)),
                  if (Platform.isAndroid)
                    const Text(
                        'On the phone, connect it to a computer with a cable to copy the files.',
                        style: TextStyle(fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Saved backups', style: title)),
                    TextButton.icon(
                      onPressed: _busy ? null : _restoreFromFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('From a file...'),
                    ),
                  ],
                ),
                if (_backups.isEmpty) const Text('No backups yet.'),
                for (final b in _backups.take(12))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(b.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${_when(b.modified)}  -  ${_size(b.bytes)}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'restore') _restoreBackup(b);
                        if (v == 'delete') _delete(b);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'restore', child: Text('Restore this backup')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                if (_backups.length > 12) Text('and ${_backups.length - 12} older ones'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
