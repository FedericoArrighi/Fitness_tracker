import 'package:flutter/material.dart';
import '../db.dart';
import '../sync_service.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _hideToken = true;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final db = AppDb.instance;
    _url.text = db.getSetting('sync_url') ?? '';
    _token.text = db.getSetting('sync_token') ?? '';
    final last = db.getSetting('sync_last');
    if (last != null) {
      final t = DateTime.tryParse(last);
      if (t != null) {
        _status = 'Last successful sync: ${t.day}.${t.month}.${t.year} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      }
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _saveSettings() {
    AppDb.instance.setSetting('sync_url', _url.text.trim());
    AppDb.instance.setSetting('sync_token', _token.text.trim());
  }

  Future<void> _test() async {
    _saveSettings();
    setState(() {
      _busy = true;
      _status = 'Testing...';
    });
    final err = await SyncService.testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = err ?? 'Connection OK.';
    });
  }

  Future<void> _sync() async {
    _saveSettings();
    setState(() {
      _busy = true;
      _status = 'Syncing...';
    });
    final r = await SyncService.run();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = r.error != null
          ? 'Sync failed: ${r.error}'
          : 'Synced. Sent ${r.pushed} change(s), received ${r.pulled}.'
              '${r.note != null ? '\n${r.note}' : ''}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Sync keeps your phone and your computer up to date through your own sync server '
              '(the sync_server.py program). Enter its address and token on every device. '
              'The app syncs when it starts, when you return to it, and every two minutes.'),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'http://192.168.1.20:8765',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: _hideToken,
            decoration: InputDecoration(
              labelText: 'Token',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_hideToken ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hideToken = !_hideToken),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                  onPressed: _busy ? null : _test,
                  child: const Text('Test connection')),
              FilledButton(
                  onPressed: _busy ? null : _sync, child: const Text('Sync now')),
            ],
          ),
          if (_busy) const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
          const SizedBox(height: 12),
          Text(_status),
        ],
      ),
    );
  }
}
