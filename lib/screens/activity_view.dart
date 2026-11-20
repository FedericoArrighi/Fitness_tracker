import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../background.dart';
import '../csv_import.dart';
import '../db.dart';
import '../health_import.dart';
import '../hevy_api.dart';
import '../nutrients.dart';
import '../widgets.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'workout_detail_screen.dart';
import 'workouts_screen.dart';

/// Imports (Health Connect, Garmin CSV, Hevy CSV) and the list of workouts.
class ActivityPanel extends StatefulWidget {
  final VoidCallback onChanged;
  const ActivityPanel({super.key, required this.onChanged});

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  List<Workout> _workouts = []; // the most recent ones
  List<Workout> _last30 = [];
  int _total = 0;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final now = DateTime.now();
    final cut = dayKey(DateTime(now.year, now.month, now.day - 29));
    setState(() {
      _workouts = AppDb.instance.loadWorkouts('1900-01-01', limit: 8);
      _last30 = AppDb.instance.loadWorkouts(cut);
      _total = AppDb.instance.countWorkouts();
    });
  }

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
    _load();
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
    _load();
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
    _load();
    widget.onChanged();
  }

  // ---------- manual workout ----------

  Future<void> _addWorkout() async {
    final type = TextEditingController(text: 'Strength training');
    final mins = TextEditingController();
    final kcal = TextEditingController();
    var day = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) {
          void submit() {
            final m = parseNum(mins.text);
            if (type.text.trim().isEmpty || m == null || m <= 0) return;
            Navigator.pop(context, true);
          }

          return AlertDialog(
            title: const Text('Add workout'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: type,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Type'),
                  ),
                  numField(
                      controller: mins,
                      label: 'Duration',
                      suffix: 'min',
                      onSubmitted: (_) => submit()),
                  numField(
                      controller: kcal,
                      label: 'Active calories (optional)',
                      suffix: 'kcal',
                      onSubmitted: (_) => submit()),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: day,
                        firstDate: DateTime(2015),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setS(() => day = d);
                    },
                    child: Text('Date: ${dayKey(day)}'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              TextButton(onPressed: submit, child: const Text('Add')),
            ],
          );
        },
      ),
    );
    final m = parseNum(mins.text);
    if (ok != true || m == null || m <= 0) return;
    final start = DateTime(day.year, day.month, day.day, 12);
    AppDb.instance.saveWorkout(Workout(
      id: newId(),
      day: dayKey(day),
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(Duration(minutes: m.round())).millisecondsSinceEpoch,
      type: type.text.trim(),
      activeKcal: parseNum(kcal.text),
      source: 'manual',
    ));
    _load();
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

  Future<void> _open(Workout w) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutDetailScreen(workoutId: w.id)),
    );
    _load();
    widget.onChanged();
  }

  Future<void> _openAll() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WorkoutsScreen()),
    );
    _load();
    widget.onChanged();
  }

  Widget _workoutCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    final recent = _last30;
    final recentMin = recent.fold<double>(0, (s, w) => s + w.minutes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Workouts', style: title)),
                TextButton.icon(
                  onPressed: _addWorkout,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            Text(_workouts.isEmpty
                ? 'No workouts yet.'
                : '$_total in total. Last 30 days: ${recent.length} '
                    'workout(s), ${fmt(recentMin / 60)} h.'),
            for (final w in _workouts.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(catIcon(categoryOf(w.type))),
                title: Text(workoutTitle(w)),
                subtitle: Text(summaryLine(w)),
                onTap: () => _open(w),
              ),
            if (_workouts.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _openAll,
                  child: const Text('All workouts, by type...'),
                ),
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
        _workoutCard(),
      ],
    );
  }
}
