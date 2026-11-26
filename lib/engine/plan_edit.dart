/// Édition du plan d'atelier — logique pure (sans Flutter), parité avec `web/src/lib/workshop.ts`
/// et `web/src/pages/WorkshopPlan.tsx` : géométrie des éléments, toucher, aimantation, cotes et mesures
/// (distance, chaîne, surface, chemin à pied A*), convoyeurs, duplication, copier/coller, rotation,
/// alignement, contrôles, import DXF, historique annuler/rétablir.
///
/// Les éléments restent des `Map` au format de l'API `/workshop-plans` ; deux éléments s'ajoutent à
/// ceux de `workshop.dart` : `dim {mode: dist|chain|area|walk, pts: [[x,y]...], note?}` et
/// `rail {pts, height, radius, label}` (convoyeur suspendu, boucle fermée).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'workshop.dart';

typedef P = (double, double);

double _n(Object? v, [double d = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? d);
double r2(double v) => (v * 100).roundToDouble() / 100;

// ------------------------------------------------------------------------------- réglages
class PlanSettings {
  const PlanSettings({
    this.grid = 0.1,
    this.snap = true,
    this.mainAisleMin = 1.2,
    this.secondaryAisleMin = 0.8,
    this.exitMaxM = 40,
    this.wallHeight = 3,
  });
  final double grid;
  final bool snap;
  final double mainAisleMin;
  final double secondaryAisleMin;
  final double exitMaxM;
  final double wallHeight;

  /// Lecture tolérante : `grid` (web) ou `grid_m` (anciens plans Flutter).
  factory PlanSettings.of(Map plan) {
    final s = (plan['settings'] as Map?) ?? const {};
    final g = _n(s['grid'] ?? s['grid_m'], 0.1);
    return PlanSettings(
      grid: g > 0 ? g : 0.1,
      snap: s['snap'] != false,
      mainAisleMin: _n(s['main_aisle_min'], 1.2),
      secondaryAisleMin: _n(s['secondary_aisle_min'], 0.8),
      exitMaxM: _n(s['exit_max_m'], 40),
      wallHeight: _n(s['wall_height'], 3),
    );
  }

  double snapV(double v) => snap ? r2((v / grid).round() * grid) : r2(v);
  P snapP(P p) => (snapV(p.$1), snapV(p.$2));
}

// ------------------------------------------------------------------------------- géométrie
P rotV(double x, double y, double deg) {
  final a = deg * math.pi / 180;
  return (x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a));
}

List<P> rectCorners(double cx, double cy, double w, double d, double deg) => [
      for (final (lx, ly) in [(-w / 2, -d / 2), (w / 2, -d / 2), (w / 2, d / 2), (-w / 2, d / 2)])
        () {
          final (dx, dy) = rotV(lx, ly, deg);
          return (cx + dx, cy + dy);
        }(),
    ];

List<P> _box(double x, double y, double w, double h) => [(x, y), (x + w, y), (x + w, y + h), (x, y + h)];

List<P> ptsOf(Map e) => [
      for (final p in (e['pts'] as List? ?? const []))
        if (p is List && p.length >= 2) (_n(p[0]), _n(p[1])),
    ];

List<List<double>> ptsJson(List<P> pts) => [for (final p in pts) [r2(p.$1), r2(p.$2)]];

/// Place de l'opératrice (côté de travail) : devant la machine par défaut.
P operatorPoint(Map m) {
  const g = 0.45;
  final w = _n(m['w'], 1.2), d = _n(m['d'], 0.6);
  final (lx, ly) = switch ('${m['operator'] ?? 'front'}') {
    'back' => (0.0, -d / 2 - g),
    'left' => (-w / 2 - g, 0.0),
    'right' => (w / 2 + g, 0.0),
    _ => (0.0, d / 2 + g),
  };
  final (dx, dy) = rotV(lx, ly, _n(m['rot']));
  return (_n(m['x']) + dx, _n(m['y']) + dy);
}

List<P> wallPoly(Map w, [double? thickness]) {
  final x1 = _n(w['x1']), y1 = _n(w['y1']), x2 = _n(w['x2']), y2 = _n(w['y2']);
  final dx = x2 - x1, dy = y2 - y1;
  final l = math.sqrt(dx * dx + dy * dy) == 0 ? 1.0 : math.sqrt(dx * dx + dy * dy);
  final t = (thickness ?? _n(w['thickness'], 0.2)) / 2;
  final nx = -dy / l * t, ny = dx / l * t;
  return [(x1 + nx, y1 + ny), (x2 + nx, y2 + ny), (x2 - nx, y2 - ny), (x1 - nx, y1 - ny)];
}

/// Contour d'un élément (polygone en mètres).
List<P> elPoly(Map e) {
  switch (e['kind']) {
    case 'machine':
      return rectCorners(_n(e['x']), _n(e['y']), _n(e['w'], 1.2), _n(e['d'], 0.6), _n(e['rot']));
    case 'wall':
      return wallPoly(e);
    case 'pillar':
      final w = _n(e['w'], 0.4), d = _n(e['d'], 0.4);
      return _box(_n(e['x']) - w / 2, _n(e['y']) - d / 2, w, d);
    case 'door':
      return rectCorners(_n(e['x']), _n(e['y']), _n(e['width'], 1), 0.3, _n(e['rot']));
    case 'dim':
    case 'rail':
      final pts = ptsOf(e);
      if (pts.isEmpty) return _box(0, 0, 0.01, 0.01);
      final xs = pts.map((p) => p.$1), ys = pts.map((p) => p.$2);
      final x0 = xs.reduce(math.min), y0 = ys.reduce(math.min);
      return _box(x0, y0, math.max(0.01, xs.reduce(math.max) - x0), math.max(0.01, ys.reduce(math.max) - y0));
    default: // aisle, zone
      return _box(_n(e['x']), _n(e['y']), _n(e['w'], 1), _n(e['h'], 1));
  }
}

