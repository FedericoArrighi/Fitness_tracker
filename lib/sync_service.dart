import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'sync_store.dart';

class SyncResult {
  final int pushed; // changes sent
  final int pulled; // changes received
  final String? error;
  final String? note;
  const SyncResult(this.pushed, this.pulled, [this.error, this.note]);
}

class SyncService {
  /// Increases whenever a sync changed local data, so screens can reload.
  static final ValueNotifier<int> dataChanged = ValueNotifier(0);
  static bool _running = false;

  // What an old server (before activity data) can store.
  static const _oldServerTables = {
    'foods', 'log_entries', 'recipes', 'weights', 'targets'
  };

  static String _baseUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// The server address cleaned up (http:// added, no trailing slash).
  static String baseUrl(String raw) => _baseUrl(raw);

  static bool get configured {
    final db = AppDb.instance;
    return _baseUrl(db.getSetting('sync_url') ?? '').isNotEmpty &&
        (db.getSetting('sync_token') ?? '').isNotEmpty;
  }

  /// Returns null if the server can be reached and the token is right.
  static Future<String?> testConnection() async {
    final db = AppDb.instance;
    final url = _baseUrl(db.getSetting('sync_url') ?? '');
    final token = db.getSetting('sync_token') ?? '';
    if (url.isEmpty) return 'Enter the server address first.';
    try {
      final res = await http.get(Uri.parse('$url/ping'),
          headers: {'Authorization': 'Bearer $token'}).timeout(
          const Duration(seconds: 10));
      if (res.statusCode == 200) return null;
      if (res.statusCode == 401) {
        return 'The server answered, but the token is wrong.';
      }
      return 'The server answered with status ${res.statusCode}.';
    } catch (e) {
      return 'Could not reach the server: $e';
    }
  }

  /// Sends local changes, receives remote ones. Never throws.
  /// The work happens in a background isolate, so the screen stays smooth
  /// even when a lot of data is exchanged.
  static Future<SyncResult> run() async {
    if (_running) return const SyncResult(0, 0, 'A sync is already running.');
    _running = true;
    try {
      final path = AppDb.instance.path;
      final r = await Isolate.run(() {
        AppDb.initAt(path);
        return _syncCore();
      });
      if (r.pulled > 0) {
        AppDb.instance.invalidateWorkouts(); // the cache in this isolate is stale now
        dataChanged.value++;
      }
      return r;
    } catch (e) {
      return SyncResult(0, 0, '$e');
    } finally {
      _running = false;
    }
  }

  static Future<SyncResult> _syncCore() async {
    final db = AppDb.instance;
    final url = _baseUrl(db.getSetting('sync_url') ?? '');
    final token = db.getSetting('sync_token') ?? '';
    if (url.isEmpty || token.isEmpty) {
      return const SyncResult(0, 0, 'Sync is not set up yet.');
    }
    try {
      SyncStore.ensureTables();
      var client = db.getSetting('sync_client');
      if (client == null) {
        client = newId();
        db.setSetting('sync_client', client);
      }
      final since = int.tryParse(db.getSetting('sync_seq') ?? '') ?? 0;
      final auth = {'Authorization': 'Bearer $token'};

      // Ask the server which kinds of data it can store. An old server does
      // not know the newer ones; those are kept back until it is updated.
      var supported = _oldServerTables;
      final ping = await http
          .get(Uri.parse('$url/ping'), headers: auth)
          .timeout(const Duration(seconds: 15));
      if (ping.statusCode == 401) return const SyncResult(0, 0, 'The token is wrong.');
      if (ping.statusCode == 200) {
        final j = jsonDecode(utf8.decode(ping.bodyBytes));
        if (j is Map && j['tables'] is List) {
          supported = {for (final t in (j['tables'] as List)) t.toString()};
        }
      }

      final dirty = SyncStore.collectDirty();
      final send = [for (final r in dirty) if (supported.contains(r.tbl)) r];
      final held = dirty.length - send.length;

      final res = await http
          .post(
            Uri.parse('$url/sync'),
            headers: {...auth, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'client': client,
              'since': since,
              'records': [for (final r in send) r.toJson()],
            }),
          )
          .timeout(const Duration(seconds: 90));
      if (res.statusCode == 401) return const SyncResult(0, 0, 'The token is wrong.');
      if (res.statusCode != 200) {
        return SyncResult(0, 0, 'The server answered with status ${res.statusCode}.');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final incoming = [
        for (final j in (data['records'] as List))
          SyncRecord.fromJson((j as Map).cast<String, dynamic>())
      ];
      SyncStore.markPushed(send);
      final applied = SyncStore.applyRemote(incoming);
      db.setSetting('sync_seq', '${data['seq']}');
      db.setSetting('sync_last', DateTime.now().toIso8601String());
      return SyncResult(
        send.length,
        applied,
        null,
        held > 0
            ? '$held activity record(s) were kept back because the sync server '
                'is outdated. Replace sync_server.py with the new version and restart it.'
            : null,
      );
    } catch (e) {
      return SyncResult(0, 0, '$e');
    }
  }
}
