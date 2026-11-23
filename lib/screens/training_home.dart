import 'package:flutter/material.dart';
import '../widgets.dart';
import 'exercise_progress_screen.dart';
import 'fitness_view.dart';
import 'training_view.dart';
import 'workouts_screen.dart';

/// The training part of the app: overview and statistics, all workouts, and
/// the progress of each lift.
class TrainingHome extends StatelessWidget {
  const TrainingHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionTabs(
      title: 'Training',
      tabs: const ['Overview', 'Workouts', 'Lifts', 'Fitness'],
      pages: [
        (_) => ListView(
              padding: const EdgeInsets.all(12),
              children: const [TrainingView()],
            ),
        (_) => const WorkoutsScreen(embedded: true),
        (_) => const ExerciseListScreen(embedded: true),
        (_) => const FitnessView(),
      ],
    );
  }
}
