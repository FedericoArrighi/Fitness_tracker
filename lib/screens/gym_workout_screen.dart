import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../analysis.dart';
import '../db.dart';
import '../gym_data.dart';
import '../nutrients.dart';
import '../workout_types.dart';

class _GSet {
  String type; // normal | warmup | dropset | failure
  final TextEditingController kg;
  final TextEditingController reps;
  bool done;
  _GSet({this.type = 'normal', String kg = '', String reps = '', this.done = false})
      : kg = TextEditingController(text: kg),
        reps = TextEditingController(text: reps);
  void dispose() {
    kg.dispose();
    reps.dispose();
  }
}

class _GEx {
  String name;
  final List<_GSet> sets;
  _GEx(this.name, this.sets);
}

String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

String _hhmmss(int s) {
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

/// Asks how to start (resume, empty, repeat a previous workout) and opens
/// the logger. Returns true if a workout was saved.
Future<bool> startGymWorkout(BuildContext context) async {
  final db = AppDb.instance;
  final draft = db.getSetting('gym_draft') ?? '';
  final recent = <Workout>[];
  final seen = <String>{};
  for (final w in db.loadAllWorkouts()) {
    if (categoryOf(w.type) != Cat.strength || w.title.isEmpty) continue;
    if (seen.add(w.title.toLowerCase())) recent.add(w);
    if (recent.length >= 8) break;
  }
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Start a gym workout'),
      children: [
        if (draft.isNotEmpty)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'resume'),
            child: const Text('Resume the workout in progress'),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'empty'),
          child: const Text('Empty workout'),
        ),
        for (final w in recent)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'tpl:${w.id}'),
            child: Text('Repeat: ${w.title}  (${w.day})'),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return false;
  Workout? tpl;
  if (choice.startsWith('tpl:')) tpl = db.loadWorkout(choice.substring(4));
  final saved = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
        builder: (_) => GymWorkoutScreen(template: tpl, resume: choice == 'resume')),
  );
  return saved == true;
}

/// Logs a gym workout like Hevy: exercises with sets of weight and
/// repetitions, the previous values next to each set, a rest timer, and a
/// summary with new records at the end. Also edits a saved workout.
class GymWorkoutScreen extends StatefulWidget {
  final Workout? editing;
  final Workout? template;
  final bool resume;
  const GymWorkoutScreen({super.key, this.editing, this.template, this.resume = false});

  @override
  State<GymWorkoutScreen> createState() => _GymWorkoutScreenState();
}

