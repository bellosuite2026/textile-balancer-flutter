/// Moteur 3D logiciel minimal (Dart pur + vector_math) pour le jumeau 3D et la vue 3D du plan.
///
/// Pourquoi « maison » : il tourne à l'identique sur Web (CanvasKit/skwasm), Windows, Linux et Android
/// sans plugin ni drapeau GPU, et dans `flutter test`. La scène est une liste de triangles colorés en
/// coordonnées monde (mètres : x = x du plan, y = hauteur, z = y du plan). La projection trie les
/// triangles du plus loin au plus proche (algorithme du peintre), élimine les faces arrière, applique un
/// ombrage plat (lumière directionnelle + ambiante) et rend des tableaux prêts pour `Canvas.drawVertices`.
///
/// Construction des scènes depuis un plan d'atelier / l'état du jumeau : voir [buildPlanScene] et
/// [buildTwinScene].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

import 'twin.dart' show BundleView;
import 'workshop.dart';

double _n(Object? v, [double d = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? d);

// ------------------------------------------------------------------------------- géométrie
class Tri3 {
  Tri3(this.a, this.b, this.c, this.color, {this.shade = true, this.tag});
  final Vector3 a, b, c;
  final int color; // ARGB
  final bool shade;
  final String? tag; // identifiant d'objet (machine, station…) pour le toucher
}

class Mesh3 {
  final tris = <Tri3>[];
  int get length => tris.length;

  /// Ajoute un triangle orienté vers l'extérieur de [center] (normale sortante).
  void _tri(Vector3 a, Vector3 b, Vector3 c, int color, Vector3? center, {bool shade = true, String? tag}) {
    if (center != null) {
      final n = (b - a).cross(c - a);
      final mid = (a + b + c) / 3;
      if (n.dot(mid - center) < 0) {
        tris.add(Tri3(a, c, b, color, shade: shade, tag: tag));
        return;
      }
    }
    tris.add(Tri3(a, b, c, color, shade: shade, tag: tag));
  }

  void quad(Vector3 a, Vector3 b, Vector3 c, Vector3 d, int color, {Vector3? center, bool shade = true, String? tag}) {
    _tri(a, b, c, color, center, shade: shade, tag: tag);
    _tri(a, c, d, color, center, shade: shade, tag: tag);
  }

  /// Pavé centré en (cx, cz) au sol [y0], dimensions w (x local) × d (z local) × h, rotation horaire (°).
  void box(double cx, double cz, double y0, double w, double d, double h, double rotDeg, int color, {int? topColor, String? tag}) {
    final a = rotDeg * math.pi / 180, c = math.cos(a), s = math.sin(a);
    Vector3 p(double lx, double ly, double lz) => Vector3(cx + lx * c - lz * s, y0 + ly, cz + lx * s + lz * c);
    final hw = w / 2, hd = d / 2;
    final b = [p(-hw, 0, -hd), p(hw, 0, -hd), p(hw, 0, hd), p(-hw, 0, hd)];
    final t = [p(-hw, h, -hd), p(hw, h, -hd), p(hw, h, hd), p(-hw, h, hd)];
    final ctr = Vector3(cx, y0 + h / 2, cz);
    quad(t[0], t[1], t[2], t[3], topColor ?? color, center: ctr, tag: tag);
    if (y0 > 1e-3) quad(b[0], b[1], b[2], b[3], color, center: ctr, tag: tag); // posé au sol : dessous jamais vu
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      quad(b[i], b[j], t[j], t[i], color, center: ctr, tag: tag);
    }
  }

  /// Cylindre vertical (prisme à [seg] côtés).
  void cylinder(double cx, double cz, double y0, double r, double h, int color, {int seg = 8, int? topColor, String? tag}) {
    final ctr = Vector3(cx, y0 + h / 2, cz);
    final ring = [for (var i = 0; i < seg; i++) (cx + r * math.cos(2 * math.pi * i / seg), cz + r * math.sin(2 * math.pi * i / seg))];
    final topC = Vector3(cx, y0 + h, cz);
    for (var i = 0; i < seg; i++) {
      final (x1, z1) = ring[i];
      final (x2, z2) = ring[(i + 1) % seg];
      quad(Vector3(x1, y0, z1), Vector3(x2, y0, z2), Vector3(x2, y0 + h, z2), Vector3(x1, y0 + h, z1), color, center: ctr, tag: tag);
      _tri(topC, Vector3(x1, y0 + h, z1), Vector3(x2, y0 + h, z2), topColor ?? color, ctr, tag: tag);
    }
  }

  /// Sphère basse définition (octaèdre subdivisé une fois).
  void sphere(double cx, double cy, double cz, double r, int color, {String? tag, bool smooth = true}) {
    final ctr = Vector3(cx, cy, cz);
    final v = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)];
    const faces = [[0, 2, 4], [4, 2, 1], [1, 2, 5], [5, 2, 0], [0, 4, 3], [4, 1, 3], [1, 5, 3], [5, 0, 3]];
    for (final f in faces) {
      final a = v[f[0]], b = v[f[1]], c = v[f[2]];
      if (!smooth) {
        _tri(ctr + a * r, ctr + b * r, ctr + c * r, color, ctr, tag: tag);
        continue;
      }
      final ab = (a + b).normalized(), bc = (b + c).normalized(), ca = (c + a).normalized();
      for (final t in [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]) {
        _tri(ctr + t[0] * r, ctr + t[1] * r, ctr + t[2] * r, color, ctr, tag: tag);
      }
    }
  }

  /// Polygone plat au sol (zones, allées, anneaux) à la hauteur [y].
  void flat(List<(double, double)> poly, double y, int color, {bool shade = false}) {
    if (poly.length < 3) return;
    for (var i = 1; i + 1 < poly.length; i++) {
      tris.add(Tri3(Vector3(poly[0].$1, y, poly[0].$2), Vector3(poly[i].$1, y, poly[i].$2), Vector3(poly[i + 1].$1, y, poly[i + 1].$2), color,
          shade: shade));
    }
  }

  /// Segment épais vertical (mur) entre deux points du sol.
  void wall(double x1, double z1, double x2, double z2, double thickness, double h, int color) {
    final dx = x2 - x1, dz = z2 - z1, l = math.sqrt(dx * dx + dz * dz);
    if (l < 1e-6) return;
    box((x1 + x2) / 2, (z1 + z2) / 2, 0, l + thickness, math.max(0.05, thickness), h, math.atan2(dz, dx) * 180 / math.pi, color);
  }

  /// Tube horizontal (convoyeur) entre deux points à la hauteur [y].
  void beam(double x1, double z1, double x2, double z2, double y, double size, int color) {
    final dx = x2 - x1, dz = z2 - z1, l = math.sqrt(dx * dx + dz * dz);
    if (l < 1e-6) return;
    box((x1 + x2) / 2, (z1 + z2) / 2, y - size / 2, l, size, size, math.atan2(dz, dx) * 180 / math.pi, color);
  }
}