(double, double, double, double) polyBounds(List<P> poly) {
  final xs = poly.map((p) => p.$1), ys = poly.map((p) => p.$2);
  return (xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
}

P elCenter(Map e) {
  switch (e['kind']) {
    case 'wall':
      return ((_n(e['x1']) + _n(e['x2'])) / 2, (_n(e['y1']) + _n(e['y2'])) / 2);
    case 'aisle':
    case 'zone':
      return (_n(e['x']) + _n(e['w'], 1) / 2, _n(e['y']) + _n(e['h'], 1) / 2);
    case 'dim':
    case 'rail':
      final (a, b, c, d) = polyBounds(elPoly(e));
      return ((a + c) / 2, (b + d) / 2);
    default:
      return (_n(e['x']), _n(e['y']));
  }
}

bool pointIn(List<P> poly, double x, double y) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final (xi, yi) = poly[i];
    final (xj, yj) = poly[j];
    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

double segDist(double px, double py, double x1, double y1, double x2, double y2) {
  final vx = x2 - x1, vy = y2 - y1, l2 = vx * vx + vy * vy;
  final t = l2 == 0 ? 0.0 : (((px - x1) * vx + (py - y1) * vy) / l2).clamp(0.0, 1.0);
  final dx = px - (x1 + t * vx), dy = py - (y1 + t * vy);
  return math.sqrt(dx * dx + dy * dy);
}

double _dist(P a, P b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Recouvrement de deux polygones convexes (axes séparateurs), tolérance en mètres.
bool overlap(List<P> a, List<P> b, [double tol = 0.02]) {
  for (final poly in [a, b]) {
    for (var i = 0; i < poly.length; i++) {
      final (x1, y1) = poly[i];
      final (x2, y2) = poly[(i + 1) % poly.length];
      final nx = y2 - y1, ny = x1 - x2;
      final l = math.sqrt(nx * nx + ny * ny) == 0 ? 1.0 : math.sqrt(nx * nx + ny * ny);
      final pa = [for (final (x, y) in a) (x * nx + y * ny) / l], pb = [for (final (x, y) in b) (x * nx + y * ny) / l];
      if (pa.reduce(math.max) - tol <= pb.reduce(math.min) || pb.reduce(math.max) - tol <= pa.reduce(math.min)) return false;
    }
  }
  return true;
}

/// Déplace un élément (tous types, y compris cotes et convoyeurs).
void moveEl(Map<String, dynamic> e, double dx, double dy) {
  if (e['kind'] == 'dim' || e['kind'] == 'rail') {
    e['pts'] = ptsJson([for (final p in ptsOf(e)) (p.$1 + dx, p.$2 + dy)]);
  } else {
    moveElement(e, dx, dy);
  }
}

// ------------------------------------------------------------------------------- cotes
double polyLen(List<P> pts) {
  var l = 0.0;
  for (var i = 1; i < pts.length; i++) {
    l += _dist(pts[i - 1], pts[i]);
  }
  return l;
}

List<(P, P)> dimSegments(Map d) {
  final pts = ptsOf(d);
  if (d['mode'] == 'area' && pts.length >= 2) {
    final (x0, y0) = pts[0];
    final (x1, y1) = pts[1];
    final c = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)];
    return [for (var i = 0; i < 4; i++) (c[i], c[(i + 1) % 4])];
  }
  return [for (var i = 1; i < pts.length; i++) (pts[i - 1], pts[i])];
}

P dimLabelAt(Map d) {
  final pts = ptsOf(d);
  if (pts.isEmpty) return (0, 0);
  if (d['mode'] == 'area' && pts.length >= 2) return ((pts[0].$1 + pts[1].$1) / 2, (pts[0].$2 + pts[1].$2) / 2);
  var l = polyLen(pts) / 2;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i], s = _dist(a, b);
    if (l <= s || i == pts.length - 1) {
      final k = s == 0 ? 0.0 : math.min(1.0, l / s);
      return (a.$1 + (b.$1 - a.$1) * k, a.$2 + (b.$2 - a.$2) * k);
    }
    l -= s;
  }
  return pts.first;
}

String frNum(double v, [int n = 2]) => v.toStringAsFixed(n).replaceAll('.', ',');

String dimText(Map d) {
  final pts = ptsOf(d);
  if (d['mode'] == 'area' && pts.length >= 2) {
    final w = (pts[1].$1 - pts[0].$1).abs(), h = (pts[1].$2 - pts[0].$2).abs();
    return '${frNum(w)} × ${frNum(h)} m = ${frNum(w * h, 1)} m²';
  }
  final l = polyLen(pts);
  if (d['mode'] == 'walk') return 'à pied ${frNum(l, 1)} m';
  return '${frNum(l)} m';
}

