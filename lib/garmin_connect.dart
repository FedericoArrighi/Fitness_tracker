import 'dart:convert';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'garmin_export.dart';
import 'sync_service.dart';

/// What the sync server brought back from Garmin Connect.
class GarminFetch {
  /// The workouts and days read from it (null when something went wrong).
  final GarminExportResult? result;
  final String? error;
  const GarminFetch({this.result, this.error});
}

/// Asks the sync server to fetch the newest data from Garmin Connect (it runs
/// garmin_sync.py) and downloads it. Nothing is stored in the app here: the
/// caller shows a preview first.
Future<GarminFetch> fetchGarminConnect() async {
  final db = AppDb.instance;
  final url = SyncService.baseUrl(db.getSetting('sync_url') ?? '');
  final token = db.getSetting('sync_token') ?? '';
  if (url.isEmpty || token.isEmpty) {
    return const GarminFetch(
        error: 'Set up the sync server first (Data, Sync): the server '
            'fetches the data from Garmin.');
  }
  final auth = {'Authorization': 'Bearer $token'};
  try {
    final run = await http
        .post(Uri.parse('$url/garmin/run'), headers: auth)
        .timeout(const Duration(minutes: 5));
    if (run.statusCode == 404) {
      return const GarminFetch(
          error: 'The sync server does not know the Garmin sync yet. Copy the '
              'new files into the server folder and restart the server.');
    }
    if (run.statusCode == 401) {
      return const GarminFetch(error: 'The sync token is wrong.');
    }
    if (run.statusCode != 200) {
      return GarminFetch(error: 'The server answered with status ${run.statusCode}.');
    }
    final j = jsonDecode(utf8.decode(run.bodyBytes));
    final ok = j is Map && j['ok'] == true;
    final said = j is Map ? '${j['output'] ?? ''}'.trim() : '';
    if (!ok) {
      return GarminFetch(
          error: said.isEmpty ? 'The Garmin fetch on the server failed.' : said);
    }
    final res = await http
        .get(Uri.parse('$url/garmin/inbox'), headers: auth)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      return GarminFetch(
          error: 'Could not download the data (status ${res.statusCode}).');
    }
    final inbox = jsonDecode(utf8.decode(res.bodyBytes));
    if (inbox is! Map) {
      return const GarminFetch(error: 'The server sent something unexpected.');
    }
    return GarminFetch(result: parseGarminInbox(inbox));
  } catch (e) {
    return GarminFetch(error: 'Could not reach the server: $e');
  }
}