// ------------------------------------------------------------------------------- caméra
class OrbitCamera {
  OrbitCamera({required this.target, this.yaw = -0.6, this.pitch = 0.75, this.distance = 25, this.fovDeg = 45});
  Vector3 target;
  double yaw; // rad, autour de l'axe vertical
  double pitch; // rad, 0 = horizon, π/2 = vue de dessus
  double distance;
  double fovDeg;

  OrbitCamera copy() => OrbitCamera(target: target.clone(), yaw: yaw, pitch: pitch, distance: distance, fovDeg: fovDeg);

  Vector3 get eye => target +
      Vector3(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)) * distance;

  void orbit(double dYaw, double dPitch) {
    yaw += dYaw;
    pitch = (pitch + dPitch).clamp(0.08, math.pi / 2 - 0.02);
  }

  void zoom(double factor) => distance = (distance * factor).clamp(2.0, 400.0);

  /// Déplace la cible dans le plan du sol (dx, dy en pixels, [scale] = mètres par pixel approx.).
  void pan(double dx, double dy, double scale) {
    final right = Vector3(math.cos(yaw), 0, -math.sin(yaw));
    final fwd = Vector3(-math.sin(yaw), 0, -math.cos(yaw));
    target += right * (-dx * scale) + fwd * (dy * scale);
  }

  /// Cadre une boîte au sol (x0, z0, x1, z1).
  void frame(double x0, double z0, double x1, double z1) {
    target = Vector3((x0 + x1) / 2, 0, (z0 + z1) / 2);
    final span = math.max(4.0, math.max(x1 - x0, z1 - z0));
    distance = span * 0.62 / math.tan(fovDeg * math.pi / 360);
    distance = distance.clamp(3.0, 400.0);
  }

  Matrix4 viewProj(double aspect) {
    final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
    final proj = makePerspectiveMatrix(fovDeg * math.pi / 180, aspect, 0.1, 1000);
    return proj * view;
  }
}