Map<String, dynamic> newDim(String id, String mode, List<P> pts, {String? note}) => {
      'id': id,
      'kind': 'dim',
      'mode': mode,
      'pts': ptsJson(pts),
      'note': ?note,
    };

// ------------------------------------------------------------------------------- toucher
/// Élément sous le point : cotes et convoyeurs d'abord, puis machines… zones en dernier.
Map<String, dynamic>? hitTest(List<Map<String, dynamic>> els, double x, double y, {double tol = 0.15, bool Function(Map)? visible}) {
  const order = ['dim', 'rail', 'machine', 'pillar', 'door', 'wall', 'aisle', 'zone'];
  for (final k in order) {
    for (var i = els.length - 1; i >= 0; i--) {
      final e = els[i];
      if (e['kind'] != k || (visible != null && !visible(e))) continue;
      switch (k) {
        case 'dim':
          final lab = dimLabelAt(e);
          if (dimSegments(e).any((s) => segDist(x, y, s.$1.$1, s.$1.$2, s.$2.$1, s.$2.$2) <= tol) || _dist((x, y), lab) <= tol * 2) return e;
        case 'rail':
          final pts = ptsOf(e);
          for (var j = 0; j < pts.length; j++) {
            final a = pts[j], b = pts[(j + 1) % pts.length];
            if (segDist(x, y, a.$1, a.$2, b.$1, b.$2) <= tol) return e;
          }
        case 'wall':
          if (segDist(x, y, _n(e['x1']), _n(e['y1']), _n(e['x2']), _n(e['y2'])) <= math.max(0.15, _n(e['thickness'], 0.2) / 2 + 0.05)) return e;
        case 'door':
          if (_dist((x, y), (_n(e['x']), _n(e['y']))) <= math.max(0.4, _n(e['width'], 1) / 2)) return e;
        default:
          if (pointIn(elPoly(e), x, y)) return e;
      }
    }
  }
  return null;
}

/// Éléments entièrement contenus dans le rectangle (encadrement).
List<String> idsInRect(List<Map<String, dynamic>> els, P a, P b, {bool Function(Map)? visible}) {
  final x0 = math.min(a.$1, b.$1), x1 = math.max(a.$1, b.$1), y0 = math.min(a.$2, b.$2), y1 = math.max(a.$2, b.$2);
  return [
    for (final e in els)
      if ((visible == null || visible(e)) && elPoly(e).every((p) => p.$1 >= x0 && p.$1 <= x1 && p.$2 >= y0 && p.$2 <= y1)) '${e['id']}',
  ];
}

// ------------------------------------------------------------------------------- aimantation
/// Points d'aimantation de la mesure : coins et centres des machines, place opératrice, poteaux,
/// extrémités et milieux des murs, coins des allées/zones, portes, points des cotes et convoyeurs.
List<P> snapTargets(List<Map<String, dynamic>> els) {
  final out = <P>[];
  for (final e in els) {
    switch (e['kind']) {
      case 'machine':
        out
          ..add((_n(e['x']), _n(e['y'])))
          ..addAll(elPoly(e))
          ..add(operatorPoint(e));
      case 'pillar':
        out
          ..add((_n(e['x']), _n(e['y'])))
          ..addAll(elPoly(e));
      case 'wall':
        out.addAll([(_n(e['x1']), _n(e['y1'])), (_n(e['x2']), _n(e['y2'])), elCenter(e)]);
      case 'aisle':
      case 'zone':
        out.addAll(elPoly(e));
      case 'door':
        out.add((_n(e['x']), _n(e['y'])));
      case 'dim':
      case 'rail':
        out.addAll(ptsOf(e));
    }
  }
  return out;
}

/// Aimante sur un point remarquable proche, sinon sur la face d'un mur, sinon `null`.
({P p, String label})? snapMeasure(List<Map<String, dynamic>> els, P p, double radius) {
  P? best;
  var bd = radius;
  for (final q in snapTargets(els)) {
    final d = _dist(q, p);
    if (d < bd) {
      bd = d;
      best = q;
    }
  }
  if (best != null) return (p: (r2(best.$1), r2(best.$2)), label: 'point');
  P? wb;
  var wd = radius * 0.8;
  for (final e in els) {
    if (e['kind'] != 'wall') continue;
    final x1 = _n(e['x1']), y1 = _n(e['y1']), vx = _n(e['x2']) - x1, vy = _n(e['y2']) - y1;
    final l2 = vx * vx + vy * vy == 0 ? 1.0 : vx * vx + vy * vy, l = math.sqrt(l2);
    final t = (((p.$1 - x1) * vx + (p.$2 - y1) * vy) / l2).clamp(0.0, 1.0);
    final cx = x1 + t * vx, cy = y1 + t * vy, nx = -vy / l, ny = vx / l;
    final side = (p.$1 - cx) * nx + (p.$2 - cy) * ny >= 0 ? 1 : -1;
    final th = _n(e['thickness'], 0.2) / 2;
    final f = (cx + nx * side * th, cy + ny * side * th);
    final d = _dist(p, f);
    if (d < wd) {
      wd = d;
      wb = f;
    }
  }
  return wb == null ? null : (p: (r2(wb.$1), r2(wb.$2)), label: 'mur');
}

