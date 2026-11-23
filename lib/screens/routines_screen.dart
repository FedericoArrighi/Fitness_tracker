import 'package:flutter/material.dart';
import '../db.dart';
import '../routines.dart';
import 'gym_workout_screen.dart';

/// Starts a routine in the gym logger. Returns true if a workout was saved.
Future<bool> startRoutine(BuildContext context, UserItem r) async {
  if ((AppDb.instance.getSetting('gym_draft') ?? '').isNotEmpty) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start this routine?'),
        content: const Text(
            'A workout is in progress. Starting a routine replaces it. '
            '(To keep it, go back and resume it first.)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
  }
  final saved = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => GymWorkoutScreen(template: routineToWorkout(r), routineId: r.id),
    ),
  );
  return saved == true;
}

/// Your saved routines: start, rename or delete.
class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({super.key});

  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  List<UserItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() => _items = AppDb.instance.loadItems('gym_template'));

  Future<void> _rename(UserItem r) async {
    final c = TextEditingController(text: (r.data['name'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename routine'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final name = c.text.trim();
    if (ok != true || name.isEmpty) return;
    AppDb.instance.saveItem('gym_template', r.id, {...r.data, 'name': name});
    _load();
  }

  Future<void> _delete(UserItem r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this routine?'),
        content: Text('"${r.data['name']}" will be removed. Workouts you did with it stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    AppDb.instance.deleteItem(r.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Routines')),
      body: _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No routines yet.\n\nIn the gym logger, tap the menu at the top and choose '
                    '"Save as routine", or open a finished workout and tap the routine button.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final r in _items)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.playlist_play),
                      title: Text((r.data['name'] ?? '').toString()),
                      subtitle: Text(_summary(r)),
                      onTap: () async {
                        if (await startRoutine(context, r) && mounted) _load();
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'rename') _rename(r);
                          if (v == 'delete') _delete(r);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  String _summary(UserItem r) {
    final exs = routineExercisesOf(r);
    var sets = 0;
    for (final e in exs) {
      for (final s in ((e['sets'] as List?) ?? const [])) {
        if ((s as Map)['type'] != 'warmup') sets++;
      }
    }
    final names = exs.map((e) => e['name']).take(3).join(', ');
    return '${exs.length} exercises, $sets sets\n$names${exs.length > 3 ? ', ...' : ''}';
  }
}