// ------------------------------------------------------------------------------- rendu
class Projected {
  Projected(this.positions, this.colors, this.triangles, this.tags, this.centers);
  final Float32List positions; // x, y écran par sommet
  final Int32List colors; // ARGB par sommet
  final int triangles;
  final List<String?> tags; // par triangle, dans l'ordre de dessin
  final List<(double, double)> centers; // centre écran de chaque triangle dessiné
}

/// Projette et trie la scène pour un écran [width]×[height].
Projected projectScene(List<Mesh3> meshes, OrbitCamera cam, double width, double height, {Vector3? light}) {
  final vp = cam.viewProj(width / math.max(1, height));
  final eye = cam.eye;
  final l = (light ?? Vector3(-0.4, 1, -0.3)).normalized();
  final items = <(double, Tri3, List<double>, double)>[]; // profondeur, tri, xy, lumière
  final v4 = Vector4.zero();
  for (final m in meshes) {
    for (final t in m.tris) {
      final n = (t.b - t.a).cross(t.c - t.a);
      final nl = n.length;
      if (nl < 1e-12) continue;
      final mid = (t.a + t.b + t.c) / 3;
      // face arrière : invisible pour les volumes ; les surfaces plates restent visibles des deux côtés
      if (t.shade && n.dot(eye - mid) <= 0) continue;
      final xy = <double>[];
      var depth = 0.0;
      var ok = true;
      for (final p in [t.a, t.b, t.c]) {
        v4.setValues(p.x, p.y, p.z, 1);
        vp.transform(v4);
        if (v4.w < 0.1) {
          ok = false;
          break;
        }
        xy
          ..add((v4.x / v4.w * 0.5 + 0.5) * width)
          ..add((1 - (v4.y / v4.w * 0.5 + 0.5)) * height);
        depth += v4.w;
      }
      if (!ok) continue;
      final lit = t.shade ? 0.55 + 0.45 * math.max(0.0, (n / nl).dot(l)) : 1.0;
      items.add((depth, t, xy, lit));
    }
  }
  items.sort((a, b) => b.$1.compareTo(a.$1));
  final pos = Float32List(items.length * 6);
  final cols = Int32List(items.length * 3);
  final tags = <String?>[];
  final centers = <(double, double)>[];
  for (var i = 0; i < items.length; i++) {
    final (_, t, xy, lit) = items[i];
    for (var k = 0; k < 6; k++) {
      pos[i * 6 + k] = xy[k];
    }
    final c = shadeColor(t.color, lit);
    cols[i * 3] = c;
    cols[i * 3 + 1] = c;
    cols[i * 3 + 2] = c;
    tags.add(t.tag);
    centers.add(((xy[0] + xy[2] + xy[4]) / 3, (xy[1] + xy[3] + xy[5]) / 3));
  }
  return Projected(pos, cols, items.length, tags, centers);
}

int shadeColor(int argb, double k) {
  final a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  int f(int c) => (c * k).round().clamp(0, 255);
  return (a << 24) | (f(r) << 16) | (f(g) << 8) | f(b);
}

/// Point écran d'un point monde (pour les étiquettes), `null` s'il est derrière la caméra.
(double, double)? projectPoint(Vector3 p, OrbitCamera cam, double width, double height) {
  final v = Vector4(p.x, p.y, p.z, 1);
  cam.viewProj(width / math.max(1, height)).transform(v);
  if (v.w < 0.1) return null;
  return ((v.x / v.w * 0.5 + 0.5) * width, (1 - (v.y / v.w * 0.5 + 0.5)) * height);
}

/// Élément touché à l'écran (le triangle dessiné en dernier qui contient le point).
String? pickTag(Projected pr, double x, double y) {
  for (var i = pr.triangles - 1; i >= 0; i--) {
    final tag = pr.tags[i];
    if (tag == null) continue;
    final p = pr.positions;
    final ax = p[i * 6], ay = p[i * 6 + 1], bx = p[i * 6 + 2], by = p[i * 6 + 3], cx = p[i * 6 + 4], cy = p[i * 6 + 5];
    final d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by);
    final d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy);
    final d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay);
    final neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
    if (!(neg && pos)) return tag;
  }
  return null;
}