class _GymWorkoutScreenState extends State<GymWorkoutScreen> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final List<_GEx> _ex = [];
  final List<_GSet> _graveyard = []; // removed sets, disposed at the end
  late DateTime _start;
  final ValueNotifier<int> _elapsed = ValueNotifier(0);
  final ValueNotifier<int> _rest = ValueNotifier(0); // seconds left
  int _restSeconds = 90;
  Timer? _timer;
  Timer? _saveTimer;
  bool _finished = false;
  Map<String, List<LiftSession>> _history = {};

  bool get _editing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _history = allLiftSessions(AppDb.instance.loadAllWorkouts(withEx: true));
    if (_editing) {
      final w = widget.editing!;
      _history.forEach((k, v) => v.removeWhere((s) => s.w.id == w.id));
      _start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      _title.text = w.title;
      final noteLine = w.notes.split('\n').where((l) => l.startsWith('Note: ')).toList();
      if (noteLine.isNotEmpty) _notes.text = noteLine.first.substring(6);
      for (final ex in w.exercises) {
        _ex.add(_fromMap(ex, done: true));
      }
    } else {
      var restored = false;
      if (widget.resume) restored = _restoreDraft();
      if (!restored) {
        _start = DateTime.now();
        final t = widget.template;
        if (t != null) {
          _title.text = t.title;
          for (final ex in t.exercises) {
            _ex.add(_fromMap(ex, done: false));
          }
        }
      }
      _elapsed.value = DateTime.now().difference(_start).inSeconds;
      _timer = Timer.periodic(const Duration(seconds: 1), _tick);
      _scheduleSave();
    }
  }

  @override
  void dispose() {
    if (!_editing && !_finished && _ex.isNotEmpty) {
      AppDb.instance.setSetting('gym_draft', jsonEncode(_toDraft()));
    }
    _timer?.cancel();
    _saveTimer?.cancel();
    _title.dispose();
    _notes.dispose();
    for (final e in _ex) {
      for (final s in e.sets) {
        s.dispose();
      }
    }
    for (final s in _graveyard) {
      s.dispose();
    }
    _elapsed.dispose();
    _rest.dispose();
    super.dispose();
  }

  void _tick(Timer t) {
    _elapsed.value = DateTime.now().difference(_start).inSeconds;
    if (_rest.value > 0) {
      _rest.value--;
      if (_rest.value == 0) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      }
    }
  }

  _GEx _fromMap(Map<String, dynamic> ex, {required bool done}) {
    final sets = <_GSet>[];
    for (final s in ((ex['sets'] as List?) ?? const [])) {
      final m = (s as Map).cast<String, dynamic>();
      final kg = (m['kg'] as num?)?.toDouble() ?? 0;
      final reps = (m['reps'] as num?)?.toDouble();
      sets.add(_GSet(
        type: (m['type'] ?? 'normal').toString(),
        kg: kg > 0 ? rawNum(kg) : '',
        reps: reps == null ? '' : rawNum(reps),
        done: done,
      ));
    }
    if (sets.isEmpty) sets.add(_GSet());
    return _GEx((ex['name'] ?? '').toString(), sets);
  }

  // ---------- the draft (survives closing the app) ----------

  Map<String, dynamic> _toDraft() => {
        'start': _start.millisecondsSinceEpoch,
        'title': _title.text,
        'notes': _notes.text,
        'ex': [
          for (final e in _ex)
            {
              'name': e.name,
              'sets': [
                for (final s in e.sets)
                  {'t': s.type, 'kg': s.kg.text, 'reps': s.reps.text, 'done': s.done}
              ],
            }
        ],
      };

  void _scheduleSave() {
    if (_editing) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      AppDb.instance.setSetting('gym_draft', jsonEncode(_toDraft()));
    });
  }

  bool _restoreDraft() {
    try {
      final d = jsonDecode(AppDb.instance.getSetting('gym_draft') ?? '') as Map;
      _start = DateTime.fromMillisecondsSinceEpoch((d['start'] as num).toInt());
      _title.text = (d['title'] ?? '').toString();
      _notes.text = (d['notes'] ?? '').toString();
      for (final e in (d['ex'] as List)) {
        final m = (e as Map).cast<String, dynamic>();
        final sets = <_GSet>[
          for (final s in (m['sets'] as List))
            _GSet(
              type: ((s as Map)['t'] ?? 'normal').toString(),
              kg: (s['kg'] ?? '').toString(),
              reps: (s['reps'] ?? '').toString(),
              done: s['done'] == true,
            )
        ];
        _ex.add(_GEx((m['name'] ?? '').toString(), sets.isEmpty ? [_GSet()] : sets));
      }
      return true;
    } catch (_) {
      _ex.clear();
      return false;
    }
  }

  void _clearDraft() => AppDb.instance.setSetting('gym_draft', '');

  // ---------- helpers ----------

  void _snack(String msg) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// The same set number in your last session of this exercise.
  LiftSet? _prevSet(_GEx e, int workingIndex) {
    final hist = _history[e.name.trim().toLowerCase()];
    if (hist == null || hist.isEmpty) return null;
    final sets = hist.last.sets;
    return workingIndex < sets.length ? sets[workingIndex] : null;
  }

  String _prevText(_GEx e, LiftSet s) {
    final hist = _history[e.name.trim().toLowerCase()]!;
    return hist.last.setText(s);
  }

  void _toggleDone(_GEx e, _GSet s, int workingIndex, bool v) {
    if (v) {
      final prev = s.type == 'warmup' ? null : _prevSet(e, workingIndex);
      if (s.reps.text.trim().isEmpty && prev != null) {
        s.reps.text = rawNum(prev.reps);
        if (s.kg.text.trim().isEmpty && prev.kg > 0) s.kg.text = rawNum(prev.kg);
      }
      if ((parseNum(s.reps.text) ?? 0) <= 0) {
        _snack('Enter the repetitions first.');
        return;
      }
      if (!_editing) _rest.value = _restSeconds;
    }
    setState(() => s.done = v);
    _scheduleSave();
  }

  Future<void> _addExercise() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ExercisePicker(history: _history),
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() => _ex.add(_GEx(name.trim(), [_GSet()])));
    _scheduleSave();
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_editing ? 'Leave without saving?' : 'Discard this workout?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_editing ? 'Leave' : 'Discard')),
        ],
      ),
    );
    if (ok != true) return;
    _finished = true;
    if (!_editing) _clearDraft();
    if (mounted) Navigator.pop(context, false);
  }

  List<String> _records(List<Map<String, dynamic>> exs) {
    final out = <String>[];
    for (final ex in exs) {
      final name = ex['name'] as String;
      final hist = _history[name.toLowerCase()] ?? [];
      if (hist.isEmpty) continue;
      var best1 = 0.0, bestKg = 0.0;
      for (final s in hist) {
        final e = s.best1rm;
        if (e != null && e > best1) best1 = e;
        if (s.maxKg > bestKg) bestKg = s.maxKg;
      }
      var new1 = 0.0, newKg = 0.0;
      var newSet = '';
      for (final s in (ex['sets'] as List)) {
        final m = (s as Map).cast<String, dynamic>();
        if (m['type'] == 'warmup') continue;
        final kg = (m['kg'] as num).toDouble();
        final reps = (m['reps'] as num).toDouble();
        final e = e1rm(kg, reps);
        if (e != null && e > new1) {
          new1 = e;
          newSet = '${rawNum(kg)} x ${reps.round()}';
        }
        if (kg > newKg) newKg = kg;
      }
      if (best1 > 0 && new1 > best1) {
        out.add('$name: new best estimated 1RM, ${fmt(new1)} kg ($newSet)');
      } else if (bestKg > 0 && newKg > bestKg) {
        out.add('$name: new heaviest weight, ${fmt(newKg)} kg');
      }
    }
    return out;
  }

  Future<void> _finish() async {
    final exs = <Map<String, dynamic>>[];
    for (final e in _ex) {
      final sets = <Map<String, dynamic>>[];
      for (final s in e.sets) {
        if (!s.done) continue;
        final reps = parseNum(s.reps.text) ?? 0;
        if (reps <= 0) continue;
        sets.add({'type': s.type, 'kg': parseNum(s.kg.text) ?? 0.0, 'reps': reps});
      }
      if (sets.isNotEmpty) exs.add({'name': e.name.trim(), 'sets': sets});
    }
    if (exs.isEmpty) {
      _snack('Tick the sets you completed first.');
      return;
    }
    var end = _editing
        ? DateTime.fromMillisecondsSinceEpoch(widget.editing!.endMs)
        : DateTime.now();
    if (!end.isAfter(_start)) end = _start.add(const Duration(minutes: 1));
    final metrics = strengthMetrics(exs);
    final userNote = _notes.text.trim();
    final notes = [strengthNotes(exs), if (userNote.isNotEmpty) 'Note: $userNote'].join('\n');
    final title = _title.text.trim().isEmpty ? 'Gym workout' : _title.text.trim();
    final prs = _records(exs);

    final Workout w = _editing
        ? widget.editing!.copyWith(
            title: title,
            notes: notes,
            metrics: {...widget.editing!.metrics, ...metrics},
            exercises: exs,
            source: 'manual',
          )
        : Workout(
            id: newId(),
            day: dayKey(_start),
            startMs: _start.millisecondsSinceEpoch,
            endMs: end.millisecondsSinceEpoch,
            type: 'STRENGTH_TRAINING',
            title: title,
            source: 'app',
            notes: notes,
            metrics: metrics,
            exercises: exs,
          );
    AppDb.instance.saveWorkout(w);
    _finished = true;
    _timer?.cancel();
    _saveTimer?.cancel();
    if (!_editing) _clearDraft();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_editing ? 'Workout updated' : 'Workout saved'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${fmtDur(w.minutes)}, ${metrics['sets']!.round()} sets, '
                '${fmt(metrics['volume_kg']!)} kg volume'),
            if (prs.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('New records', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final p in prs) Text(p),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    if (mounted) Navigator.pop(context, true);
  }

  // ---------- display ----------

  Widget _numBox(TextEditingController c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextField(
          controller: c,
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          ),
          onChanged: (_) => _scheduleSave(),
        ),
      );

  Widget _setRow(_GEx e, int j) {
    final s = e.sets[j];
    final workingIndex = e.sets.take(j).where((x) => x.type != 'warmup').length;
    final label = switch (s.type) {
      'warmup' => 'W',
      'dropset' => 'D',
      'failure' => 'F',
      _ => '${workingIndex + 1}',
    };
    final prev = s.type == 'warmup' ? null : _prevSet(e, workingIndex);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: PopupMenuButton<String>(
              tooltip: 'Set type',
              onSelected: (v) {
                setState(() {
                  if (v == 'delete') {
                    _graveyard.add(e.sets.removeAt(j));
                  } else {
                    s.type = v;
                  }
                });
                _scheduleSave();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'normal', child: Text('Normal set')),
                PopupMenuItem(value: 'warmup', child: Text('Warm-up set')),
                PopupMenuItem(value: 'dropset', child: Text('Drop set')),
                PopupMenuItem(value: 'failure', child: Text('Failure set')),
                PopupMenuItem(value: 'delete', child: Text('Delete this set')),
              ],
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          SizedBox(
            width: 84,
            child: InkWell(
              onTap: prev == null
                  ? null
                  : () {
                      setState(() {
                        s.kg.text = prev.kg > 0 ? rawNum(prev.kg) : '';
                        s.reps.text = rawNum(prev.reps);
                      });
                      _scheduleSave();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(prev == null ? '-' : _prevText(e, prev),
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
          Expanded(child: _numBox(s.kg)),
          Expanded(child: _numBox(s.reps)),
          SizedBox(
            width: 48,
            child: Checkbox(
              value: s.done,
              onChanged: (v) => _toggleDone(e, s, workingIndex, v ?? false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _exerciseCard(int i) {
    final e = _ex[i];
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(e.name,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'remove') {
                      setState(() {
                        _graveyard.addAll(_ex.removeAt(i).sets);
                      });
                      _scheduleSave();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'remove', child: Text('Remove exercise')),
                  ],
                ),
              ],
            ),
            const Row(
              children: [
                SizedBox(width: 40, child: Center(child: Text('SET', style: head))),
                SizedBox(width: 84, child: Center(child: Text('PREVIOUS', style: head))),
                Expanded(child: Center(child: Text('KG', style: head))),
                Expanded(child: Center(child: Text('REPS', style: head))),
                SizedBox(width: 48),
              ],
            ),
            for (var j = 0; j < e.sets.length; j++) _setRow(e, j),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  final last = e.sets.isEmpty ? null : e.sets.last;
                  e.sets.add(_GSet(
                    kg: last?.kg.text ?? '',
                    reps: last?.reps.text ?? '',
                  ));
                });
                _scheduleSave();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add set'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: _editing ? 'Leave' : 'Discard',
          onPressed: _discard,
        ),
        title: _editing
            ? const Text('Edit workout')
            : ValueListenableBuilder<int>(
                valueListenable: _elapsed,
                builder: (context, s, _) => Text('Workout  ${_hhmmss(s)}'),
              ),
        actions: [
          TextButton(
            onPressed: _finish,
            child: Text(_editing ? 'Save' : 'Finish'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Workout name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _scheduleSave(),
          ),
          const SizedBox(height: 8),
          if (!_editing)
            ValueListenableBuilder<int>(
              valueListenable: _rest,
              builder: (context, left, _) => left <= 0
                  ? const SizedBox.shrink()
                  : Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.timer_outlined),
                            const SizedBox(width: 8),
                            Text('Rest  ${_mmss(left)}',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            const Spacer(),
                            TextButton(
                                onPressed: () => _rest.value = left > 15 ? left - 15 : 1,
                                child: const Text('-15 s')),
                            TextButton(
                                onPressed: () => _rest.value = left + 15,
                                child: const Text('+15 s')),
                            IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Skip',
                                onPressed: () => _rest.value = 0),
                          ],
                        ),
                      ),
                    ),
            ),
          for (var i = 0; i < _ex.length; i++) _exerciseCard(i),
          FilledButton.icon(
            onPressed: _addExercise,
            icon: const Icon(Icons.add),
            label: const Text('Add exercise'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _scheduleSave(),
          ),
          if (!_editing)
            Row(
              children: [
                const Text('Rest timer after each set:  '),
                DropdownButton<int>(
                  value: _restSeconds,
                  items: [
                    for (final s in [30, 60, 90, 120, 150, 180, 240, 300])
                      DropdownMenuItem(value: s, child: Text(_mmss(s))),
                  ],
                  onChanged: (v) => setState(() => _restSeconds = v ?? _restSeconds),
                ),
              ],
            ),
          const SizedBox(height: 16),
          if (!_editing)
            OutlinedButton(
              onPressed: _discard,
              child: const Text('Discard workout'),
            ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

/// Bottom sheet with a search box: your own exercises first, then common ones.
class _ExercisePicker extends StatefulWidget {
  final Map<String, List<LiftSession>> history;
  const _ExercisePicker({required this.history});

  @override
  State<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends State<_ExercisePicker> {
  String _q = '';
  late final List<String> _names;

  @override
  void initState() {
    super.initState();
    final lists = widget.history.values.where((l) => l.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final names = [for (final l in lists) l.first.name];
    final lower = names.map((n) => n.toLowerCase()).toSet();
    for (final b in builtinExercises) {
      if (!lower.contains(b.toLowerCase())) names.add(b);
    }
    _names = names;
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final shown = [
      for (final n in _names)
        if (words.every((w) => n.toLowerCase().contains(w))) n
    ];
    final exact = _names.any((n) => n.toLowerCase() == q);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search or type a new exercise',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _q = v),
                onSubmitted: (v) {
                  if (shown.isNotEmpty) {
                    Navigator.pop(context, shown.first);
                  } else if (v.trim().isNotEmpty) {
                    Navigator.pop(context, v.trim());
                  }
                },
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (q.isNotEmpty && !exact)
                    ListTile(
                      leading: const Icon(Icons.add_circle_outline),
                      title: Text('Create "${_q.trim()}"'),
                      onTap: () => Navigator.pop(context, _q.trim()),
                    ),
                  for (final n in shown.take(80))
                    ListTile(title: Text(n), onTap: () => Navigator.pop(context, n)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
