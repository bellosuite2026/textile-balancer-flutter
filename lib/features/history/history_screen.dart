/// Historique des calculs de l'atelier (cet appareil + serveur).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../results/result_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    if (s.cloudAvailable) s.pullCloud();
  }

  Future<void> _openCloud(String id) async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().openCloudRun(id);
      if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(runId: r.id)));
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final runs = s.runs;
    return PageScaffold(
      title: 'Historique',
      subtitle: 'Tous les calculs de l\'atelier, du plus récent au plus ancien.',
      actions: [
        if (s.isCloud)
          IconButton(onPressed: s.cloudAvailable ? () => s.pullCloud() : null, icon: const Icon(Icons.refresh), tooltip: 'Actualiser'),
      ],
      children: [
        if (_busy) const LinearProgressIndicator(),
        SectionCard(
          title: 'Calculs enregistrés sur cet appareil',
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: runs.isEmpty
              ? const EmptyState(icon: Icons.history, text: 'Aucun calcul pour l\'instant.')
              : ScrollTable(
                  columns: const [
                    DataColumn(label: Text('Date')),
                    DataColumn(label: Text('Gamme')),
                    DataColumn(label: Text('Objectif')),
                    DataColumn(label: Text('Méthode')),
                    DataColumn(label: Text('Statut')),
                    DataColumn(label: Text('Stations'), numeric: true),
                    DataColumn(label: Text('Cycle réel'), numeric: true),
                    DataColumn(label: Text('Rendement'), numeric: true),
                    DataColumn(label: Text('Où')),
                  ],
                  rows: [
                    for (final r in runs)
                      DataRow(
                        onSelectChanged: (_) =>
                            Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(runId: r.id))),
                        cells: [
                          DataCell(Text(fmtDate(r.createdAt))),
                          DataCell(Text(r.problem.name)),
                          DataCell(Text(r.kind == 'min_cycle' ? 'Cadence min.' : 'Cadence ${fmtNum(r.problem.targetCycleTime, 3)}')),
                          DataCell(Text(solverLabels[r.solver] ?? r.solver)),
                          DataCell(StatusBadge.forRun(status: r.status, result: r.balance, found: r.minCycle?.found ?? true)),
                          DataCell(Text(r.balance == null ? '—' : '${r.balance!.stationsUsed}')),
                          DataCell(Text(r.balance == null ? '—' : fmtNum(r.balance!.actualCycleTime, 3))),
                          DataCell(Text(r.balance == null ? '—' : fmtPct(r.balance!.efficiency))),
                          DataCell(Icon(
                            r.source == 'local'
                                ? (r.pushState == 'pending' ? Icons.cloud_upload_outlined : Icons.computer)
                                : Icons.cloud_outlined,
                            size: 18,
                            color: r.pushState == 'pending' ? Brand.warn : Brand.muted,
                          )),
                        ],
                      ),
                  ],
                ),
        ),
        if (s.isCloud)
          SectionCard(
            title: 'Autres calculs du serveur',
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: !s.online
                ? const Padding(padding: EdgeInsets.all(16), child: Notice('Hors ligne : historique serveur indisponible.'))
                : s.cloudRuns.isEmpty
                    ? const EmptyState(icon: Icons.cloud_done_outlined, text: 'Rien de plus sur le serveur.')
                    : ScrollTable(
                        columns: const [
                          DataColumn(label: Text('Date')),
                          DataColumn(label: Text('Objectif')),
                          DataColumn(label: Text('Méthode')),
                          DataColumn(label: Text('Statut')),
                          DataColumn(label: Text('Stations'), numeric: true),
                          DataColumn(label: Text('Rendement'), numeric: true),
                        ],
                        rows: [
                          for (final r in s.cloudRuns)
                            DataRow(
                              onSelectChanged: (_) => _openCloud(r['id'].toString()),
                              cells: [
                                DataCell(Text(fmtDate(DateTime.tryParse(r['created_at']?.toString() ?? '')))),
                                DataCell(Text(r['kind'] == 'min_cycle' ? 'Cadence min.' : 'Équilibrage')),
                                DataCell(Text(solverLabels[r['solver']] ?? '${r['solver']}')),
                                DataCell(Text(_cloudStatus(r))),
                                DataCell(Text('${r['stations_used'] ?? '—'}')),
                                DataCell(Text(r['efficiency'] == null ? '—' : fmtPct(r['efficiency'] as num))),
                              ],
                            ),
                        ],
                      ),
          ),
      ],
    );
  }

  String _cloudStatus(Map<String, dynamic> r) => switch (r['status']) {
        'queued' => 'En file',
        'running' => 'En cours',
        'failed' => 'Échec',
        _ => r['compliant'] == true ? 'Conforme' : (r['success'] == true ? 'À vérifier' : 'Non conforme'),
      };
}
