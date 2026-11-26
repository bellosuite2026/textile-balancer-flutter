/// Dessin d'un plan d'atelier (CustomPainter) partagé par l'éditeur et le jumeau numérique.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../../ui/theme.dart';

double _n(Object? v, [double d = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? d);

/// Repère écran ↔ mètres : origine + échelle (pixels par mètre).
class PlanView {
  const PlanView(this.origin, this.scale);
  final Offset origin;
  final double scale;

  Offset toPx(double x, double y) => origin + Offset(x * scale, y * scale);
  (double, double) toM(Offset p) => ((p.dx - origin.dx) / scale, (p.dy - origin.dy) / scale);

  /// Ajuste un rectangle en mètres (x0, y0, x1, y1) dans [size] avec une marge.
  static PlanView fit(Size size, (double, double, double, double) bounds, {double margin = 24}) {
    final (x0, y0, x1, y1) = bounds;
    final w = (x1 - x0).abs() < 1e-6 ? 1.0 : x1 - x0, h = (y1 - y0).abs() < 1e-6 ? 1.0 : y1 - y0;
    final sx = (size.width - 2 * margin) / w, sy = (size.height - 2 * margin) / h;
    final s = (sx < sy ? sx : sy).clamp(2.0, 400.0);
    final ox = (size.width - w * s) / 2 - x0 * s, oy = (size.height - h * s) / 2 - y0 * s;
    return PlanView(Offset(ox, oy), s);
  }
}

const zoneColors = <String, Color>{
  'coupe': Color(0xFFFDE68A),
  'preparation': Color(0xFFBFDBFE),
  'montage': Color(0xFFBBF7D0),
  'finition': Color(0xFFDDD6FE),
  'repassage': Color(0xFFFBCFE8),
  'controle': Color(0xFFFED7AA),
  'stock': Color(0xFFE5E7EB),
  'expedition': Color(0xFFCCFBF1),
};

Color machineColor(String category) => switch (category) {
      'piqure' => const Color(0xFF2563EB),
      'surjet' => const Color(0xFF7C3AED),
      'auto' => const Color(0xFF0891B2),
      'coupe' => const Color(0xFFB45309),
      'repassage' => const Color(0xFFDB2777),
      'controle' => const Color(0xFFEA580C),
      _ => const Color(0xFF64748B),
    };

void _text(Canvas c, String s, Offset at, {double size = 10, Color color = Brand.navy, bool center = true, FontWeight w = FontWeight.w600}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: w)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 160);
  tp.paint(c, center ? at - Offset(tp.width / 2, tp.height / 2) : at);
}