/// Extrémité de mur la plus proche (rayon 0,3 m), sinon aimantation à la grille.
P snapToWallEnds(List<Map<String, dynamic>> els, P p, PlanSettings st, {String? except, double radius = 0.3}) {
  P? best;
  var bd = radius;
  for (final e in els) {
    if (e['kind'] != 'wall' || e['id'] == except) continue;
    for (final q in [(_n(e['x1']), _n(e['y1'])), (_n(e['x2']), _n(e['y2']))]) {
      final d = _dist(q, p);
      if (d < bd) {
        bd = d;
        best = q;
      }
    }
  }
  return best ?? st.snapP(p);
}

/// Mur le plus proche (< 0,8 m) : angle et point projeté, pour poser une porte dans l'axe du mur.
({double angle, double x, double y})? nearestWallAngle(List<Map<String, dynamic>> els, double x, double y) {
  ({double d, double angle, double x, double y})? best;
  for (final e in els) {
    if (e['kind'] != 'wall') continue;
    final x1 = _n(e['x1']), y1 = _n(e['y1']), x2 = _n(e['x2']), y2 = _n(e['y2']);
    final d = segDist(x, y, x1, y1, x2, y2);
    if (d < 0.8 && (best == null || d < best.d)) {
      final vx = x2 - x1, vy = y2 - y1, l2 = vx * vx + vy * vy == 0 ? 1.0 : vx * vx + vy * vy;
      final t = (((x - x1) * vx + (y - y1) * vy) / l2).clamp(0.0, 1.0);
      best = (d: d, angle: math.atan2(vy, vx) * 180 / math.pi, x: x1 + t * vx, y: y1 + t * vy);
    }
  }
  return best == null ? null : (angle: best.angle, x: r2(best.x), y: r2(best.y));
}

// ------------------------------------------------------------------------------- chemin à pied
/// Chemin à pied le plus court entre les places opératrices de deux machines (A* sur une grille de
/// 10–25 cm ; murs, poteaux et autres machines = obstacles, portes ouvertes). Parité `walkRoute`.
({List<P> pts, double length})? walkRoute(Map plan, String aId, String bId) {
  final els = planElements(plan);
  Map<String, dynamic>? find(String id) => els.where((e) => e['id'] == id && e['kind'] == 'machine').firstOrNull;
  final a = find(aId), b = find(bId);
  if (a == null || b == null) return null;
  final wm = _n(plan['width_m'], 30), lm = _n(plan['length_m'], 20);
  final c = math.max(0.1, math.min(0.25, math.sqrt(wm * lm / 60000)));
  final nx = (wm / c).ceil(), ny = (lm / c).ceil();
  final block = List<bool>.filled(nx * ny, false);
  void mark(List<P> poly, bool v) {
    final (bx0, by0, bx1, by1) = polyBounds(poly);
    for (var j = math.max(0, (by0 / c).floor()); j <= math.min(ny - 1, (by1 / c).floor()); j++) {
      for (var i = math.max(0, (bx0 / c).floor()); i <= math.min(nx - 1, (bx1 / c).floor()); i++) {
        if (pointIn(poly, (i + 0.5) * c, (j + 0.5) * c)) block[j * nx + i] = v;
      }
    }
  }

  for (final e in els) {
    if (e['kind'] == 'wall') {
      mark(wallPoly(e, math.max(_n(e['thickness'], 0.2), c * 1.2)), true);
    } else if (e['kind'] == 'pillar' || (e['kind'] == 'machine' && e['id'] != aId && e['id'] != bId)) {
      mark(elPoly(e), true);
    }
  }
  for (final d in els) {
    if (d['kind'] == 'door') mark(rectCorners(_n(d['x']), _n(d['y']), _n(d['width'], 1), 0.6, _n(d['rot'])), false);
  }
  (int, int) cell(P p) => (((p.$1 / c).floor()).clamp(0, nx - 1), ((p.$2 / c).floor()).clamp(0, ny - 1));
  final pa = operatorPoint(a), pb = operatorPoint(b);
  final (ai, aj) = cell(pa);
  final (bi, bj) = cell(pb);
  final start = aj * nx + ai, goal = bj * nx + bi;
  block[start] = false;
  block[goal] = false;
  final dist = List<double>.filled(nx * ny, double.infinity);
  final prev = List<int>.filled(nx * ny, -1);
  double h(int k) => math.sqrt(math.pow((k % nx) - bi, 2) + math.pow(k ~/ nx - bj, 2));
  final heap = _MinHeap();
  dist[start] = 0;
  heap.push(h(start), start);
  const s2 = math.sqrt2;
  const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)];
  while (heap.isNotEmpty) {
    final k = heap.pop();
    if (k == goal) break;
    final i = k % nx, j = k ~/ nx, dk = dist[k];
    for (final (di, dj) in dirs) {
      final ni = i + di, nj = j + dj;
      if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
      final nk = nj * nx + ni;
      if (block[nk]) continue;
      if (di != 0 && dj != 0 && (block[j * nx + ni] || block[nj * nx + i])) continue;
      final nd = dk + (di != 0 && dj != 0 ? s2 : 1);
      if (nd < dist[nk]) {
        dist[nk] = nd;
        prev[nk] = k;
        heap.push(nd + h(nk), nk);
      }
    }
  }
  if (dist[goal].isInfinite) return null;
  final cells = <P>[];
  for (var k = goal; k != -1; k = prev[k]) {
    cells.add((((k % nx) + 0.5) * c, ((k ~/ nx) + 0.5) * c));
  }
  final ordered = cells.reversed.toList();
  bool free(P p, P q) {
    final n = (_dist(p, q) / (c / 2)).ceil();
    for (var s = 0; s <= n; s++) {
      final t = s / math.max(1, n);
      final (ci, cj) = cell((p.$1 + (q.$1 - p.$1) * t, p.$2 + (q.$2 - p.$2) * t));
      if (block[cj * nx + ci]) return false;
    }
    return true;
  }

  final pts = <P>[pa];
  var anchor = pa;
  for (var i = 1; i < ordered.length; i++) {
    if (!free(anchor, ordered[i])) {
      anchor = ordered[i - 1];
      pts.add(anchor);
    }
  }
  pts.add(pb);
  final out = [for (final p in pts) (r2(p.$1), r2(p.$2))];
  return (pts: out, length: polyLen(out));
}

