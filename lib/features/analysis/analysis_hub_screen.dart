/// Section « Analyse » : jumeau numérique, plan d'atelier, Process Flow, simulation détaillée,
/// optimiseur Pareto. Chaque outil s'ouvre sur un calcul terminé (choisi dans une liste).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/records.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../twin/twin_screen.dart';

class AnalysisTool {
  const AnalysisTool(this.key, this.title, this.text, this.icon, {this.online = false, this.needsRun = true});
  final String key;
  final String title;
  final String text;
  final IconData icon;
  final bool online;
  final bool needsRun;
}

const analysisTools = [
  AnalysisTool('twin', 'Jumeau numérique 2D', 'Ligne animée, encours, goulot, scénarios « et si », réel vs simulé.', Icons.view_in_ar_outlined),
];

Widget? toolScreen(String key, String runId) => switch (key) {
      'twin' => TwinScreen(runId: runId),
      _ => null,
    };

/// Boutons d'accès aux outils d'analyse depuis un résultat de calcul.
List<Widget> analysisButtons(BuildContext context, RunRecord r) {
  final s = context.read<AppState>();
  return [
    for (final t in analysisTools)
      if (t.needsRun)
        OutlinedButton.icon(
          key: Key('open-${t.key}'),
          onPressed: t.online && !(s.cloudAvailable && r.cloudId != null)
              ? null
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => toolScreen(t.key, r.id)!)),
          icon: Icon(t.icon),
          label: Text(t.title),
        ),
  ];
}

class AnalysisHubScreen extends StatelessWidget {
  const AnalysisHubScreen({super.key});

  Future<void> _open(BuildContext context, AnalysisTool t) async {
    final s = context.read<AppState>();
    if (!t.needsRun) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => toolScreen(t.key, '')!));
      return;
    }
    final runs = s.runs.where((r) => r.isDone && r.balance != null && r.balance!.stationDetails.isNotEmpty).toList();
    if (runs.isEmpty) {
      showSnack(context, 'Aucun calcul terminé : lancez d\'abord un calcul.', error: true);
      return;
    }
    final picked = await showModalBottomSheet<RunRecord>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('${t.title} — choisir un calcul', style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
            ),
            for (final r in runs)
              ListTile(
                enabled: !t.online || (s.cloudAvailable && r.cloudId != null),
                leading: Icon(r.source == 'cloud' || r.cloudId != null ? Icons.cloud_done_outlined : Icons.phone_android),
                title: Text(r.problem.name),
                subtitle: Text('${fmtDate(r.createdAt)} · ${r.balance!.stationsUsed} stations · '
                    'cadence ${fmtNum(r.balance!.actualCycleTime, 3)} min${t.online && r.cloudId == null ? ' · non synchronisé' : ''}'),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ]),
        ),
      ),
    );
    if (picked != null && context.mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => toolScreen(t.key, picked.id)!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return PageScaffold(
      title: 'Analyse',
      subtitle: 'Visualiser, simuler et optimiser une ligne équilibrée',
      children: [
        if (!s.cloudAvailable)
          const Notice('Hors ligne ou mode local : jumeau, plan d\'atelier et Process Flow fonctionnent sur l\'appareil ; '
              'la simulation détaillée et l\'optimiseur nécessitent le serveur (mode cloud, en ligne).'),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth < 560 ? 1 : (c.maxWidth < 900 ? 2 : 3);
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final t in analysisTools)
              SizedBox(
                width: w,
                child: Card(
                  child: InkWell(
                    key: Key('tool-${t.key}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _open(context, t),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(t.icon, color: Brand.navy, size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Brand.navy)),
                            const SizedBox(height: 4),
                            Text(t.text, style: const TextStyle(color: Brand.muted, fontSize: 13)),
                            if (t.online)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: StatusBadge(s.cloudAvailable ? 'Serveur' : 'En ligne uniquement',
                                    color: s.cloudAvailable ? Brand.ok : Brand.muted, icon: Icons.cloud_outlined),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        }),
      ],
    );
  }
}
