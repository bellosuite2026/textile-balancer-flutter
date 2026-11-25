/// Tableau de bord de l'atelier.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../state/app_state.dart';
import '../../ui/shell.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../gamme/gamme_editor_screen.dart';
import '../gamme/sample.dart';
import '../results/result_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _example(BuildContext context) async {
    final s = context.read<AppState>();
    final p = await loadChemiseExample();
    final g = await s.saveGamme(s.newGamme(p));
    if (context.mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => GammeEditorScreen(gammeId: g.id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final nav = context.read<ShellNav>();
    final runs = s.runs;
    final done = runs.where((r) => r.isDone && r.balance != null).toList();
    final last = done.isEmpty ? null : done.first;
    final open = s.sessions.where((x) => x.isOpen).length;
    return PageScaffold(
      title: 'Tableau de bord',
      subtitle: s.workshop?.name,
      actions: [
        OutlinedButton.icon(onPressed: () => _example(context), icon: const Icon(Icons.checkroom), label: const Text('Exemple chemise')),
        FilledButton.icon(onPressed: () => nav.go(2), icon: const Icon(Icons.calculate), label: const Text('Nouveau calcul')),
      ],
      children: [
        if (s.isCloud && !s.online)
          const Notice(
              'Hors ligne : vous pouvez continuer (gammes, RPW, production). Les modifications seront envoyées au retour du réseau.',
              kind: 'warn'),
        KpiGrid(children: [
          KpiCard(label: 'Gammes', value: '${s.gammes.length + s.cloudGammes.length}', icon: Icons.list_alt),
          KpiCard(label: 'Calculs', value: '${runs.length + s.cloudRuns.length}', icon: Icons.calculate_outlined),
          KpiCard(label: 'Sessions ouvertes', value: '$open', icon: Icons.precision_manufacturing_outlined),
          KpiCard(
            label: 'Dernier rendement',
            value: last == null ? '—' : fmtPct(last.balance!.efficiency),
            sub: last == null ? null : '${last.balance!.stationsUsed} stations · ${solverLabels[last.solver] ?? last.solver}',
            icon: Icons.speed,
          ),
        ]),
        SectionCard(
          title: 'Derniers calculs',
          trailing: TextButton(onPressed: () => nav.go(3), child: const Text('Tout l\'historique')),
          child: runs.isEmpty
              ? EmptyState(
                  icon: Icons.calculate_outlined,
                  text: 'Aucun calcul pour l\'instant. Saisissez une gamme ou chargez l\'exemple chemise.',
                  action: FilledButton(onPressed: () => nav.go(1), child: const Text('Ouvrir les gammes')),
                )
              : Column(children: [
                  for (final r in runs.take(6))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(r.source == 'local' ? Icons.computer : Icons.cloud_outlined, color: Brand.muted),
                      title: Text(r.problem.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        fmtDate(r.createdAt),
                        solverLabels[r.solver] ?? r.solver,
                        if (r.balance != null) '${r.balance!.stationsUsed} st. · ${fmtPct(r.balance!.efficiency)}',
                      ].join(' · ')),
                      trailing: StatusBadge.forRun(status: r.status, result: r.balance, found: r.minCycle?.found ?? true),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(runId: r.id))),
                    ),
                ]),
        ),
        SectionCard(
          title: 'Démarrer',
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            _Action(Icons.edit_note, 'Saisir une gamme', 'Opérations, SAM, précédences, machines', () => nav.go(1)),
            _Action(Icons.calculate, 'Équilibrer', 'RPW hors ligne ou CP-SAT en ligne', () => nav.go(2)),
            _Action(Icons.tablet_android, 'Suivre la production', 'Saisie tablette heure par heure', () => nav.go(4)),
          ]),
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.title, this.sub, this.onTap);
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 260,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(14)),
          child: Row(children: [
            Icon(icon, color: Brand.navy),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(sub, style: const TextStyle(color: Brand.muted, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
}
