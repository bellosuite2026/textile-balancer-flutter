/// Yamazumi : charge empilée par opération pour chaque station, comparée à la cadence (ligne de takt).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../ui/theme.dart';

const _palette = [
  Color(0xFF3B82F6),
  Color(0xFF22A06B),
  Color(0xFFF59E0B),
  Color(0xFF8B5CF6),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFF84CC16),
  Color(0xFF64748B),
];

class YamazumiChart extends StatelessWidget {
  const YamazumiChart({super.key, required this.result, required this.problem, this.height = 300});
  final BalanceResult result;
  final Problem problem;
  final double height;

  @override
  Widget build(BuildContext context) {
    final st = result.stationDetails;
    if (st.isEmpty) return const SizedBox.shrink();
    final c = result.targetCycleTime;
    final ops = {for (final o in problem.operations) o.id: o};
    final maxY = math.max(c * 1.2, st.map((s) => s.totalTime).fold(0.0, math.max) * 1.1);
    final groups = <BarChartGroupData>[];
    for (var i = 0; i < st.length; i++) {
      final s = st[i];
      final par = math.max(1, s.parallel);
      var y = 0.0;
      final items = <BarChartRodStackItem>[];
      for (var k = 0; k < s.operations.length; k++) {
        final oid = s.operations[k];
        final m = (s.shares?[oid] ?? ops[oid]?.duration ?? 0) / par;
        items.add(BarChartRodStackItem(y, y + m, _palette[k % _palette.length]));
        y += m;
      }
      if (s.totalTime - y > 1e-3) {
        // temps de déplacement entre machines
        items.add(BarChartRodStackItem(y, s.totalTime, Colors.grey.shade400));
      }
      final over = s.totalTime > c + 1e-6;
      groups.add(BarChartGroupData(x: i, barRods: [
        BarChartRodData(
          toY: math.max(s.totalTime, y),
          width: math.max(8, math.min(36, 600 / st.length)),
          rodStackItems: items,
          borderRadius: BorderRadius.circular(3),
          borderSide: over ? const BorderSide(color: Brand.danger, width: 2) : BorderSide.none,
          color: Colors.transparent,
        ),
      ]));
    }
    final width = math.max(360.0, st.length * 42.0);
    return LayoutBuilder(builder: (context, box) {
      final chart = SizedBox(
        width: math.max(box.maxWidth, width),
        height: height,
        child: BarChart(BarChartData(
          maxY: maxY,
          minY: 0,
          barGroups: groups,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: _niceStep(maxY),
            getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFEFF2F6), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(horizontalLines: [
            HorizontalLine(
              y: c,
              color: Brand.danger,
              strokeWidth: 2,
              dashArray: [6, 4],
              label: HorizontalLineLabel(
                show: true,
                alignment: Alignment.topRight,
                style: const TextStyle(color: Brand.danger, fontWeight: FontWeight.w600, fontSize: 11),
                labelResolver: (_) => 'Cadence ${fmtNum(c, 3)} min',
              ),
            ),
          ]),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: _niceStep(maxY),
                getTitlesWidget: (v, meta) =>
                    Text(fmtNum(v, 2), style: const TextStyle(fontSize: 10, color: Brand.muted)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= st.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${st[i].station}${st[i].parallel > 1 ? '×${st[i].parallel}' : ''}',
                        style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => const Color(0xF01F2937),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItem: (g, gi, rod, ri) {
                final s = st[g.x];
                return BarTooltipItem(
                  'Station ${s.station} · ${fmtNum(s.totalTime, 3)} min (${fmtNum(s.loadPct, 1)} %)\n'
                  '${s.operations.map((o) => '$o ${ops[o]?.name ?? ''}'.trim()).join('\n')}',
                  const TextStyle(color: Colors.white, fontSize: 11),
                  textAlign: TextAlign.left,
                );
              },
            ),
          ),
        )),
      );
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: chart);
    });
  }
}

double _niceStep(double max) {
  if (max <= 0) return 1;
  final raw = max / 5;
  final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in [1, 2, 2.5, 5, 10]) {
    if (raw <= m * p) return m * p;
  }
  return 10 * p;
}