/// Dessine la salle, le fond calibré, les zones, allées, murs, poteaux, portes et machines.
void paintPlan(Canvas canvas, Map plan, PlanView v,
    {String? selectedId,
    Set<String> selectedIds = const {},
    Set<String> issueIds = const {},
    bool Function(Map)? visible,
    double? gridStep,
    Map<String, String> machineStation = const {},
    ui.Image? background,
    bool grid = true,
    double opacity = 1}) {
  final w = _n(plan['width_m'], 30), l = _n(plan['length_m'], 20);
  final room = Rect.fromPoints(v.toPx(0, 0), v.toPx(w, l));
  canvas.drawRect(room, Paint()..color = Colors.white.withValues(alpha: opacity));
  final bg = plan['background_local'] as Map?;
  if (background != null && bg != null && bg['hidden'] != true) {
    final mpp = _n(bg['m_per_px'], 0.01);
    final dst = Rect.fromLTWH(v.toPx(_n(bg['x']), _n(bg['y'])).dx, v.toPx(_n(bg['x']), _n(bg['y'])).dy,
        background.width * mpp * v.scale, background.height * mpp * v.scale);
    canvas.drawImageRect(background, Rect.fromLTWH(0, 0, background.width.toDouble(), background.height.toDouble()), dst,
        Paint()..color = Colors.white.withValues(alpha: _n(bg['opacity'], 0.55).clamp(0.05, 1.0)));
  }
  if (grid && v.scale >= 6) {
    final gp = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..strokeWidth = 0.5;
    var step = v.scale >= 25 ? 1.0 : 5.0;
    final gs = gridStep;
    if (gs != null && gs > 0 && gs * v.scale >= 12) step = gs;
    for (var x = 0.0; x <= w + 1e-6; x += step) {
      canvas.drawLine(v.toPx(x, 0), v.toPx(x, l), gp);
    }
    for (var y = 0.0; y <= l + 1e-6; y += step) {
      canvas.drawLine(v.toPx(0, y), v.toPx(w, y), gp);
    }
  }
  canvas.drawRect(room, Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xFF94A3B8)
    ..strokeWidth = 1);
  final els = planElements(plan);
  // ordre d'affichage : zones, allées, murs/poteaux/portes, machines
  int rank(Map e) => switch (e['kind']) { 'zone' => 0, 'aisle' => 1, 'machine' => 3, 'rail' => 4, 'dim' => 5, _ => 2 };
  els.sort((a, b) => rank(a).compareTo(rank(b)));
  for (final e in els) {
    if (visible != null && !visible(e)) continue;
    final sel = e['id'] == selectedId || selectedIds.contains(e['id']);
    final bad = issueIds.contains(e['id']);
    final selPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Brand.orange
      ..strokeWidth = 2;
    switch (e['kind']) {
      case 'zone':
        final r = Rect.fromLTWH(v.toPx(_n(e['x']), _n(e['y'])).dx, v.toPx(_n(e['x']), _n(e['y'])).dy, _n(e['w'], 1) * v.scale,
            _n(e['h'], 1) * v.scale);
        canvas.drawRect(r, Paint()..color = (zoneColors[e['zone']] ?? const Color(0xFFE0F2FE)).withValues(alpha: 0.55 * opacity));
        _text(canvas, '${e['name'] ?? workshopZones[e['zone']] ?? 'Zone'}', r.topLeft + const Offset(4, 3),
            size: 10, color: Brand.muted, center: false);
        if (sel) canvas.drawRect(r, selPaint);
        if (bad) canvas.drawRect(r, selPaint..color = Brand.danger);
      case 'aisle':
        final r = Rect.fromLTWH(v.toPx(_n(e['x']), _n(e['y'])).dx, v.toPx(_n(e['x']), _n(e['y'])).dy, _n(e['w'], 1) * v.scale,
            _n(e['h'], 1) * v.scale);
        canvas.drawRect(r, Paint()..color = const Color(0xFFFEF9C3).withValues(alpha: opacity));
        canvas.drawRect(r, Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFFEAB308)
          ..strokeWidth = e['main'] == true ? 1.5 : 0.8);
        if (v.scale >= 14) {
          _text(canvas, '${e['main'] == true ? 'allée' : 'passage'} ${fmtM(_n(e['w'], 1) < _n(e['h'], 1) ? _n(e['w'], 1) : _n(e['h'], 1), 2)} m', r.center,
              size: 9, color: const Color(0xFF92400E));
        }
        if (sel) canvas.drawRect(r, selPaint);
        if (bad) canvas.drawRect(r, selPaint..color = Brand.danger);
      case 'wall':
        canvas.drawLine(v.toPx(_n(e['x1']), _n(e['y1'])), v.toPx(_n(e['x2']), _n(e['y2'])), Paint()
          ..color = sel ? Brand.orange : const Color(0xFF334155)
          ..strokeWidth = (_n(e['thickness'], 0.2) * v.scale).clamp(2.0, 30.0)
          ..strokeCap = StrokeCap.square);
      case 'pillar':
        final ww = _n(e['w'], 0.4), dd = _n(e['d'], 0.4);
        final r = Rect.fromCenter(center: v.toPx(_n(e['x']), _n(e['y'])), width: ww * v.scale, height: dd * v.scale);
        canvas.drawRect(r, Paint()..color = const Color(0xFF475569));
        if (sel) canvas.drawRect(r, selPaint);
      case 'door':
        final ww = _n(e['width'], 1);
        final c = v.toPx(_n(e['x']), _n(e['y']));
        final exit = e['exit'] == true;
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(_n(e['rot']) * 3.141592653589793 / 180);
        final s2 = ww * v.scale;
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: s2, height: 0.28 * v.scale), Paint()..color = Colors.white);
        final arc = Path()
          ..moveTo(-s2 / 2, 0)
          ..lineTo(-s2 / 2, -s2)
          ..arcToPoint(Offset(s2 / 2, 0), radius: Radius.circular(s2));
        canvas.drawPath(arc, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sel ? 2 : 1
          ..color = sel ? Brand.orange : (exit ? const Color(0xFF16A34A) : const Color(0xFF8A8F98)));
        if (exit && v.scale >= 10) _text(canvas, 'ISSUE', Offset(0, 0.45 * v.scale), size: 8, color: const Color(0xFF16A34A));
        canvas.restore();
      case 'rail':
        final pts = [for (final p in (e['pts'] as List? ?? const [])) if (p is List && p.length >= 2) v.toPx(_n(p[0]), _n(p[1]))];
        if (pts.length >= 2) {
          final path = Path()..addPolygon(pts, true);
          canvas.drawPath(path, Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = (0.08 * v.scale).clamp(2.0, 8.0) * (sel ? 1.5 : 1)
            ..color = sel ? Brand.orange : const Color(0xFF7B4FA0));
          _text(canvas, '${e['label'] ?? 'Convoyeur'} · ${fmtM(_n(e['height'], 2.1), 1)} m', pts.first - const Offset(0, 10),
              size: 9, color: const Color(0xFF7B4FA0), center: false);
        }
      case 'dim':
        paintDim(canvas, e, v, selected: sel);
      case 'machine':
        final spec = machineCatalog['${e['type']}'];
        final pts = [for (final (x, y) in machineCorners(e)) v.toPx(x, y)];
        final path = Path()..addPolygon(pts, true);
        final col = machineColor(spec?.category ?? '');
        final down = e['status'] == 'panne';
        canvas.drawPath(path, Paint()..color = (down ? Brand.danger : col).withValues(alpha: 0.18 * opacity + 0.05));
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..color = sel ? Brand.orange : (bad || down ? Brand.danger : (e['status'] == 'reserve' ? Brand.low : col))
          ..strokeWidth = sel || bad ? 2.5 : 1.2);
        if (spec?.isWorkstation ?? true) {
          final (ox, oy) = operatorPoint(e);
          canvas.drawCircle(v.toPx(ox, oy), (0.17 * v.scale).clamp(2.0, 9.0),
              Paint()..color = (e['status'] == 'service' || e['status'] == null ? Brand.navy : Brand.low).withValues(alpha: 0.85));
        }
        final st = machineStation['${e['id']}'];
        final center = v.toPx(_n(e['x']), _n(e['y']));
        if (v.scale >= 14) {
          final lab = '${e['label'] ?? ''}'.isNotEmpty ? '${e['label']}' : (spec?.label.split(' ').first ?? '${e['type']}');
          _text(canvas, lab, center, size: (v.scale * 0.22).clamp(7, 11).toDouble(), color: col);
        }
        if (st != null) {
          canvas.drawCircle(pts[0], 7, Paint()..color = Brand.navy);
          _text(canvas, st, pts[0], size: 8, color: Colors.white);
        }
    }
  }
}

