import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../analysis.dart';
import '../db.dart';
import '../gym_data.dart';
import '../nutrients.dart';
import '../routines.dart';
import '../workout_types.dart';
import 'lift_tools_screen.dart';

class _GSet {
  String type; // normal | warmup | dropset | failure
  final TextEditingController kg;
  final TextEditingController reps;
  final TextEditingController rpe; // effort 1-10, optional
  bool done;
  _GSet(
      {this.type = 'normal',
      String kg = '',
      String reps = '',
      String rpe = '',
      this.done = false})
      : kg = TextEditingController(text: kg),
        reps = TextEditingController(text: reps),
        rpe = TextEditingController(text: rpe);
  void dispose() {
    kg.dispose();
    reps.dispose();
    rpe.dispose();
  }
}

class _GEx {
  String name;
  final List<_GSet> sets;
  String? ss; // exercises with the same value are a superset
  String note = '';
  final Key key = UniqueKey(); // lets the list keep track of it while reordering
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
  final routines = db.loadItems('gym_template');
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
        for (final r in routines)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'routine:${r.id}'),
            child: Text('Routine: ${r.data['name']}'),
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
  String? routineId;
  if (choice.startsWith('tpl:')) tpl = db.loadWorkout(choice.substring(4));
  if (choice.startsWith('routine:')) {
    final id = choice.substring(8);
    final found = routines.where((x) => x.id == id).toList();
    if (found.isNotEmpty) {
      tpl = routineToWorkout(found.first);
      routineId = id;
    }
  }
  final saved = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
        builder: (_) => GymWorkoutScreen(
            template: tpl, resume: choice == 'resume', routineId: routineId)),
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

  /// Set when the workout was started from a saved routine.
  final String? routineId;
  const GymWorkoutScreen(
      {super.key, this.editing, this.template, this.resume = false, this.routineId});

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
  int _restSeconds = 90; // default rest, for exercises without their own
  Map<String, int> _restByEx = {}; // rest in seconds per exercise (lower-case name)
  static const _restChoices = [0, 30, 45, 60, 75, 90, 105, 120, 150, 180, 210, 240, 300, 360];
  static const _defaultChoices = [30, 60, 90, 120, 150, 180, 240, 300];
  Timer? _timer;
  Timer? _saveTimer;
  bool _finished = false;
  Map<String, List<LiftSession>> _history = {};

  bool get _editing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final savedDefault = int.tryParse(AppDb.instance.getSetting('gym_rest_default') ?? '');
    if (savedDefault != null && _defaultChoices.contains(savedDefault)) {
      _restSeconds = savedDefault;
    }
    try {
      final m = jsonDecode(AppDb.instance.getSetting('gym_rest') ?? '{}') as Map;
      _restByEx = {for (final e in m.entries) e.key as String: (e.value as num).toInt()};
    } catch (_) {
      _restByEx = {};
    }
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
      final rpe = (m['rpe'] as num?)?.toDouble();
      sets.add(_GSet(
        type: (m['type'] ?? 'normal').toString(),
        kg: kg > 0 ? rawNum(kg) : '',
        reps: reps == null ? '' : rawNum(reps),
        rpe: rpe == null ? '' : rawNum(rpe),
        done: done,
      ));
    }
    if (sets.isEmpty) sets.add(_GSet());
    return _GEx((ex['name'] ?? '').toString(), sets)
      ..ss = ex['ss']?.toString()
      ..note = (ex['note'] ?? '').toString();
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
              'ss': e.ss,
              'note': e.note,
              'sets': [
                for (final s in e.sets)
                  {'t': s.type, 'kg': s.kg.text, 'reps': s.reps.text, 'rpe': s.rpe.text, 'done': s.done}
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
              rpe: (s['rpe'] ?? '').toString(),
              done: s['done'] == true,
            )
        ];
        _ex.add(_GEx((m['name'] ?? '').toString(), sets.isEmpty ? [_GSet()] : sets)
          ..ss = m['ss']?.toString()
          ..note = (m['note'] ?? '').toString());
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

  int _restFor(_GEx e) => _restByEx[e.name.trim().toLowerCase()] ?? _restSeconds;

  /// Choose the rest time of one exercise. It is remembered for next time.
  Future<void> _pickRest(_GEx e) async {
    final key = e.name.trim().toLowerCase();
    final own = _restByEx[key];
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Rest timer: ${e.name}'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Saved for this exercise and used every time you log it.',
                style: TextStyle(fontSize: 12)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in _restChoices)
                  ChoiceChip(
                    label: Text(s == 0 ? 'Off' : _mmss(s)),
                    selected: own == s,
                    onSelected: (_) => Navigator.pop(context, s),
                  ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: Text('Use the default (${_mmss(_restSeconds)})'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    setState(() {
      if (choice < 0) {
        _restByEx.remove(key);
      } else {
        _restByEx[key] = choice;
      }
    });
    AppDb.instance.setSetting('gym_rest', jsonEncode(_restByEx));
  }

  /// Suggestion for working set number [workingIndex] of [e], from the same
  /// set in the last session (the last set if there were fewer).
  SetHint? _hint(_GEx e, int workingIndex) {
    if (_editing) return null;
    final hist = _history[e.name.trim().toLowerCase()];
    if (hist == null || hist.isEmpty) return null;
    final sets = hist.last.sets;
    if (sets.isEmpty) return null;
    final p = workingIndex < sets.length ? sets[workingIndex] : sets.last;
    return progressionHint(p.kg, p.reps, p.rpe);
  }

  /// Fills the empty weight and reps boxes of the open sets with the hints.
  void _useHints(_GEx e) {
    setState(() {
      var w = 0;
      for (final s in e.sets) {
        if (s.type == 'warmup') continue;
        final h = _hint(e, w);
        w++;
        if (h == null || s.done || s.type == 'dropset') continue;
        if (s.kg.text.trim().isEmpty && h.kg > 0) s.kg.text = rawNum(h.kg);
        if (s.reps.text.trim().isEmpty) s.reps.text = rawNum(h.reps);
      }
    });
    _scheduleSave();
  }

  Widget _hintLine(_GEx e) {
    final h = _hint(e, 0);
    if (h == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text('Hint: ${h.why}. The grey numbers are suggestions.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ),
          TextButton(onPressed: () => _useHints(e), child: const Text('Use hints')),
        ],
      ),
    );
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
      if (!_editing) {
        // In a superset the rest starts after the last exercise of the round.
        final group = e.ss == null ? [e] : _ex.where((x) => x.ss == e.ss).toList();
        if (identical(group.last, e)) {
          _rest.value = group.map(_restFor).reduce((a, b) => a > b ? a : b);
        } else {
          _rest.value = 0;
        }
      }
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
        final rpe = parseNum(s.rpe.text);
        sets.add({
          'type': s.type,
          'kg': parseNum(s.kg.text) ?? 0.0,
          'reps': reps,
          if (rpe != null && rpe >= 1 && rpe <= 10) 'rpe': rpe,
        });
      }
      if (sets.isNotEmpty) {
        exs.add({
          'name': e.name.trim(),
          'sets': sets,
          if (e.ss != null) 'ss': e.ss,
          if (e.note.trim().isNotEmpty) 'note': e.note.trim(),
        });
      }
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
            metrics: {...(Map<String, double>.from(widget.editing!.metrics)..remove('rpe')), ...metrics},
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
    if (!_editing && mounted) await _offerRoutineUpdate(exs);
    if (mounted) Navigator.pop(context, true);
  }

  /// After a workout that was started from a routine: use today's weights
  /// and reps the next time.
  Future<void> _offerRoutineUpdate(List<Map<String, dynamic>> done) async {
    final id = widget.routineId;
    if (id == null) return;
    final found = AppDb.instance.loadItems('gym_template').where((i) => i.id == id).toList();
    if (found.isEmpty) return;
    final r = found.first;
    final doneByName = {
      for (final e in routineExercises(done)) (e['name'] as String).toLowerCase(): e
    };
    final old = routineExercisesOf(r);
    final next = [
      for (final e in old) doneByName[(e['name'] ?? '').toString().toLowerCase()] ?? e
    ];
    if (jsonEncode(next) == jsonEncode(old)) return; // nothing changed
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update the routine?'),
        content: Text('Use the weights and reps of this workout in "${r.data['name']}" '
            'the next time you start it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep as is')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
        ],
      ),
    );
    if (yes != true) return;
    AppDb.instance.saveItem('gym_template', id, {...r.data, 'exercises': next});
  }

  // ---------- supersets, warm-ups, drop sets, notes ----------

  /// Dragging an exercise to a new place.
  void _reorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    setState(() {
      final e = _ex.removeAt(oldIndex);
      _ex.insert(newIndex, e);
    });
    _scheduleSave();
  }

  /// One place up (-1) or down (+1); also works when the list is long.
  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _ex.length) return;
    setState(() {
      final e = _ex.removeAt(i);
      _ex.insert(j, e);
    });
    _scheduleSave();
  }

  /// Puts exercise [i] and the next one in a superset.
  void _superset(int i) {
    if (i >= _ex.length - 1) return;
    setState(() {
      final a = _ex[i], b = _ex[i + 1];
      if (a.ss != null) {
        b.ss = a.ss;
      } else if (b.ss != null) {
        a.ss = b.ss;
      } else {
        final id = 's${DateTime.now().millisecondsSinceEpoch}';
        a.ss = id;
        b.ss = id;
      }
    });
    _scheduleSave();
  }

  void _leaveSuperset(_GEx e) {
    setState(() {
      final id = e.ss;
      e.ss = null;
      // a group of one is no group
      final rest = _ex.where((x) => x.ss == id).toList();
      if (id != null && rest.length == 1) rest.first.ss = null;
    });
    _scheduleSave();
  }

  void _addWarmups(_GEx e) {
    final base = _firstKg(e) ?? _hint(e, 0)?.kg ?? _prevSet(e, 0)?.kg;
    if (base == null || base <= 0) {
      _snack('Enter the working weight first.');
      return;
    }
    final w = warmupScheme(base);
    if (w.isEmpty) {
      _snack('${rawNum(base)} kg is light enough to start without a warm-up.');
      return;
    }
    setState(() {
      final firstWork = e.sets.indexWhere((s) => s.type != 'warmup');
      final at = firstWork < 0 ? e.sets.length : firstWork;
      e.sets.insertAll(at, [
        for (final x in w) _GSet(type: 'warmup', kg: rawNum(x.kg), reps: '${x.reps}')
      ]);
    });
    _scheduleSave();
  }

  /// A drop set: about 20 % lighter than the last set.
  void _addDropSet(_GEx e) {
    double? last;
    for (final s in e.sets) {
      final k = parseNum(s.kg.text);
      if (s.type != 'warmup' && k != null && k > 0) last = k;
    }
    var kg = '';
    if (last != null) {
      var d = ((last * 0.8) / 2.5).round() * 2.5;
      if (d >= last) d = last - 2.5;
      if (d > 0) kg = rawNum(d);
    }
    setState(() => e.sets.add(_GSet(type: 'dropset', kg: kg)));
    _scheduleSave();
  }

  Future<void> _editNote(_GEx e) async {
    final c = TextEditingController(text: e.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Note: ${e.name}'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Seat height, grip, tempo, how it felt...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => e.note = c.text.trim());
    _scheduleSave();
  }

  Future<void> _saveAsRoutine() async {
    final exs = <Map<String, dynamic>>[
      for (final e in _ex)
        {
          'name': e.name.trim(),
          if (e.ss != null) 'ss': e.ss,
          'note': e.note,
          'sets': <Map<String, dynamic>>[
            for (final s in e.sets)
              {
                'type': s.type,
                'kg': parseNum(s.kg.text) ?? 0.0,
                'reps': parseNum(s.reps.text) ?? 0.0,
              }
          ],
        }
    ];
    final id = await saveRoutineDialog(context, suggestedName: _title.text.trim(), exercises: exs);
    if (id != null) _snack('Routine saved.');
  }

  /// The weight of the first set that has one (for the plate calculator).
  double? _firstKg(_GEx e) {
    for (final s in e.sets) {
      final k = parseNum(s.kg.text);
      if (k != null && k > 0) return k;
    }
    return null;
  }

  /// The set with the highest estimated 1RM (for the 1RM calculator).
  LiftSet? _bestSet(_GEx e) {
    LiftSet? best;
    double? bestV;
    for (final s in e.sets) {
      final kg = parseNum(s.kg.text) ?? 0, reps = parseNum(s.reps.text) ?? 0;
      final v = e1rm(kg, reps);
      if (v != null && (bestV == null || v > bestV)) {
        best = LiftSet(kg, reps);
        bestV = v;
      }
    }
    return best;
  }

  Widget _e1rmLine(_GEx e) {
    double? today;
    for (final s in e.sets) {
      if (!s.done || s.type == 'warmup') continue;
      final v = e1rm(parseNum(s.kg.text) ?? 0, parseNum(s.reps.text) ?? 0);
      if (v != null && (today == null || v > today)) today = v;
    }
    double? before;
    for (final sess in (_history[e.name.trim().toLowerCase()] ?? const <LiftSession>[])) {
      for (final s in sess.sets) {
        final v = e1rm(s.kg, s.reps);
        if (v != null && (before == null || v > before)) before = v;
      }
    }
    if (today == null && before == null) return const SizedBox.shrink();
    final up = today != null && before != null && today > before + 0.05;
    final text = [
      if (today != null) 'Est. 1RM today ${fmt(today)} kg',
      if (before != null) 'best before ${fmt(before)} kg',
    ].join('  |  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(up ? '$text  (new best)' : text,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
              fontWeight: up ? FontWeight.w700 : FontWeight.normal)),
    );
  }

  // ---------- display ----------

  Widget _numBox(TextEditingController c, {String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextField(
          controller: c,
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
    final hint = (s.type == 'warmup' || s.type == 'dropset') ? null : _hint(e, workingIndex);
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
          Expanded(
              child: _numBox(s.kg,
                  hint: (hint != null && hint.kg > 0) ? rawNum(hint.kg) : null)),
          Expanded(child: _numBox(s.reps, hint: hint == null ? null : rawNum(hint.reps))),
          SizedBox(width: 56, child: _numBox(s.rpe)),
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
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Tooltip(message: 'Drag to reorder', child: Icon(Icons.drag_handle)),
                  ),
                ),
                Expanded(
                  child: Text(e.name,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                TextButton.icon(
                  onPressed: () => _pickRest(e),
                  icon: const Icon(Icons.timer_outlined, size: 18),
                  label: Text(_restFor(e) == 0 ? 'Off' : _mmss(_restFor(e)),
                      style: TextStyle(
                          fontWeight: _restByEx.containsKey(e.name.trim().toLowerCase())
                              ? FontWeight.w700
                              : FontWeight.normal)),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'plates') showPlateCalculator(context, kg: _firstKg(e));
                    if (v == 'onerm') {
                      final b = _bestSet(e);
                      showOneRmCalculator(context, kg: b?.kg, reps: b?.reps);
                    }
                    if (v == 'moveup') _move(i, -1);
                    if (v == 'movedown') _move(i, 1);
                    if (v == 'superset') _superset(i);
                    if (v == 'unsuperset') _leaveSuperset(e);
                    if (v == 'warmups') _addWarmups(e);
                    if (v == 'drop') _addDropSet(e);
                    if (v == 'note') _editNote(e);
                    if (v == 'remove') {
                      setState(() {
                        _graveyard.addAll(_ex.removeAt(i).sets);
                      });
                      _scheduleSave();
                    }
                  },
                  itemBuilder: (_) => [
                    if (i > 0) const PopupMenuItem(value: 'moveup', child: Text('Move up')),
                    if (i < _ex.length - 1)
                      const PopupMenuItem(value: 'movedown', child: Text('Move down')),
                    const PopupMenuItem(value: 'warmups', child: Text('Add warm-up sets')),
                    const PopupMenuItem(value: 'drop', child: Text('Add a drop set')),
                    if (e.ss == null && i < _ex.length - 1)
                      const PopupMenuItem(
                          value: 'superset', child: Text('Superset with the next exercise')),
                    if (e.ss != null && i < _ex.length - 1 && _ex[i + 1].ss != e.ss)
                      const PopupMenuItem(
                          value: 'superset', child: Text('Add the next exercise to the superset')),
                    if (e.ss != null)
                      const PopupMenuItem(
                          value: 'unsuperset', child: Text('Remove from the superset')),
                    PopupMenuItem(
                        value: 'note',
                        child: Text(e.note.isEmpty ? 'Add a note' : 'Edit the note')),
                    const PopupMenuItem(value: 'plates', child: Text('Plate calculator')),
                    const PopupMenuItem(value: 'onerm', child: Text('1RM calculator')),
                    const PopupMenuItem(value: 'remove', child: Text('Remove exercise')),
                  ],
                ),
              ],
            ),
            if (e.ss != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Superset with ${_ex.where((x) => x.ss == e.ss && !identical(x, e)).map((x) => x.name).join(', ')}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
            if (e.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(e.note,
                    style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
              ),
            _hintLine(e),
            _e1rmLine(e),
            const Row(
              children: [
                SizedBox(width: 40, child: Center(child: Text('SET', style: head))),
                SizedBox(width: 84, child: Center(child: Text('PREVIOUS', style: head))),
                Expanded(child: Center(child: Text('KG', style: head))),
                Expanded(child: Center(child: Text('REPS', style: head))),
                SizedBox(width: 56, child: Center(child: Text('RPE', style: head))),
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
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'routine') _saveAsRoutine();
              if (v == 'plates') showPlateCalculator(context);
              if (v == 'onerm') showOneRmCalculator(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'routine', child: Text('Save as routine...')),
              PopupMenuItem(value: 'plates', child: Text('Plate calculator')),
              PopupMenuItem(value: 'onerm', child: Text('1RM calculator')),
            ],
          ),
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
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorder: _reorder,
            children: [
              for (var i = 0; i < _ex.length; i++)
                KeyedSubtree(key: _ex[i].key, child: _exerciseCard(i)),
            ],
          ),
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
                const Flexible(
                    child: Text('Default rest (exercises without their own):  ')),
                DropdownButton<int>(
                  value: _restSeconds,
                  items: [
                    for (final s in _defaultChoices)
                      DropdownMenuItem(value: s, child: Text(_mmss(s))),
                  ],
                  onChanged: (v) {
                    setState(() => _restSeconds = v ?? _restSeconds);
                    AppDb.instance.setSetting('gym_rest_default', '$_restSeconds');
                  },
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