class _MinHeap {
  final _f = <double>[];
  final _k = <int>[];
  bool get isNotEmpty => _f.isNotEmpty;
  void push(double f, int k) {
    _f.add(f);
    _k.add(k);
    var i = _f.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_f[p] <= _f[i]) break;
      _swap(p, i);
      i = p;
    }
  }

  int pop() {
    final top = _k[0];
    final lf = _f.removeLast(), lk = _k.removeLast();
    if (_f.isNotEmpty) {
      _f[0] = lf;
      _k[0] = lk;
      var i = 0;
      for (;;) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _f.length && _f[l] < _f[m]) m = l;
        if (r < _f.length && _f[r] < _f[m]) m = r;
        if (m == i) break;
        _swap(m, i);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final f = _f[a], k = _k[a];
    _f[a] = _f[b];
    _k[a] = _k[b];
    _f[b] = f;
    _k[b] = k;
  }
}

// ------------------------------------------------------------------------------- convoyeur
double railLength(Map r) {
  final pts = ptsOf(r);
  var l = 0.0;
  for (var i = 0; i < pts.length; i++) {
    l += _dist(pts[i], pts[(i + 1) % pts.length]);
  }
  return l;
}

Map<String, dynamic> newRail(String id, List<P> pts) =>
    {'id': id, 'kind': 'rail', 'pts': ptsJson(pts), 'height': 2.1, 'radius': 0.5, 'label': 'Convoyeur suspendu'};

// ------------------------------------------------------------------------------- édition
/// Repère suivant : M01, M02… (le plus grand numéro + 1).
String nextLabel(List<Map<String, dynamic>> els) {
  var max = 0;
  final re = RegExp(r'(\d+)\s*$');
  for (final e in els) {
    if (e['kind'] != 'machine') continue;
    final m = re.firstMatch('${e['label'] ?? ''}');
    if (m != null) max = math.max(max, int.parse(m.group(1)!));
  }
  return 'M${(max + 1).toString().padLeft(2, '0')}';
}

Map<String, dynamic> deepCopyEl(Map e) => (jsonDecode(jsonEncode(e)) as Map).cast<String, dynamic>();

/// Duplique les éléments (décalés ; une machine seule est posée à côté d'elle-même). Retourne les copies,
/// déjà ajoutées au plan.
List<Map<String, dynamic>> duplicateIds(List<Map<String, dynamic>> els, List<String> ids, String Function() newId) {
  final src = [for (final e in els) if (ids.contains(e['id'])) e];
  final out = <Map<String, dynamic>>[];
  for (final e in src) {
    var off = (0.5, 0.5);
    if (src.length == 1 && e['kind'] == 'machine') {
      final o = math.max(_n(e['w'], 1.2), 0.6) + 0.2;
      off = (math.sin(_n(e['rot']) * math.pi / 180)).abs() > 0.7 ? (0.0, o) : (o, 0.0);
    }
    final n = deepCopyEl(e)..['id'] = newId();
    moveEl(n, off.$1, off.$2);
    if (n['kind'] == 'machine') {
      n['label'] = nextLabel([...els, ...out]);
      n.remove('ws_id');
    }
    out.add(n);
  }
  els.addAll(out);
  return out;
}

/// Colle un presse-papiers (copies profondes) décalé de [offset] ; nouveaux identifiants et repères.
List<Map<String, dynamic>> pasteElements(List<Map<String, dynamic>> els, List<Map<String, dynamic>> clip, String Function() newId, {P offset = (0.5, 0.5)}) {
  final out = <Map<String, dynamic>>[];
  for (final e in clip) {
    final n = deepCopyEl(e)..['id'] = newId();
    moveEl(n, offset.$1, offset.$2);
    if (n['kind'] == 'machine') {
      n['label'] = nextLabel([...els, ...out]);
      n.remove('ws_id');
    }
    out.add(n);
  }
  els.addAll(out);
  return out;
}

void removeIds(List<Map<String, dynamic>> els, Iterable<String> ids) {
  final s = ids.toSet();
  els.removeWhere((e) => s.contains(e['id']));
}

/// Pivote machines et portes (pas en degrés, modulo 360).
void rotateIds(List<Map<String, dynamic>> els, List<String> ids, double deg) {
  for (final e in els) {
    if (ids.contains(e['id']) && (e['kind'] == 'machine' || e['kind'] == 'door')) {
      e['rot'] = (((_n(e['rot']) + deg).round() % 360) + 360) % 360;
    }
  }
}