// ------------------------------------------------------------------------------- couleurs
const _floor = 0xFFE7E5E0;
const _wallC = 0xFFB8BEC7;
const _pillarC = 0xFF6B7280;
const _tableC = 0xFFF8FAFC;
const _legC = 0xFF94A3B8;
const _railC = 0xFF7B4FA0;
const _skin = 0xFFE0AC69;
const _hair = 0xFF3F2A1D;
const _chair = 0xFF334155;
const bundleColor = 0xFFEA580C;
const bottleneckColor = 0xFFDC2626;

const zoneArgb = <String, int>{
  'coupe': 0xFFFDE68A,
  'preparation': 0xFFBFDBFE,
  'montage': 0xFFBBF7D0,
  'finition': 0xFFDDD6FE,
  'repassage': 0xFFFBCFE8,
  'controle': 0xFFFED7AA,
  'stock': 0xFFE5E7EB,
  'expedition': 0xFFCCFBF1,
};

int categoryArgb(String category) => switch (category) {
      'piqure' => 0xFF2563EB,
      'surjet' => 0xFF7C3AED,
      'auto' => 0xFF0891B2,
      'coupe' => 0xFFB45309,
      'repassage' => 0xFFDB2777,
      'controle' => 0xFFEA580C,
      _ => 0xFF64748B,
    };

// ------------------------------------------------------------------------------- objets
/// Machine : table + pieds + tête selon la forme du catalogue (détaillé) ou simple pavé coloré.
void addMachine(Mesh3 m, Map e, {bool detailed = true, bool hot = false, String? tag}) {
  final spec = machineCatalog['${e['type']}'];
  final x = _n(e['x']), z = _n(e['y']), w = _n(e['w'], spec?.w ?? 1.2), d = _n(e['d'], spec?.d ?? 0.6), rot = _n(e['rot']);
  final down = e['status'] == 'panne';
  final col = hot ? bottleneckColor : (down ? 0xFF9CA3AF : categoryArgb(spec?.category ?? ''));
  final shape = spec?.shape ?? 'table';
  if (!detailed) {
    m.box(x, z, 0, w, d, 0.75, rot, _tableC, topColor: col, tag: tag);
    return;
  }
  final a = rot * math.pi / 180, c = math.cos(a), s = math.sin(a);
  (double, double) at(double lx, double lz) => (x + lx * c - lz * s, z + lx * s + lz * c);
  switch (shape) {
    case 'rack':
    case 'pallet':
    case 'cart':
      m.box(x, z, 0, w, d, shape == 'pallet' ? 0.15 : 1.4, rot, col, tag: tag);
      return;
    case 'press':
    case 'fusing':
    case 'detector':
    case 'spreader':
    case 'cutter_cad':
    case 'bandknife':
    case 'mannequin':
    case 'conveyor':
      m.box(x, z, 0, w, d, 0.9, rot, 0xFFCBD5E1, topColor: col, tag: tag);
      final (hx, hz) = at(0, -d * 0.15);
      m.box(hx, hz, 0.9, w * 0.6, d * 0.5, 0.45, rot, col, tag: tag);
      return;
    default:
      break;
  }
  // table de couture / de travail
  const top = 0.74, thick = 0.04;
  m.box(x, z, top - thick, w, d, thick, rot, _tableC, tag: tag);
  // piètement : deux flancs (moins de triangles que quatre pieds, même silhouette)
  for (final lx in [-w / 2 + 0.04, w / 2 - 0.04]) {
    final (px, pz) = at(lx, 0);
    m.box(px, pz, 0, 0.04, d - 0.1, top - thick, rot, _legC, tag: tag);
  }
  if (shape.startsWith('sew_')) {
    // tête de machine : socle + colonne + bras
    final (bx, bz) = at(w * 0.05, -d * 0.05);
    m.box(bx, bz, top, 0.42, 0.2, 0.06, rot, col, tag: tag);
    final (cx2, cz2) = at(w * 0.05 + 0.16, -d * 0.05);
    m.box(cx2, cz2, top + 0.06, 0.1, 0.16, 0.28, rot, col, tag: tag);
    final (ax, az) = at(w * 0.05 + 0.02, -d * 0.05);
    m.box(ax, az, top + 0.28, 0.4, 0.14, 0.09, rot, col, tag: tag);
    final (nx, nz) = at(w * 0.05 - 0.17, -d * 0.05);
    m.box(nx, nz, top + 0.12, 0.06, 0.1, 0.16, rot, col, tag: tag);
  } else if (shape == 'ironing') {
    final (ix, iz) = at(0, 0);
    m.box(ix, iz, top, 0.22, 0.12, 0.08, rot, col, tag: tag);
  } else {
    // table de contrôle / emballage : un repère coloré sur le plateau
    m.box(x, z, top, w * 0.5, d * 0.4, 0.02, rot, col, tag: tag);
  }
}

