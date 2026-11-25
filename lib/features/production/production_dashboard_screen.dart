/// Tableau de bord de production (calculé sur l'appareil à partir des saisies,
/// mêmes définitions que l'API) : objectif à date, alerte < 80 %, efficience,
/// goulot observé / calculé, encours, arrêts.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/file_io.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'production_entry_screen.dart';

class ProductionDashboardScreen extends StatefulWidget {
  const ProductionDashboardScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<ProductionDashboardScreen> createState() => _ProductionDashboardScreenState();
}

class _ProductionDashboardScreenState extends State<ProductionDashboardScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final sess = s.repo.session(widget.sessionId);
    if (sess != null) s.pullEntries(sess);
    _tick = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  void _refresh() {
    final s = context.read<AppState>();
    final sess = s.repo.session(widget.sessionId);
    if (sess != null) s.pullEntries(sess);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final sess = s.repo.session(widget.sessionId);
    if (sess == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, text: 'Session introuvable.'));
    final d = s.dashboardFor(sess);
    final alerts = (d['alerts'] as List).cast<Map>();
    final rows = (d['stations'] as List).cast<Map>();
    final hourly = (d['hourly'] as List).cast<Map>();
    final stops = (d['stops'] as List).cast<Map>();
    final reasons = (d['downtime_by_reason'] as List).cast<Map>().where((r) => (r['minutes'] as num) > 0).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Tableau de bord · ${sess.model}', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Saisie tablette',
            icon: const Icon(Icons.tablet_android),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ProductionEntryScreen(sessionId: sess.id))),
          ),
          if (sess.cloudId != null && s.cloudAvailable)
            PopupMenuButton<String>(
              icon: const Icon(Icons.download),
              tooltip: 'Rapport du serveur',
              onSelected: (ext) async {
                try {
                  final b = await s.api.sessionExport(s.workshop!.id, sess.cloudId!, ext);
                  final msg = await saveBytes('production_${sess.sessionDate}.$ext', b);
                  if (msg != null && context.mounted) showSnack(context, msg);
                } on ApiException catch (e) {
                  if (context.mounted) showSnack(context, e.message, error: true);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'xlsx', child: Text('Rapport Excel')),
                PopupMenuItem(value: 'pdf', child: Text('Rapport PDF')),
              ],
            ),
        ],
      ),
      body: PageScaffold(
        title: '${sess.model} · ${sess.sessionDate}',
        subtitle: 'Poste ${sess.shiftStart} · ${fmtNum(sess.shiftHours, 1)} h · objectif ${fmtNum(sess.targetPerHour, 1)} pcs/h',
        actions: [
          StatusBadge(sess.isOpen ? 'Ouverte' : 'Fermée', color: sess.isOpen ? Brand.ok : Brand.muted),
          OutlinedButton.icon(
            onPressed: !(s.workshop?.canWrite ?? true)
                ? null
                : () async {
                    if (sess.isOpen &&
                        !await confirm(context, 'Fermer la session',
                            'La saisie sera verrouillée et le tableau de bord figé à cette heure. Vous pourrez la rouvrir si besoin.',
                            ok: 'Fermer')) {
                      return;
                    }
                    await s.setSessionStatus(sess, sess.isOpen ? 'closed' : 'open');
                  },
            icon: Icon(sess.isOpen ? Icons.lock_outline : Icons.lock_open),
            label: Text(sess.isOpen ? 'Fermer la session' : 'Rouvrir'),
          ),
        ],
        children: [
          for (final a in alerts.take(6)) Notice(a['message'].toString(), kind: a['level'] == 'danger' ? 'error' : 'warn'),
          KpiGrid(children: [
            KpiCard(label: 'Réalisé (pièces finies)', value: '${d['output']}'),
            KpiCard(
              label: 'Objectif à date',
              value: fmtNum(d['expected_to_date'] as num?, 0),
              sub: d['pct_target'] == null ? null : '${fmtNum(d['pct_target'] as num, 0)} % de l\'objectif',
              color: (d['pct_target'] as num? ?? 100) < 80 ? Brand.danger : null,
            ),
            KpiCard(label: 'Objectif du poste', value: fmtNum(d['target_shift'] as num?, 0), sub: '${fmtNum(d['target_per_hour'] as num?, 1)} / h'),
            KpiCard(label: 'Efficience', value: fmtPct(d['efficiency'] as num?), sub: 'minutes produites / présence'),
            KpiCard(
              label: 'Goulot observé / calculé',
              value: '${d['bottleneck_observed'] ?? '—'} / ${d['bottleneck_planned'] ?? '—'}',
            ),
            KpiCard(label: 'Encours', value: '${d['wip_total']}', sub: 'pièces entre stations'),
            KpiCard(label: 'Arrêts cumulés', value: '${fmtNum(d['downtime_total'] as num?, 0)} min'),
            KpiCard(
              label: 'Défauts / retouches',
              value: '${d['defects']} / ${d['rework']}',
              sub: d['defect_rate'] == null ? null : 'taux ${fmtPct(d['defect_rate'] as num)}',
            ),
          ]),
          SectionCard(title: 'Réalisé et objectif par heure', child: _HourlyChart(hourly: hourly)),
          SectionCard(
            title: 'Par station',
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: ScrollTable(
              columns: const [
                DataColumn(label: Text('Station')),
                DataColumn(label: Text('Opérations')),
                DataColumn(label: Text('Ouvriers')),
                DataColumn(label: Text('Pièces'), numeric: true),
                DataColumn(label: Text('Objectif à date'), numeric: true),
                DataColumn(label: Text('% objectif'), numeric: true),
                DataColumn(label: Text('Efficience'), numeric: true),
                DataColumn(label: Text('Défauts / ret.')),
                DataColumn(label: Text('Arrêts (min)'), numeric: true),
                DataColumn(label: Text('Encours aval'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    color: (r['pct_target'] as num? ?? 100) < 80 ? WidgetStateProperty.all(Brand.danger.withValues(alpha: 0.05)) : null,
                    cells: [
                      DataCell(Text('${r['station']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      DataCell(Text((r['operations'] as List).join(', '))),
                      DataCell(Text((r['workers'] as List).join(', '))),
                      DataCell(Text('${r['pieces']}')),
                      DataCell(Text(fmtNum(r['expected'] as num?, 0))),
                      DataCell(Text(r['pct_target'] == null ? '—' : '${fmtNum(r['pct_target'] as num, 0)} %')),
                      DataCell(Text(fmtPct(r['efficiency'] as num?))),
                      DataCell(Text('${r['defects']} / ${r['rework']}')),
                      DataCell(Text(fmtNum(r['downtime_minutes'] as num?, 0))),
                      DataCell(Text(_wipAfter(d, r['station'] as int))),
                    ],
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Arrêts par motif',
            child: stops.isEmpty
                ? const Text('Aucun arrêt déclaré.', style: TextStyle(color: Brand.muted))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final r in reasons) Chip(label: Text('${r['label']} : ${fmtNum(r['minutes'] as num, 0)} min')),
                    ]),
                    const SizedBox(height: 8),
                    for (final x in stops)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(reasonIcons[x['reason']] ?? Icons.pause, color: x['ongoing'] == true ? Brand.orange : Brand.muted),
                        title: Text('Station ${x['station']} · ${x['label']}'),
                        subtitle: Text('${x['slot_hour']} h · ${fmtNum(x['minutes'] as num?, 0)} min${x['ongoing'] == true ? ' (en cours)' : ''}'
                            '${(x['comment'] ?? '').toString().isEmpty ? '' : ' · ${x['comment']}'}'),
                      ),
                  ]),
          ),
        ],
      ),
    );
  }

  String _wipAfter(Map<String, dynamic> d, int station) {
    for (final w in (d['wip'] as List).cast<Map>()) {
      if ((w['between'] as List).first == station) return '${w['pieces']}';
    }
    return '—';
  }
}

