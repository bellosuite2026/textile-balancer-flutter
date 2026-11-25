/// Formulaire « Démarrer une session de production » depuis un calcul terminé.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/widgets.dart';
import 'production_entry_screen.dart';

Future<void> showSessionForm(BuildContext context, RunRecord run) async {
  final s = context.read<AppState>();
  if (!(s.workshop?.canWrite ?? true)) {
    showSnack(context, 'Votre rôle ne permet pas d\'ouvrir une session.', error: true);
    return;
  }
  final plan = s.repo.planFor(run);
  if (plan == null) {
    showSnack(context, 'Il faut un calcul d\'équilibrage terminé avec des stations.', error: true);
    return;
  }
  final model = TextEditingController(text: run.problem.name);
  final date = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final start = TextEditingController(text: '08:00');
  final hours = TextEditingController(text: '8');
  final target = TextEditingController(text: fmtNum(defaultTargetPerHour(plan) ?? 0, 1));
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Démarrer une session'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${plan['stations'].length} stations · ${plan['operators']} opérateurs · cycle ${fmtNum(plan['cycle_time'] as num?, 3)} min'),
            const SizedBox(height: 12),
            TextField(controller: model, decoration: const InputDecoration(labelText: 'Modèle')),
            const SizedBox(height: 10),
            TextField(controller: date, decoration: const InputDecoration(labelText: 'Date (AAAA-MM-JJ)')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: start, decoration: const InputDecoration(labelText: 'Début du poste (HH:MM)'))),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: hours,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Durée (heures)'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Objectif (pièces / heure)', helperText: 'Par défaut : 60 / cycle réel'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Démarrer')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date.text.trim()) ||
      !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(start.text.trim())) {
    showSnack(context, 'Date (AAAA-MM-JJ) ou heure (HH:MM) invalide.', error: true);
    return;
  }
  final session = await s.openSession(
    run,
    model: model.text.trim(),
    date: date.text.trim(),
    shiftStart: start.text.trim(),
    shiftHours: parseNum(hours.text) ?? 8,
    targetPerHour: parseNum(target.text),
  );
  if (context.mounted) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ProductionEntryScreen(sessionId: session.id)));
  }
}