/// Opératrice assise (ou debout) devant la machine.
void addOperator(Mesh3 m, double x, double z, double facingDeg, {required bool working, bool detailed = true, double t = 0, String? tag}) {
  final shirt = working ? 0xFF16A34A : 0xFF94A3B8;
  if (!detailed) {
    m.cylinder(x, z, 0, 0.18, 1.2, shirt, seg: 6, tag: tag);
    m.sphere(x, 1.35, z, 0.13, _skin, tag: tag);
    return;
  }
  final a = facingDeg * math.pi / 180, c = math.cos(a), s = math.sin(a);
  (double, double) at(double lx, double lz) => (x + lx * c - lz * s, z + lx * s + lz * c);
  // chaise
  final (sx, sz) = at(0, 0.12);
  m.box(sx, sz, 0.42, 0.42, 0.42, 0.05, facingDeg, _chair);
  m.box(sx, sz, 0, 0.05, 0.05, 0.42, facingDeg, _chair);
  final (bx, bz) = at(0, 0.32);
  m.box(bx, bz, 0.47, 0.4, 0.05, 0.45, facingDeg, _chair);
  // corps
  m.cylinder(x, z, 0.47, 0.17, 0.55, shirt, seg: 6, tag: tag);
  m.sphere(x, 1.17, z, 0.12, _skin, tag: tag, smooth: false);
  m.box(x, z + 0.03, 1.2, 0.2, 0.18, 0.08, facingDeg, _hair, tag: tag);
  // jambes vers la machine
  final (lx, lz) = at(0, -0.2);
  m.box(lx, lz, 0.42, 0.3, 0.34, 0.12, facingDeg, 0xFF1F2937);
  // bras : en mouvement quand elle travaille
  final k = working ? 0.05 * math.sin(t * 9) : 0;
  for (final side in [-1.0, 1.0]) {
    final (ax, az) = at(side * 0.2, -0.22 + side * k);
    m.box(ax, az, 0.78, 0.07, 0.3, 0.07, facingDeg, shirt, tag: tag);
  }
}

/// Plan d'atelier en 3D : sol, zones, allées, murs, poteaux, portes, machines, convoyeurs.
Mesh3 buildPlanScene(Map plan, {bool detailed = true, Set<String> hotMachines = const {}, bool withOperators = false, Set<String> hiddenKinds = const {}}) {
  final m = Mesh3();
  final w = _n(plan['width_m'], 30), l = _n(plan['length_m'], 20);
  m.flat([(0, 0), (w, 0), (w, l), (0, l)], 0, _floor);
  final wallH = _n((plan['settings'] as Map?)?['wall_height'], 3).clamp(1.0, 8.0) * (detailed ? 1 : 0.4);
  for (final e in planElements(plan)) {
    final k = '${e['kind']}';
    if (hiddenKinds.contains(k)) continue;
    switch (k) {
      case 'zone':
        m.flat([for (final (x, y) in _rect(e)) (x, y)], 0.005, zoneArgb['${e['zone']}'] ?? 0xFFE0F2FE);
      case 'aisle':
        m.flat([for (final (x, y) in _rect(e)) (x, y)], 0.01, e['main'] == true ? 0xFFFDE047 : 0xFFFEF9C3);
      case 'wall':
        m.wall(_n(e['x1']), _n(e['y1']), _n(e['x2']), _n(e['y2']), _n(e['thickness'], 0.2), wallH.toDouble(), _wallC);
      case 'pillar':
        m.box(_n(e['x']), _n(e['y']), 0, _n(e['w'], 0.4), _n(e['d'], 0.4), wallH.toDouble(), 0, _pillarC);
      case 'door':
        final ww = _n(e['width'], 1), rot = _n(e['rot']);
        m.flat(_rot(_n(e['x']), _n(e['y']), ww, 0.3, rot), 0.02, e['exit'] == true ? 0xFF16A34A : 0xFF8A8F98);
      case 'machine':
        addMachine(m, e, detailed: detailed, hot: hotMachines.contains(e['id']), tag: 'm:${e['id']}');
        if (withOperators && (machineCatalog['${e['type']}']?.isWorkstation ?? true) && e['status'] != 'panne') {
          final rot = _n(e['rot']);
          final a = rot * math.pi / 180;
          final od = _n(e['d'], 0.6) / 2 + 0.38;
          addOperator(m, _n(e['x']) - od * math.sin(a), _n(e['y']) + od * math.cos(a), rot, working: false, detailed: detailed);
        }
      case 'rail':
        final pts = [for (final p in (e['pts'] as List? ?? const [])) if (p is List && p.length >= 2) (_n(p[0]), _n(p[1]))];
        final h = _n(e['height'], 2.1);
        for (var i = 0; i < pts.length; i++) {
          final a = pts[i], b = pts[(i + 1) % pts.length];
          m.beam(a.$1, a.$2, b.$1, b.$2, h, 0.08, _railC);
        }
        if (detailed) {
          for (final p in pts) {
            m.cylinder(p.$1, p.$2, h, 0.02, wallH - h > 0 ? (wallH - h).toDouble() : 0.5, _legC, seg: 4);
          }
        }
    }
  }
  return m;
}