class _HourlyChart extends StatelessWidget {
  const _HourlyChart({required this.hourly});
  final List<Map> hourly;

  @override
  Widget build(BuildContext context) {
    if (hourly.isEmpty) return const SizedBox.shrink();
    final maxY = math.max(
      1.0,
      hourly.map((h) => math.max((h['target'] as num).toDouble(), (h['output'] as num).toDouble())).reduce(math.max) * 1.2,
    );
    return Column(children: [
      SizedBox(
        height: 220,
        child: BarChart(BarChartData(
          maxY: maxY,
          gridData: const FlGridData(drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          barGroups: [
            for (var i = 0; i < hourly.length; i++)
              BarChartGroupData(x: i, barsSpace: 3, barRods: [
                BarChartRodData(toY: (hourly[i]['target'] as num).toDouble(), color: const Color(0xFFCBD5E1), width: 12),
                BarChartRodData(
                  toY: (hourly[i]['output'] as num).toDouble(),
                  color: (hourly[i]['output'] as num) < 0.8 * (hourly[i]['target'] as num) ? Brand.danger : Brand.good,
                  width: 12,
                ),
              ]),
          ],
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  return i >= 0 && i < hourly.length ? Text('${hourly[i]['hour']} h', style: const TextStyle(fontSize: 10)) : const SizedBox();
                },
              ),
            ),
          ),
        )),
      ),
      const SizedBox(height: 6),
      const Wrap(spacing: 16, children: [
        _Legend(color: Color(0xFFCBD5E1), label: 'Objectif'),
        _Legend(color: Brand.good, label: 'Réalisé'),
        _Legend(color: Brand.danger, label: 'Réalisé < 80 %'),
      ]),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);
}