/// Bornes d'un plan en mètres (salle + éléments).
(double, double, double, double) planBounds(Map plan) {
  var x0 = 0.0, y0 = 0.0, x1 = _n(plan['width_m'], 30), y1 = _n(plan['length_m'], 20);
  for (final e in planElements(plan)) {
    final (a, b, c, d) = elementBounds(e);
    if (a < x0) x0 = a;
    if (b < y0) y0 = b;
    if (c > x1) x1 = c;
    if (d > y1) y1 = d;
  }
  return (x0, y0, x1, y1);
}

String fmtM(double v, int n) => v.toStringAsFixed(n).replaceAll('.', ',');

/// Cote (distance, chaîne, surface, chemin à pied) : traits, flèches de bout, texte sur fond blanc.
void paintDim(Canvas canvas, Map d, PlanView v, {bool selected = false, bool temp = false}) {
  final walk = d['mode'] == 'walk';
  final col = selected ? Brand.orange : (walk ? const Color(0xFF16A34A) : const Color(0xFF1F4E79));
  final p = Paint()
    ..color = col
    ..strokeWidth = selected ? 2 : 1.3
    ..style = PaintingStyle.stroke;
  for (final (a, b) in dimSegments(d)) {
    final pa = v.toPx(a.$1, a.$2), pb = v.toPx(b.$1, b.$2);
    if (temp) {
      // pointillés
      final len = (pb - pa).distance;
      if (len < 1) continue;
      final u = (pb - pa) / len;
      for (var t = 0.0; t < len; t += 8) {
        canvas.drawLine(pa + u * t, pa + u * (t + 4 < len ? t + 4 : len), p);
      }
    } else {
      canvas.drawLine(pa, pb, p);
    }
    if (!walk && d['mode'] != 'area') {
      for (final q in [pa, pb]) {
        final dir = pb - pa;
        if (dir.distance < 1) continue;
        final n = Offset(-dir.dy, dir.dx) / dir.distance * 5;
        canvas.drawLine(q - n, q + n, p);
      }
    }
  }
  final (lx, ly) = dimLabelAt(d);
  final tp = TextPainter(
    text: TextSpan(text: dimText(d), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: col)),
    textDirection: TextDirection.ltr,
  )..layout();
  final at = v.toPx(lx, ly);
  final r = Rect.fromCenter(center: at, width: tp.width + 6, height: tp.height + 2);
  canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), Paint()..color = Colors.white.withValues(alpha: 0.9));
  tp.paint(canvas, r.topLeft + const Offset(3, 1));
}
