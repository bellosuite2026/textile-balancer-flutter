/// Production : sessions de l'atelier, démarrage depuis un calcul.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'production_dashboard_screen.dart';
import 'production_entry_screen.dart';
import 'session_form.dart';

class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    if (s.cloudAvailable) s.pullCloud();
  }

  Future<void> _start() async {
    final s = context.read<AppState>();
    final runs = s.runs.where((r) => r.isDone && (r.balance?.stationDetails.isNotEmpty ?? false)).toList();
    if (runs.isEmpty) {
      showSnack(context, 'Il faut d\'abord un calcul d\'équilibrage terminé.', error: true);
      return;
    }
    final run = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Choisir un calcul…'),
        children: [
          for (final r in runs.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, r.id),
              child: ListTile(
                title: Text(r.problem.name),
                subtitle: Text('${fmtDate(r.createdAt)} · ${r.balance!.stationsUsed} st. · ${fmtPct(r.balance!.efficiency)} · '
                    '${solverLabels[r.solver] ?? r.solver}'),
              ),
            ),
        ],
      ),
    );
    if (run == null || !mounted) return;
    await showSessionForm(context, s.repo.run(run)!);
  }

  Future<void> _openCloud(String id) async {
    setState(() => _busy = true);
    try {
      final sess = await context.read<AppState>().openCloudSession(id);
      if (mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ProductionDashboardScreen(sessionId: sess.id)));
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final sessions = s.sessions;
    return PageScaffold(
      title: 'Production',
      subtitle: 'Pilotez la ligne en direct : saisie sur tablette, tableau de bord heure par heure.',
      actions: [
        FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_arrow), label: const Text('Démarrer une session')),
      ],
      children: [
        if (_busy) const LinearProgressIndicator(),
        const Notice('La saisie fonctionne hors ligne : les saisies sont gardées sur l\'appareil et envoyées au retour du réseau.'),
        SectionCard(
          title: 'Sessions',
          child: sessions.isEmpty
              ? const EmptyState(icon: Icons.precision_manufacturing_outlined, text: 'Aucune session. Démarrez-en une depuis un calcul terminé.')
              : Column(children: [
                  for (final x in sessions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(x.isOpen ? Icons.play_circle : Icons.lock_outline, color: x.isOpen ? Brand.ok : Brand.muted),
                      title: Text('${x.model} · ${x.sessionDate}'),
                      subtitle: Text([
                        'poste ${x.shiftStart} · ${fmtNum(x.shiftHours, 1)} h',
                        'objectif ${fmtNum(x.targetPerHour, 1)} pcs/h',
                        x.isOpen ? 'Ouverte' : 'Fermée',
                        if (s.workshop?.isCloud == true) x.cloudId == null ? 'envoi en attente' : 'synchronisée',
                      ].join(' · ')),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(
                          tooltip: 'Saisie tablette',
                          icon: const Icon(Icons.tablet_android),
                          onPressed: () => Navigator.push(
                              context, MaterialPageRoute(builder: (_) => ProductionEntryScreen(sessionId: x.id))),
                        ),
                        IconButton(
                          tooltip: 'Tableau de bord',
                          icon: const Icon(Icons.insights),
                          onPressed: () => Navigator.push(
                              context, MaterialPageRoute(builder: (_) => ProductionDashboardScreen(sessionId: x.id))),
                        ),
                      ]),
                    ),
                ]),
        ),
        if (s.isCloud && s.cloudSessions.isNotEmpty)
          SectionCard(
            title: 'Autres sessions du serveur',
            child: Column(children: [
              for (final r in s.cloudSessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_outlined, color: Brand.muted),
                  title: Text('${r['model'] ?? ''} · ${r['session_date'] ?? ''}'),
                  subtitle: Text('${r['line_name'] ?? ''} · objectif ${r['target_per_hour'] ?? '—'} pcs/h · '
                      '${r['status'] == 'open' ? 'Ouverte' : 'Fermée'}'),
                  trailing: const Icon(Icons.download_outlined),
                  onTap: () => _openCloud(r['id'].toString()),
                ),
            ]),
          ),
      ],
    );
  }
}