/// Aligne les centres des machines sélectionnées : `y` = en ligne, `x` = en colonne.
bool alignIds(List<Map<String, dynamic>> els, List<String> ids, String axis) {
  final ms = [for (final e in els) if (ids.contains(e['id']) && e['kind'] == 'machine') e];
  if (ms.length < 2) return false;
  final v = r2(ms.fold<double>(0, (a, m) => a + _n(m[axis])) / ms.length);
  for (final m in ms) {
    m[axis] = v;
  }
  return true;
}

/// Répartit régulièrement les machines sélectionnées entre les deux extrêmes sur l'axe.
bool distributeIds(List<Map<String, dynamic>> els, List<String> ids, String axis) {
  final ms = [for (final e in els) if (ids.contains(e['id']) && e['kind'] == 'machine') e]
    ..sort((a, b) => _n(a[axis]).compareTo(_n(b[axis])));
  if (ms.length < 3) return false;
  final a = _n(ms.first[axis]), b = _n(ms.last[axis]);
  for (var i = 0; i < ms.length; i++) {
    ms[i][axis] = r2(a + (b - a) * i / (ms.length - 1));
  }
  return true;
}

// ------------------------------------------------------------------------------- poignées
enum HandleKind { resize, rotate, end1, end2, pt }

class PlanHandle {
  const PlanHandle(this.kind, this.p, [this.idx]);
  final HandleKind kind;
  final P p;
  final int? idx;
}

List<PlanHandle> handlesFor(Map e) {
  switch (e['kind']) {
    case 'machine':
    case 'door':
      final w = e['kind'] == 'door' ? _n(e['width'], 1) : _n(e['w'], 1.2);
      final d = e['kind'] == 'door' ? 0.3 : _n(e['d'], 0.6);
      final rot = _n(e['rot']);
      final (rx, ry) = rotV(w / 2, d / 2, rot);
      final (ux, uy) = rotV(0, -d / 2 - 0.5, rot);
      final x = _n(e['x']), y = _n(e['y']);
      return [PlanHandle(HandleKind.resize, (x + rx, y + ry)), PlanHandle(HandleKind.rotate, (x + ux, y + uy))];
    case 'pillar':
      return [PlanHandle(HandleKind.resize, (_n(e['x']) + _n(e['w'], 0.4) / 2, _n(e['y']) + _n(e['d'], 0.4) / 2))];
    case 'aisle':
    case 'zone':
      return [PlanHandle(HandleKind.resize, (_n(e['x']) + _n(e['w'], 1), _n(e['y']) + _n(e['h'], 1)))];
    case 'wall':
      return [PlanHandle(HandleKind.end1, (_n(e['x1']), _n(e['y1']))), PlanHandle(HandleKind.end2, (_n(e['x2']), _n(e['y2'])))];
    case 'dim':
    case 'rail':
      final pts = ptsOf(e);
      return [for (var i = 0; i < pts.length; i++) PlanHandle(HandleKind.pt, pts[i], i)];
  }
  return const [];
}

/// Applique le glisser d'une poignée (point courant [p], déjà aimanté si voulu) à partir de l'original.
void applyHandle(Map<String, dynamic> e, Map orig, PlanHandle h, P p, PlanSettings st, {bool freeRotate = false}) {
  final (mx, my) = p;
  switch (h.kind) {
    case HandleKind.rotate:
      final x = _n(orig['x']), y = _n(orig['y']);
      var a = math.atan2(mx - x, -(my - y)) * 180 / math.pi;
      if (!freeRotate) a = (a / 15).round() * 15;
      e['rot'] = ((a.round() % 360) + 360) % 360;
    case HandleKind.resize:
      switch (orig['kind']) {
        case 'machine':
          final (lx, ly) = rotV(mx - _n(orig['x']), my - _n(orig['y']), -_n(orig['rot']));
          e['w'] = math.max(0.2, st.snapV(lx.abs() * 2));
          e['d'] = math.max(0.2, st.snapV(ly.abs() * 2));
        case 'door':
          final (lx, _) = rotV(mx - _n(orig['x']), my - _n(orig['y']), -_n(orig['rot']));
          e['width'] = math.max(0.6, st.snapV(lx.abs() * 2));
        case 'pillar':
          e['w'] = math.max(0.1, st.snapV((mx - _n(orig['x'])).abs() * 2));
          e['d'] = math.max(0.1, st.snapV((my - _n(orig['y'])).abs() * 2));
        default:
          e['w'] = math.max(0.2, st.snapV(mx - _n(orig['x'])));
          e['h'] = math.max(0.2, st.snapV(my - _n(orig['y'])));
      }
    case HandleKind.end1:
      e['x1'] = r2(mx);
      e['y1'] = r2(my);
    case HandleKind.end2:
      e['x2'] = r2(mx);
      e['y2'] = r2(my);
    case HandleKind.pt:
      final pts = ptsOf(orig);
      if (h.idx != null && h.idx! < pts.length) {
        pts[h.idx!] = (mx, my);
        e['pts'] = ptsJson(pts);
      }
  }
}

// ------------------------------------------------------------------------------- calques
/// Calques de l'éditeur (par type d'élément). Stockés localement (`ui_layers`), jamais envoyés à l'API.
const planLayers = <String, String>{
  'zone': 'Zones',
  'aisle': 'Allées',
  'wall': 'Murs',
  'pillar': 'Poteaux',
  'door': 'Portes',
  'machine': 'Machines',
  'rail': 'Convoyeurs',
  'dim': 'Cotes',
};

