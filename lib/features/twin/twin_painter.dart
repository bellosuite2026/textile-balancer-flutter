/// Vue animée de la ligne (CustomPainter) : postes, ouvrières, paquets en file / en travail / en
/// transit, encours devant chaque poste, goulot en rouge, plan d'atelier en fond si présent.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../../ui/theme.dart';
import '../workshop/plan_painting.dart';

const double stationWm = 1.1; // largeur dessinée d'un poste (m)
const double stationDm = 0.7;

class TwinPainter extends CustomPainter {
  TwinPainter({
    required this.order,
    required this.positions,
    required this.bundles,
    required this.workersByStation,
    this.bottleneck,
    this.plan,
    this.selected,
    this.bundleSize = 10,
  });

  final List<int> order;
  final Map<String, dynamic> positions; // {"<station>": {x, y}} mètres
  final List<BundleView> bundles;
  final Map<int, List<String>> workersByStation;
  final int? bottleneck;
  final Map<String, dynamic>? plan;
  final int? selected;
  final int bundleSize;

  (double, double) pos(int sid) {
    final p = positions['$sid'] as Map?;
    return (((p?['x'] ?? 0) as num).toDouble(), ((p?['y'] ?? 0) as num).toDouble());
  }

  (double, double, double, double) bounds() {
    if (plan != null) {
      var (x0, y0, x1, y1) = planBounds(plan!);
      for (final s in order) {
        final (x, y) = pos(s);
        x0 = math.min(x0, x - 1);
        y0 = math.min(y0, y - 1);
        x1 = math.max(x1, x + 1);
        y1 = math.max(y1, y + 1.2);
      }
      return (x0, y0, x1, y1);
    }
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final s in order) {
      final (x, y) = pos(s);
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
    }
    if (x0.isInfinite) return (0, 0, 1, 1);
    return (x0 - 1.0, y0 - 1.3, x1 + 1.0, y1 + 1.3);
  }

  PlanView view(Size size) => PlanView.fit(size, bounds(), margin: 16);

  /// Station sous le point (pour le glisser-déposer en disposition libre).
  int? hit(Size size, Offset p) {
    final v = view(size);
    for (final s in order) {
      final (x, y) = pos(s);
      final c = v.toPx(x, y);
      final r = Rect.fromCenter(center: c, width: math.max(28, stationWm * v.scale), height: math.max(22, stationDm * v.scale));
      if (r.inflate(6).contains(p)) return s;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final v = view(size);
    if (plan != null) paintPlan(canvas, plan!, v, grid: false, opacity: 0.8);
    final s = v.scale;
    final sw = math.max(26.0, stationWm * s), sd = math.max(20.0, stationDm * s);
    // flux entre postes
    final flow = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i + 1 < order.length; i++) {
      final (ax, ay) = pos(order[i]);
      final (bx, by) = pos(order[i + 1]);
      final a = v.toPx(ax, ay), b = v.toPx(bx, by);
      canvas.drawLine(a, b, flow);
      final mid = Offset.lerp(a, b, 0.5)!;
      final dir = (b - a);
      if (dir.distance > 1) {
        final u = dir / dir.distance;
        final n = Offset(-u.dy, u.dx);
        final path = Path()
          ..moveTo(mid.dx + u.dx * 5, mid.dy + u.dy * 5)
          ..lineTo(mid.dx - u.dx * 4 + n.dx * 4, mid.dy - u.dy * 4 + n.dy * 4)
          ..lineTo(mid.dx - u.dx * 4 - n.dx * 4, mid.dy - u.dy * 4 - n.dy * 4)
          ..close();
        canvas.drawPath(path, Paint()..color = const Color(0xFF94A3B8));
      }
    }
    // encours par station (pièces en file + en travail)
    final queue = <int, int>{}, working = <int, Set<String>>{};
    for (final b in bundles) {
      if (b.state == 'queue') queue[b.station] = (queue[b.station] ?? 0) + b.size;
      if (b.state == 'work') working.putIfAbsent(b.station, () => {}).add(b.worker ?? '?');
    }
    for (final sid in order) {
      final (x, y) = pos(sid);
      final c = v.toPx(x, y);
      final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: sw, height: sd), const Radius.circular(5));
      final isB = sid == bottleneck;
      if (isB) {
        canvas.drawRRect(rect.inflate(5), Paint()
          ..color = Brand.danger.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      }
      final busy = (working[sid]?.isNotEmpty ?? false);
      canvas.drawRRect(rect, Paint()..color = busy ? const Color(0xFFDCFCE7) : Colors.white);
      canvas.drawRRect(rect, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isB || sid == selected ? 2.5 : 1.3
        ..color = sid == selected ? Brand.orange : (isB ? Brand.danger : Brand.navy));
      _label(canvas, 'S$sid', c, size: math.min(12, math.max(9, sd * 0.4)), color: isB ? Brand.danger : Brand.navy);
      // ouvrières (cercles sous le poste)
      final ws = workersByStation[sid] ?? const <String>[];
      for (var k = 0; k < ws.length; k++) {
        final o = c + Offset((k - (ws.length - 1) / 2) * 11, sd / 2 + 8);
        final on = working[sid]?.contains(ws[k]) ?? false;
        canvas.drawCircle(o, 4.5, Paint()..color = on ? Brand.ok : Brand.low);
      }
      if (ws.isEmpty) _label(canvas, '∅', c + Offset(0, sd / 2 + 8), size: 10, color: Brand.danger);
      // file d'encours : barre au-dessus du poste
      final q = queue[sid] ?? 0;
      if (q > 0) {
        final n = (q / math.max(1, bundleSize)).ceil();
        final shown = math.min(n, 6);
        for (var k = 0; k < shown; k++) {
          final r = Rect.fromLTWH(c.dx - sw / 2 + k * 7.0, c.dy - sd / 2 - 9, 6, 6);
          canvas.drawRect(r, Paint()..color = n > 4 ? Brand.warn : Brand.mid);
        }
        _label(canvas, '$q', Offset(c.dx + sw / 2 - 2, c.dy - sd / 2 - 7), size: 9, color: Brand.muted, align: 1);
      }
    }
    // paquets en transit
    for (final b in bundles.where((b) => b.state == 'transit' && b.toStation != null)) {
      final (ax, ay) = pos(b.station);
      final (bx, by) = pos(b.toStation!);
      final p = Offset.lerp(v.toPx(ax, ay), v.toPx(bx, by), b.progress)!;
      canvas.drawRect(Rect.fromCenter(center: p.translate(0, -sd / 2 - 3), width: 7, height: 7), Paint()..color = Brand.orange);
    }
  }

  void _label(Canvas c, String s, Offset at, {double size = 10, Color color = Brand.navy, int align = 0}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == 0 ? tp.width / 2 : 0.0;
    tp.paint(c, at - Offset(dx, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant TwinPainter old) => true;
}
