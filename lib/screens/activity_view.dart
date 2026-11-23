import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../background.dart';
import '../csv_import.dart';
import '../garmin_export.dart';
import '../db.dart';
import '../health_import.dart';
import '../hevy_api.dart';
import '../nutrients.dart';
import '../widgets.dart';
import '../workout_format.dart';
import '../workout_types.dart';

/// Imports (Health Connect, Garmin CSV, Hevy CSV) and the list of workouts.
class ActivityPanel extends StatefulWidget {
  final VoidCallback onChanged;
  const ActivityPanel({super.key, required this.onChanged});

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  bool _busy = false;
  String _status = '';

  // ---------- Health Connect ----------

  Future<void> _importHealth(int days) async {
    setState(() {
      _busy = true;
      _status = 'Importing...';
    });
    final r = await HealthImport.importAll(
      days: days,
      onProgress: (t) {
        if (mounted) setState(() => _status = t);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = r.summary;
    });
    widget.onChanged();
  }

  Future<void> _importOlder() async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Import how far back?'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
                'Only data that exists in Health Connect can be imported. '
                'Long imports take several minutes: keep the app open.',
                style: TextStyle(fontSize: 12)),
          ),
          for (final d in [30, 90, 180, 365, 730, 1095, 1825])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, d),
              child: Text(d < 365
                  ? '$d days'
                  : (d == 365 ? '1 year' : '${d ~/ 365} years')),
            ),
        ],
      ),
    );
    if (days != null) _importHealth(days);
  }

  // ---------- Hevy (API) ----------

  Future<void> _hevyKey() async {
    final ctl = TextEditingController(text: AppDb.instance.getSetting('hevy_api_key') ?? '');
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hevy API key'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'In Hevy on the web (hevy.com), open Settings, then Developer, '
                  'and create an API key. This needs an active Hevy Pro subscription. '
                  'Set this up on one device only; the sync server passes the '
                  'workouts on to your other devices.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                controller: ctl,
                autofocus: true,
                onSubmitted: (_) => Navigator.pop(context, 'save'),
                decoration: const InputDecoration(labelText: 'API key'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'full'),
              child: const Text('Save and re-sync everything')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    if (choice == null) return;
    AppDb.instance.setSetting('hevy_api_key', ctl.text.trim());
    if (ctl.text.trim().isNotEmpty) await _syncHevy(full: choice == 'full');
  }

  Future<void> _syncHevy({bool full = false}) async {
    if (!HevySync.configured) {
      await _hevyKey();
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Syncing with Hevy...';
    });
    final r = await HevySync.sync(full: full);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = r.summary;
    });
    widget.onChanged();
  }

  // ---------- CSV files ----------

  Future<void> _importCsv(bool garmin) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (files.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Reading the file...';
    });
    final bytes = await files.first.readAsBytes();
    var miles = false;
    var r = await parseCsvInBackground(garmin: garmin, bytes: bytes, miles: miles);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });

    var reparsing = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) {
          final ws = r.workouts;
          String first = '', last = '';
          if (ws.isNotEmpty) {
            final days = ws.map((w) => w.day).toList()..sort();
            first = days.first;
            last = days.last;
          }
          return AlertDialog(
            title: Text(garmin ? 'Garmin Connect CSV' : 'Hevy CSV'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (r.error != null)
                      Text(r.error!,
                          style: TextStyle(color: Theme.of(context).colorScheme.error))
                    else ...[
                      Text('${ws.length} workout(s), $first to $last'),
                      if (garmin) ...[
                        const SizedBox(height: 8),
                        const Text('Distances in the file are in:'),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('km')),
                            ButtonSegment(value: true, label: Text('miles')),
                          ],
                          selected: {miles},
                          onSelectionChanged: (s) async {
                            miles = s.first;
                            setS(() => reparsing = true);
                            final nr = await parseCsvInBackground(
                                garmin: garmin, bytes: bytes, miles: miles);
                            r = nr;
                            setS(() => reparsing = false);
                          },
                        ),
                        if (reparsing) const LinearProgressIndicator(),
                      ],
                      const SizedBox(height: 8),
                      const Text('Preview:'),
                      for (final w in ws.take(6))
                        Text(
                          '${w.day}  ${workoutTitle(w)}  '
                          '${fmt(w.minutes)} min'
                          '${w.distanceM != null ? '  ${fmt(w.distanceM! / 1000)} km' : ''}'
                          '${w.activeKcal != null ? '  ${fmt(w.activeKcal!)} kcal' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (ws.length > 6)
                        const Text('...', style: TextStyle(fontSize: 12)),
                    ],
                    const SizedBox(height: 8),
                    for (final skipped in r.skips.take(6))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(skipped, style: const TextStyle(fontSize: 11)),
                      ),
                    for (final msg in r.warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(msg, style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              if (r.error == null)
                TextButton(
                    onPressed: reparsing ? null : () => Navigator.pop(context, true),
                    child: const Text('Import')),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = 'Importing ${r.workouts.length} workouts...';
    });
    final c = await importWorkoutsInBackground(r.workouts);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = 'Imported ${c.added} new workout(s), ${c.updated} updated, '
          '${c.merged} merged with sessions already recorded by another source, '
          '${c.unchanged} already present.';
    });
    widget.onChanged();
  }

  // ---------- Garmin full export (JSON files) ----------

  Future<void> _importGarminExport() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Reading ${files.length} file(s)...';
    });
    final data = <String, Uint8List>{};
    for (final f in files) {
      data[f.name] = await f.readAsBytes();
    }
    final r = await parseGarminExportInBackground(data);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
    });
    final ws = r.workouts;
    final dayKeys = r.days.keys.toList()..sort();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Garmin full export'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (r.error != null)
                  Text(r.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error))
                else ...[
                  Text('${ws.length} workout(s), ${dayKeys.length} day(s) with '
                      'steps / sleep / heart rate'
                      '${dayKeys.isEmpty ? '' : ' (${dayKeys.first} to ${dayKeys.last})'}'),
                  const SizedBox(height: 8),
                  const Text('Preview:'),
                  for (final w in (ws.toList()..sort((a, b) => b.startMs.compareTo(a.startMs))).take(6))
                    Text(
                      '${w.day}  ${workoutTitle(w)}  ${fmt(w.minutes)} min'
                      '${w.distanceM != null ? '  ${fmt(w.distanceM! / 1000)} km' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
                const SizedBox(height: 8),
                for (final msg in r.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(msg, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          if (r.error == null)
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Import')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = 'Importing ${ws.length} workouts and ${dayKeys.length} days...';
    });
    final c = await importGarminExportInBackground(r.workouts, r.days,
        kcalFixes: r.kcalFixes);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = 'Workouts: ${c.workouts.added} new, ${c.workouts.updated} updated, '
          '${c.workouts.merged} merged with sessions from another source, '
          '${c.workouts.unchanged} already present. '
          'Days: ${c.daysAdded} new, ${c.daysFilled} completed with missing values.';
    });
    widget.onChanged();
  }

  // ---------- display ----------

  Widget _importCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (HealthImport.supported) ...[
              const Text(
                  'Health Connect: your Garmin watch data reaches it through the '
                  'Garmin Connect app.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _importHealth(30),
                    icon: const Icon(Icons.health_and_safety_outlined),
                    label: const Text('Last 30 days'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _importOlder,
                    child: const Text('Older data...'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            const Text(
                'Hevy (needs Hevy Pro): reads your workouts directly, no CSV needed. '
                'Afterwards it updates itself whenever the app starts.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _syncHevy(),
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync Hevy'),
                ),
                TextButton(
                  onPressed: _busy ? null : _hevyKey,
                  child: const Text('API key...'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
                'CSV files: workouts exported from Garmin Connect (website, '
                'Activities, Export CSV) or from Hevy (Settings, Export & Import).',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _importCsv(true),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Garmin CSV'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _importCsv(false),
                  icon: const Icon(Icons.fitness_center),
                  label: const Text('Hevy CSV'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importGarminExport,
                  icon: const Icon(Icons.folder_zip),
                  label: const Text('Garmin full export'),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _importCard(),
      ],
    );
  }
}