class LayerState {
  LayerState({Set<String>? hidden, Set<String>? locked}) : hidden = hidden ?? {}, locked = locked ?? {};
  final Set<String> hidden;
  final Set<String> locked;
  factory LayerState.of(Map plan) {
    final l = (plan['ui_layers'] as Map?) ?? const {};
    return LayerState(hidden: {for (final x in (l['hidden'] as List? ?? const [])) '$x'}, locked: {for (final x in (l['locked'] as List? ?? const [])) '$x'});
  }
  Map<String, dynamic> toJson() => {'hidden': hidden.toList()..sort(), 'locked': locked.toList()..sort()};
  bool visible(Map e) => !hidden.contains(e['kind']);
  bool editable(Map e) => visible(e) && !locked.contains(e['kind']);
}

// ------------------------------------------------------------------------------- contrôles
class PlanIssue {
  const PlanIssue(this.level, this.msg, [this.ids = const []]);
  final String level; // err | warn | info
  final String msg;
  final List<String> ids;
}

/// Repères indicatifs (pas une norme) : machines qui se chevauchent ou sortent de la salle, allées
/// trop étroites, poste sans issue de secours, machine sans repère.
List<PlanIssue> checkPlan(Map plan) {
  final els = planElements(plan);
  final st = PlanSettings.of(plan);
  final out = <PlanIssue>[];
  final wm = _n(plan['width_m'], 30), lm = _n(plan['length_m'], 20);
  final ms = [for (final e in els) if (e['kind'] == 'machine') e];
  final obstacles = [for (final e in els) if (e['kind'] == 'pillar' || e['kind'] == 'wall') e];
  for (var i = 0; i < ms.length; i++) {
    final pa = elPoly(ms[i]);
    for (var j = i + 1; j < ms.length; j++) {
      if (overlap(pa, elPoly(ms[j]))) {
        out.add(PlanIssue('err', 'Machines ${ms[i]['label'] ?? ''} et ${ms[j]['label'] ?? ''} se chevauchent.', ['${ms[i]['id']}', '${ms[j]['id']}']));
      }
    }
    for (final o in obstacles) {
      if (overlap(pa, elPoly(o))) {
        out.add(PlanIssue('err', 'Machine ${ms[i]['label'] ?? ''} sur un ${o['kind'] == 'wall' ? 'mur' : 'poteau'}.', ['${ms[i]['id']}', '${o['id']}']));
      }
    }
    final (x0, y0, x1, y1) = polyBounds(pa);
    if (x0 < -0.01 || y0 < -0.01 || x1 > wm + 0.01 || y1 > lm + 0.01) {
      out.add(PlanIssue('warn', 'Machine ${ms[i]['label'] ?? ''} hors de la salle.', ['${ms[i]['id']}']));
    }
    if ('${ms[i]['label'] ?? ''}'.trim().isEmpty) out.add(PlanIssue('info', 'Une machine n\'a pas de repère.', ['${ms[i]['id']}']));
  }
  for (final a in els.where((e) => e['kind'] == 'aisle')) {
    final w = math.min(_n(a['w'], 1), _n(a['h'], 1));
    final min = a['main'] == true ? st.mainAisleMin : st.secondaryAisleMin;
    if (w + 1e-6 < min) {
      out.add(PlanIssue('warn', '${a['main'] == true ? 'Allée principale' : 'Passage'} de ${frNum(w)} m (< ${frNum(min)} m conseillés).', ['${a['id']}']));
    }
  }
  if (ms.isNotEmpty && !els.any((e) => e['kind'] == 'door' && e['exit'] == true)) {
    out.add(const PlanIssue('warn', 'Aucune issue de secours sur le plan (porte marquée « issue »).'));
  }
  return out;
}