List<(double, double)> _rect(Map e) {
  final x = _n(e['x']), y = _n(e['y']), w = _n(e['w'], 1), h = _n(e['h'], 1);
  return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)];
}

List<(double, double)> _rot(double cx, double cy, double w, double d, double deg) {
  final a = deg * math.pi / 180, c = math.cos(a), s = math.sin(a);
  return [
    for (final (lx, ly) in [(-w / 2, -d / 2), (w / 2, -d / 2), (w / 2, d / 2), (-w / 2, d / 2)]) (cx + lx * c - ly * s, cy + lx * s + ly * c),
  ];
}

// ------------------------------------------------------------------------------- jumeau 3D
/// Entrées du jumeau 3D (mêmes données que le jumeau 2D `TwinPainter`).
class Twin3DInput {
  const Twin3DInput({
    required this.order,
    required this.positions,
    required this.bundles,
    required this.workersByStation,
    this.bottleneck,
    this.plan,
    this.assignment = const {},
    this.bundleSize = 10,
  });
  final List<int> order;
  final Map<String, dynamic> positions; // {"<station>": {x, y}} en mètres
  final List<BundleView> bundles;
  final Map<int, List<String>> workersByStation;
  final int? bottleneck;
  final Map<String, dynamic>? plan; // plan d'atelier si la ligne est posée dessus
  final Map<String, List<String>> assignment; // station → machines du plan
  final int bundleSize;

  (double, double) pos(int sid) {
    final p = positions['$sid'] as Map?;
    return (_n(p?['x']), _n(p?['y']));
  }

  /// Emprise au sol (x0, z0, x1, z1).
  (double, double, double, double) bounds() {
    if (plan != null) return (0, 0, _n(plan!['width_m'], 30), _n(plan!['length_m'], 20));
    var x0 = double.infinity, z0 = double.infinity, x1 = -double.infinity, z1 = -double.infinity;
    for (final s in order) {
      final (x, z) = pos(s);
      x0 = math.min(x0, x);
      z0 = math.min(z0, z);
      x1 = math.max(x1, x);
      z1 = math.max(z1, z);
    }
    if (x0.isInfinite) return (0, 0, 4, 4);
    return (x0 - 1.5, z0 - 1.5, x1 + 1.5, z1 + 1.5);
  }
}

