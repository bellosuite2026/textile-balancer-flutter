/// Résultat d'un calcul : statut, KPI, Yamazumi, répartition, points d'attention, exports.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/exporters.dart';
import '../../data/file_io.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../analysis/analysis_hub_screen.dart';
import '../production/session_form.dart';
import '../simulation/simulation_screen.dart';
import 'yamazumi_chart.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.runId});
  final String runId;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  RunRecord? _run;
  StreamSubscription<RunRecord>? _poll;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _run = context.read<AppState>().repo.run(widget.runId);
    _startPolling();
  }

  void _startPolling() {
    final r = _run;
    if (r == null || r.source != 'cloud' || r.cloudId == null) return;
    if (r.status != 'queued' && r.status != 'running') return;
    _poll = context.read<AppState>().pollCloudRun(r).listen(
          (u) => setState(() => _run = u),
          onError: (Object e) => setState(() => _error = e.toString()),
        );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _export(String kind) async {
    final r = _run!;
    final b = r.balance;
    if (b == null) return;
    final s = context.read<AppState>();
    final base = r.problem.name.replaceAll(RegExp(r'[^\w\-]+', unicode: true), '_');
    try {
      final (bytes, name, mime) = switch (kind) {
        'csv' => (resultCsv(b, r.problem), '${base}_equilibrage.csv', 'text/csv'),
        'xlsx' => (
            resultXlsx(b, r.problem),
            '${base}_equilibrage.xlsx',
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          ),
        _ => (await resultPdf(b, r.problem, workshop: s.workshop?.name ?? ''), '${base}_equilibrage.pdf', 'application/pdf'),
      };
      final msg = await saveBytes(name, bytes, mime: mime);
      if (msg != null && mounted) showSnack(context, msg);
    } catch (e) {
      if (mounted) showSnack(context, 'Export impossible : $e', error: true);
    }
  }

  Future<void> _serverExport(String ext) async {
    final r = _run!;
    final s = context.read<AppState>();
    try {
      final bytes = await s.api.runExport(s.workshop!.id, r.cloudId!, ext);
      final msg = await saveBytes('calcul_${r.cloudId!.substring(0, 8)}.$ext', bytes);
      if (msg != null && mounted) showSnack(context, msg);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _rerun({String? kind, String? solver}) async {
    final r = _run!;
    final s = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final p = r.problem.deepCopy();
      final RunRecord n = (solver ?? 'rpw') == 'rpw'
          ? await s.runLocal(p, kind: kind ?? 'balance', gammeId: r.gammeId)
          : await s.runCloud(p, kind: kind ?? 'balance', solver: solver!, gammeId: r.gammeId);
      if (mounted) {
        await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ResultScreen(runId: n.id)));
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
    final r = _run;
    if (r == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable.'));
    }
    final b = r.balance;
    final pending = r.status == 'queued' || r.status == 'running';
    final title = '${r.problem.name} · ${solverLabels[r.solver] ?? r.solver}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (b != null)
            PopupMenuButton<String>(
              tooltip: 'Exporter',
              icon: const Icon(Icons.download),
              onSelected: (v) => v.startsWith('srv_') ? _serverExport(v.substring(4)) : _export(v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'xlsx', child: Text('Excel (.xlsx)')),
                const PopupMenuItem(value: 'csv', child: Text('CSV (;)')),
                const PopupMenuItem(value: 'pdf', child: Text('PDF')),
                if (r.cloudId != null && s.cloudAvailable) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'srv_pdf', child: Text('Rapport PDF du serveur')),
                  const PopupMenuItem(value: 'srv_xlsx', child: Text('Excel du serveur')),
                  const PopupMenuItem(value: 'srv_json', child: Text('JSON du serveur')),
                ],
              ],
            ),
        ],
      ),
      body: PageScaffold(
        title: 'Résultat',
        subtitle: [
          fmtDate(r.createdAt),
          r.source == 'local' ? 'calculé sur cet appareil' : 'calculé sur le serveur',
          if (r.pushState == 'pending') 'copie cloud en attente',
        ].join(' · '),
        actions: [StatusBadge.forRun(status: r.status, result: b, found: r.minCycle?.found ?? true)],
        children: [
          if (_error != null) Notice(_error!, kind: 'error'),
          if (pending)
            Column(children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(r.status == 'queued' ? 'En file d\'attente sur le serveur…' : 'Calcul en cours sur le serveur…'),
            ]),
          if (r.status == 'failed') Notice('Échec du calcul : ${r.error}', kind: 'error'),
          if (r.kind == 'min_cycle' && r.isDone)
            Notice(
              r.minCycle?.found == true
                  ? 'Cadence minimale atteignable : ${fmtNum(r.minCycle!.minCycleTime, 3)} min/pièce '
                      '(${fmtNum(60 / r.minCycle!.minCycleTime!, 1)} pièces/h).'
                  : 'Aucune cadence réalisable trouvée avec ces données (postes ou compétences insuffisants ?).',
              kind: r.minCycle?.found == true ? 'ok' : 'warn',
            ),
          if (b != null) ..._resultBody(context, r, b, s),
        ],
      ),
    );
  }

  List<Widget> _resultBody(BuildContext context, RunRecord r, BalanceResult b, AppState s) {
    final nmin = theoreticalMinStations(r.problem.totalSam, b.targetCycleTime);
    final errors = b.violations.where((v) => v.isError).length;
    final bn = b.bottleneck;
    return [
      if (!b.success && b.errorMessage.isNotEmpty) Notice(b.errorMessage, kind: 'error'),
      if (b.success && !b.compliant)
        Notice('Solution trouvée, mais ${errors == 0 ? b.violations.length : errors} point(s) à corriger avant de l\'appliquer en atelier.',
            kind: 'warn'),
      KpiGrid(children: [
        KpiCard(label: 'Stations', value: '${b.stationsUsed}', sub: 'minimum théorique $nmin'),
        KpiCard(label: 'Opérateurs', value: '${b.operators}'),
        KpiCard(label: 'Cycle réel', value: fmtMin(b.actualCycleTime, 3), sub: 'cible ${fmtNum(b.targetCycleTime, 3)}'),
        KpiCard(
          label: 'Rendement ligne',
          value: fmtPct(b.efficiency),
          color: b.efficiency >= 85 ? Brand.ok : (b.efficiency >= 70 ? null : Brand.warn),
        ),
        KpiCard(
            label: 'Production',
            value: '${fmtNum(b.outputPerHour, 0)} pcs/h',
            sub: '${fmtNum(b.outputPerHour * 8, 0)} pcs / 8 h'),
        KpiCard(label: 'Perte d\'équilibrage', value: fmtPct(b.balanceDelay), sub: 'lissage ${fmtNum(b.smoothnessIndex, 2)}'),
      ]),
      SectionCard(
        title: 'Yamazumi — charge par station',
        trailing: bn == null
            ? null
            : Text('Goulot : station ${bn.station} (${fmtNum(bn.totalTime, 3)} min)',
                style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600)),
        child: YamazumiChart(result: b, problem: r.problem),
      ),
      SectionCard(
        title: 'Répartition',
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: ScrollTable(
          columns: const [
            DataColumn(label: Text('Station')),
            DataColumn(label: Text('Opérations')),
            DataColumn(label: Text('Temps (min)'), numeric: true),
            DataColumn(label: Text('Charge')),
            DataColumn(label: Text('Poste(s)')),
            DataColumn(label: Text('Ouvrier(s)')),
          ],
          rows: [
            for (final st in b.stationDetails)
              DataRow(
                color: st.loadPct > 100.01 ? WidgetStateProperty.all(Brand.danger.withValues(alpha: 0.05)) : null,
                cells: [
                  DataCell(Text('${st.station}${st.parallel > 1 ? ' ×${st.parallel}' : ''}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: bn?.station == st.station ? Brand.danger : null))),
                  DataCell(ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Text(st.operations
                        .map((o) => st.shares?[o] != null ? '$o (part ${fmtNum(st.shares![o], 2)} min)' : o)
                        .join(', ')),
                  )),
                  DataCell(Text(fmtNum(st.totalTime, 3))),
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: 70,
                      child: LinearProgressIndicator(
                        value: (st.loadPct / 100).clamp(0, 1),
                        minHeight: 8,
                        backgroundColor: const Color(0xFFEFF2F6),
                        color: st.loadPct > 100.01 ? Brand.danger : (st.loadPct >= 85 ? Brand.good : Brand.mid),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('${fmtNum(st.loadPct, 0)} %'),
                  ])),
                  DataCell(Text(st.allWorkstations.isNotEmpty
                      ? st.allWorkstations.join(', ')
                      : ((st.machineTypes?.isEmpty ?? true) ? 'manuel' : 'aucun'))),
                  DataCell(Text([
                    st.workers.isEmpty ? '—' : st.workers.join(', '),
                    if (st.workerTime != null && st.workers.isNotEmpty && (st.workerTime! - st.totalTime).abs() > 0.005)
                      '(${fmtNum(st.workerTime, 2)} min réels)',
                  ].join(' '))),
                ],
              ),
          ],
        ),
      ),
      if (b.violations.isNotEmpty || b.warnings.any((w) => w.startsWith('[')))
        SectionCard(
          title: 'Points d\'attention',
          child: IssueList(issues: [
            ...b.violations,
            ...precedenceViolations(r.problem, b.stationDetails),
            for (final w in b.warnings.where((w) => w.startsWith('[')))
              Issue(w.substring(1, w.indexOf(']')), 'warning', w.substring(w.indexOf(']') + 2)),
          ]),
        ),
      if (b.warnings.any((w) => !w.startsWith('[')))
        SectionCard(
          title: 'Notes du solveur',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final w in b.warnings.where((w) => !w.startsWith('[')))
              Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(w, style: const TextStyle(color: Brand.muted))),
            Text('Temps de calcul : ${fmtNum(b.solveTimeSeconds, 3)} s · ${statusLabels[b.status] ?? b.status}',
                style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        ),
      SectionCard(
        title: 'Actions',
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: () => showSessionForm(context, r),
            icon: const Icon(Icons.precision_manufacturing),
            label: const Text('Suivre en production'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SimulationScreen(runId: r.id))),
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Simulation rapide'),
          ),
          ...analysisButtons(context, r),
          if (r.kind == 'balance')
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _rerun(kind: 'min_cycle'),
              icon: const Icon(Icons.speed),
              label: const Text('Chercher la cadence minimale'),
            ),
          OutlinedButton.icon(
            onPressed: _busy || !s.cloudAvailable ? null : () => _rerun(solver: 'cp_sat'),
            icon: const Icon(Icons.auto_awesome),
            label: Text(s.cloudAvailable ? 'Optimiser avec CP-SAT' : 'CP-SAT (en ligne uniquement)'),
          ),
        ]),
      ),
    ];
  }
}