// ------------------------------------------------------------------------------- DXF
/// Import DXF ASCII : LINE, LWPOLYLINE, POLYLINE/VERTEX → murs (épaisseur 0,15 m), y inversé, marge 0,5 m.
/// [unit] = auto | mm | cm | m (auto : `$INSUNITS` 4 = mm, 5 = cm, 6 = m ; sinon mm).
({List<Map<String, dynamic>> walls, double width, double length, String unit}) dxfToWalls(String text, String Function() newId, {String unit = 'auto'}) {
  final lines = const LineSplitter().convert(text);
  final pairs = <(int, String)>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = int.tryParse(lines[i].trim());
    if (code == null) throw const FormatException('Fichier DXF illisible (format ASCII attendu).');
    pairs.add((code, lines[i + 1].trim()));
  }
  var ins = 0;
  for (var i = 0; i + 1 < pairs.length; i++) {
    if (pairs[i].$1 == 9 && pairs[i].$2 == r'$INSUNITS') {
      ins = int.tryParse(pairs[i + 1].$2) ?? 0;
      break;
    }
  }
  final u = unit != 'auto' ? unit : (ins == 5 ? 'cm' : ins == 6 ? 'm' : 'mm');
  final k = u == 'mm' ? 0.001 : u == 'cm' ? 0.01 : 1.0;
  final segs = <(double, double, double, double)>[];
  // découpe en entités (code 0)
  final ents = <List<(int, String)>>[];
  var inEntities = false;
  for (var i = 0; i < pairs.length; i++) {
    final (c, v) = pairs[i];
    if (c == 2 && v == 'ENTITIES') inEntities = true;
    if (c == 0 && v == 'ENDSEC') inEntities = false;
    if (c == 0) ents.add([(c, v)]);
    if (c != 0 && ents.isNotEmpty) ents.last.add((c, v));
  }
  if (!pairs.any((p) => p.$1 == 2 && p.$2 == 'ENTITIES')) inEntities = true; // fichier minimal sans sections
  List<P>? poly;
  var polyClosed = false;
  for (final e in ents) {
    final type = e.first.$2;
    if (!inEntities && !['LINE', 'LWPOLYLINE', 'POLYLINE', 'VERTEX', 'SEQEND'].contains(type)) continue;
    double g(int code) => double.tryParse(e.firstWhere((p) => p.$1 == code, orElse: () => (code, '0')).$2) ?? 0;
    switch (type) {
      case 'LINE':
        segs.add((g(10), g(20), g(11), g(21)));
      case 'LWPOLYLINE':
        final xs = [for (final p in e) if (p.$1 == 10) double.tryParse(p.$2) ?? 0];
        final ys = [for (final p in e) if (p.$1 == 20) double.tryParse(p.$2) ?? 0];
        final n = math.min(xs.length, ys.length);
        for (var i = 0; i + 1 < n; i++) {
          segs.add((xs[i], ys[i], xs[i + 1], ys[i + 1]));
        }
        if ((g(70).toInt() & 1) == 1 && n > 2) segs.add((xs[n - 1], ys[n - 1], xs[0], ys[0]));
      case 'POLYLINE':
        poly = [];
        polyClosed = (g(70).toInt() & 1) == 1;
      case 'VERTEX':
        poly?.add((g(10), g(20)));
      case 'SEQEND':
        final p = poly;
        if (p != null) {
          for (var i = 0; i + 1 < p.length; i++) {
            segs.add((p[i].$1, p[i].$2, p[i + 1].$1, p[i + 1].$2));
          }
          if (polyClosed && p.length > 2) segs.add((p.last.$1, p.last.$2, p.first.$1, p.first.$2));
        }
        poly = null;
    }
  }
  if (segs.isEmpty) throw const FormatException('Aucune ligne (LINE / LWPOLYLINE) trouvée dans le DXF.');
  if (segs.length > 3000) throw FormatException('DXF trop détaillé (${segs.length} segments, 3000 max) : exportez seulement le calque des murs.');
  final xs = [for (final s in segs) ...[s.$1, s.$3]], ys = [for (final s in segs) ...[s.$2, s.$4]];
  final minX = xs.reduce(math.min), maxY = ys.reduce(math.max);
  final walls = <Map<String, dynamic>>[];
  for (final (x1, y1, x2, y2) in segs) {
    final w = {
      'id': newId(),
      'kind': 'wall',
      'thickness': 0.15,
      'x1': r2((x1 - minX) * k + 0.5),
      'y1': r2((maxY - y1) * k + 0.5),
      'x2': r2((x2 - minX) * k + 0.5),
      'y2': r2((maxY - y2) * k + 0.5),
    };
    if (_dist((_n(w['x1']), _n(w['y1'])), (_n(w['x2']), _n(w['y2']))) >= 0.05) walls.add(w);
  }
  return (
    walls: walls,
    width: r2((xs.reduce(math.max) - minX) * k + 1),
    length: r2((maxY - ys.reduce(math.min)) * k + 1),
    unit: u,
  );
}

// ------------------------------------------------------------------------------- historique
/// Annuler / rétablir (100 étapes) : instantanés de la partie éditable du plan (sans l'image de fond).
class PlanHistory {
  PlanHistory({this.limit = 100});
  final int limit;
  final _undo = <String>[];
  final _redo = <String>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;

  static String snapshot(Map plan) {
    final bg = (plan['background_local'] as Map?);
    return jsonEncode({
      'elements': plan['elements'],
      'width_m': plan['width_m'],
      'length_m': plan['length_m'],
      'settings': plan['settings'],
      'bg': bg == null ? null : {for (final e in bg.entries) if (e.key != 'data') e.key: e.value},
      'has_bg': bg != null,
    });
  }

  static void restore(Map<String, dynamic> plan, String snap) {
    final m = jsonDecode(snap) as Map<String, dynamic>;
    plan['elements'] = (m['elements'] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    plan['width_m'] = m['width_m'];
    plan['length_m'] = m['length_m'];
    plan['settings'] = m['settings'];
    final bg = plan['background_local'] as Map?;
    final meta = m['bg'] as Map?;
    // l'image elle-même n'est pas historisée : seuls sa position / échelle / opacité le sont
    if (bg != null && meta != null) plan['background_local'] = {...bg, ...meta, 'data': bg['data']};
  }

  /// Enregistre l'état AVANT une modification.
  void push(String before) {
    if (_undo.isNotEmpty && _undo.last == before) return;
    _undo.add(before);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  bool undo(Map<String, dynamic> plan) {
    if (_undo.isEmpty) return false;
    _redo.add(snapshot(plan));
    restore(plan, _undo.removeLast());
    return true;
  }

  bool redo(Map<String, dynamic> plan) {
    if (_redo.isEmpty) return false;
    _undo.add(snapshot(plan));
    restore(plan, _redo.removeLast());
    return true;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