/// Décor statique du jumeau : plan (s'il existe) ou postes génériques, goulot en rouge.
Mesh3 buildTwinStatic(Twin3DInput inp, {bool detailed = true}) {
  final hot = <String>{};
  if (inp.bottleneck != null) hot.addAll(inp.assignment['${inp.bottleneck}'] ?? const []);
  if (inp.plan != null) {
    final m = buildPlanScene(inp.plan!, detailed: detailed, hotMachines: hot);
    // stations virtuelles (hors plan) : poste générique
    final placed = {for (final e in inp.assignment.entries) if (e.value.isNotEmpty) e.key};
    for (final sid in inp.order) {
      if (placed.contains('$sid')) continue;
      final (x, z) = inp.pos(sid);
      addMachine(m, {'type': 'piqueuse_plate', 'x': x, 'y': z, 'rot': 0}, detailed: detailed, hot: sid == inp.bottleneck, tag: 's:$sid');
    }
    _bottleneckRing(m, inp);
    return m;
  }
  final m = Mesh3();
  final (x0, z0, x1, z1) = inp.bounds();
  m.flat([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], 0, _floor);
  for (var i = 0; i + 1 < inp.order.length; i++) {
    final (ax, az) = inp.pos(inp.order[i]);
    final (bx, bz) = inp.pos(inp.order[i + 1]);
    final dx = bx - ax, dz = bz - az, len = math.sqrt(dx * dx + dz * dz);
    if (len > 1e-6) {
      final nx = -dz / len * 0.04, nz = dx / len * 0.04;
      m.flat([(ax + nx, az + nz), (bx + nx, bz + nz), (bx - nx, bz - nz), (ax - nx, az - nz)], 0.01, 0xFFCBD5E1);
    }
  }
  for (final sid in inp.order) {
    final (x, z) = inp.pos(sid);
    addMachine(m, {'type': 'piqueuse_plate', 'x': x, 'y': z, 'rot': 0}, detailed: detailed, hot: sid == inp.bottleneck, tag: 's:$sid');
  }
  _bottleneckRing(m, inp);
  return m;
}

void _bottleneckRing(Mesh3 m, Twin3DInput inp) {
  final b = inp.bottleneck;
  if (b == null || !inp.order.contains(b)) return;
  final (x, z) = inp.pos(b);
  const seg = 20, r0 = 1.0, r1 = 1.2;
  for (var i = 0; i < seg; i++) {
    final a0 = 2 * math.pi * i / seg, a1 = 2 * math.pi * (i + 1) / seg;
    m.flat([
      (x + r0 * math.cos(a0), z + r0 * math.sin(a0)),
      (x + r1 * math.cos(a0), z + r1 * math.sin(a0)),
      (x + r1 * math.cos(a1), z + r1 * math.sin(a1)),
      (x + r0 * math.cos(a1), z + r0 * math.sin(a1)),
    ], 0.02, bottleneckColor);
  }
}

/// Partie animée à l'instant [t] : opératrices (au travail / disponibles), paquets en file, en travail
/// et en transit.
Mesh3 buildTwinDynamic(Twin3DInput inp, {bool detailed = true, double t = 0}) {
  final m = Mesh3();
  final queue = <int, int>{};
  final working = <int, Set<String>>{};
  for (final b in inp.bundles) {
    if (b.state == 'queue') queue[b.station] = (queue[b.station] ?? 0) + 1;
    if (b.state == 'work') working.putIfAbsent(b.station, () => {}).add(b.worker ?? '?');
  }
  for (final sid in inp.order) {
    final (x, z) = inp.pos(sid);
    final ws = inp.workersByStation[sid] ?? const <String>[];
    for (var k = 0; k < ws.length; k++) {
      final ox = x + (k - (ws.length - 1) / 2) * 0.75;
      final on = working[sid]?.contains(ws[k]) ?? false;
      addOperator(m, ox, z + 0.72, 0, working: on, detailed: detailed, t: t + k, tag: 's:$sid');
    }
    // file d'encours : piles de paquets à gauche du poste
    final q = queue[sid] ?? 0;
    final stacks = math.min(q, 12);
    for (var k = 0; k < stacks; k++) {
      final col = k ~/ 4, lvl = k % 4;
      m.box(x - 0.85 - col * 0.3, z - 0.1, lvl * 0.13, 0.26, 0.3, 0.12, 0, q > 4 ? 0xFFD97706 : 0xFF3B82F6);
    }
    if ((working[sid]?.isNotEmpty ?? false)) {
      m.box(x - 0.2, z + 0.12, 0.74, 0.22, 0.18, 0.06, 0, bundleColor);
    }
  }
  for (final b in inp.bundles) {
    if (b.state != 'transit' || b.toStation == null) continue;
    final (ax, az) = inp.pos(b.station);
    final (bx, bz) = inp.pos(b.toStation!);
    final px = ax + (bx - ax) * b.progress, pz = az + (bz - az) * b.progress;
    final hop = 0.9 + 0.25 * math.sin(b.progress * math.pi);
    m.box(px, pz, hop, 0.24, 0.3, 0.12, 0, bundleColor);
  }
  return m;
}
