/// Simulation rapide (déterministe, hors ligne) d'un résultat d'équilibrage :
/// débit, encours, temps de traversée, goulot, occupation des stations.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key, required this.runId});
  final String runId;

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen> {
  double _hours = 8;
  double _eff = 85;
  int _buffer = 10;
  int _initWip = 2;
  double _transport = 0.1;
  double _cv = 0;
  bool _workerTimes = true;
  SimResult? _res;

  void _run(BalanceResult b) => setState(() => _res = _compute(b));

  SimResult _compute(BalanceResult b) {
    final st = stationsFromResult(b, useWorkerTimes: _workerTimes);
    return simulateLine(
          st,
          SimConfig(
            durationMinutes: _hours * 60,
            efficiency: _eff / 100,
            bufferCapacity: _buffer,
            initialWipPerBuffer: _initWip,
            transportMinutes: _transport,
            variability: _cv / 100,
            useWorkerTimes: _workerTimes,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final r = context.read<AppState>().repo.run(widget.runId);
    final b = r?.balance;
    if (r == null || b == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable.'));
    }
    final res = _res ??= _compute(b);
    final h = res.horizon;
    return Scaffold(
      appBar: AppBar(title: Text('Simulation rapide · ${r.problem.name}', overflow: TextOverflow.ellipsis)),
      body: PageScaffold(
        title: 'Simulation rapide de la ligne',
        subtitle: 'Modèle déterministe sur cet appareil. La simulation détaillée (aléas, pannes, convoyeur) est disponible en ligne.',
        children: [
          SectionCard(
            title: 'Paramètres',
            child: Wrap(spacing: 24, runSpacing: 8, children: [
              _slider('Durée (h)', _hours, 1, 10, 9, (v) => _hours = v, fmtNum(_hours, 1)),
              _slider('Efficience (%)', _eff, 50, 120, 70, (v) => _eff = v, fmtNum(_eff, 0)),
              _slider('Encours max entre postes', _buffer.toDouble(), 1, 50, 49, (v) => _buffer = v.round(), '$_buffer'),
              _slider('Encours de départ', _initWip.toDouble(), 0, 20, 20, (v) => _initWip = v.round(), '$_initWip'),
              _slider('Transport (min)', _transport, 0, 2, 20, (v) => _transport = v, fmtNum(_transport, 2)),
              _slider('Variabilité (%)', _cv, 0, 40, 8, (v) => _cv = v, fmtNum(_cv, 0)),
              SizedBox(
                width: 300,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _workerTimes,
                  onChanged: (v) {
                    _workerTimes = v;
                    _run(b);
                  },
                  title: const Text('Temps réels des ouvrières (rendement)'),
                ),
              ),
            ]),
          ),
          KpiGrid(children: [
            KpiCard(label: 'Pièces produites', value: '${res.completed}', sub: 'en ${fmtNum(h / 60, 1)} h'),
            KpiCard(label: 'Débit', value: '${fmtNum(res.throughputPerHour, 1)} pcs/h', sub: 'théorique ${fmtNum(b.outputPerHour, 1)}'),
            KpiCard(label: 'Encours moyen', value: fmtNum(res.avgWip, 1), sub: 'pièces'),
            KpiCard(label: 'Temps de traversée', value: fmtMin(res.avgLeadTimeMinutes, 1)),
            KpiCard(label: 'Goulot', value: 'Station ${res.bottleneckStation}', color: Brand.danger),
            KpiCard(label: 'Opérateurs', value: '${b.operators}'),
          ]),
          SectionCard(
            title: 'Pièces finies cumulées',
            child: SizedBox(
              height: 200,
              child: LineChart(LineChartData(
                minX: 0,
                maxX: h,
                minY: 0,
                gridData: const FlGridData(drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 60,
                      getTitlesWidget: (v, m) => Text('${(v / 60).round()} h', style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (final (t, n) in res.outputCurve) FlSpot(t, n.toDouble())],
                    isStepLineChart: true,
                    dotData: const FlDotData(show: false),
                    color: Brand.navy,
                    barWidth: 2,
                  ),
                ],
              )),
            ),
          ),
          SectionCard(
            title: 'Par station',
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: ScrollTable(
              columns: const [
                DataColumn(label: Text('Station')),
                DataColumn(label: Text('min/pc'), numeric: true),
                DataColumn(label: Text('Opérateurs'), numeric: true),
                DataColumn(label: Text('Pièces'), numeric: true),
                DataColumn(label: Text('Occupation')),
                DataColumn(label: Text('Bloquée'), numeric: true),
                DataColumn(label: Text('En attente'), numeric: true),
                DataColumn(label: Text('File moy. / max'), numeric: true),
              ],
              rows: [
                for (final s in res.stations)
                  DataRow(cells: [
                    DataCell(Text('${s.station}',
                        style: TextStyle(fontWeight: FontWeight.w700, color: s.station == res.bottleneckStation ? Brand.danger : null))),
                    DataCell(Text(fmtNum(s.minutesPerPiece, 3))),
                    DataCell(Text('${s.operators}')),
                    DataCell(Text('${s.processed}')),
                    DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(
                        width: 70,
                        child: LinearProgressIndicator(
                          value: s.utilization(h).clamp(0, 1),
                          minHeight: 8,
                          color: s.utilization(h) > 0.92 ? Brand.danger : (s.utilization(h) < 0.75 ? Brand.mid : Brand.good),
                          backgroundColor: const Color(0xFFEFF2F6),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(fmtPct(s.utilization(h) * 100, 0)),
                    ])),
                    DataCell(Text(fmtPct(s.blockedPct(h) * 100, 0))),
                    DataCell(Text(fmtPct(s.starvedPct(h) * 100, 0))),
                    DataCell(Text('${fmtNum(s.avgQueue(h), 1)} / ${s.maxQueue}')),
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, double v, double min, double max, int div, void Function(double) set, String shown) => SizedBox(
        width: 300,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label : $shown', style: const TextStyle(fontSize: 13)),
          Slider(
            value: v.clamp(min, max),
            min: min,
            max: max,
            divisions: div,
            onChanged: (x) => setState(() => set(x)),
            onChangeEnd: (_) {
              final b = context.read<AppState>().repo.run(widget.runId)?.balance;
              if (b != null) _run(b);
            },
          ),
        ]),
      );
}
