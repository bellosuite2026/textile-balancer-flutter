/// Plan d'atelier (cartographie) : géométrie pure, sans effet sur l'équilibrage.
///
/// Format identique à l'API (`WorkshopPlanIn`, `routes_workshop.py`) : mètres, x vers la droite,
/// y vers le bas, rotation horaire en degrés. Éléments :
/// `wall {x1,y1,x2,y2,thickness}`, `pillar {x,y,w,d}`, `door {x,y,width,rot}`,
/// `aisle {x,y,w,h,main}`, `zone {x,y,w,h,zone,name}`,
/// `machine {type,x,y,w,d,rot,label,status,ws_id}` (x, y = centre).
///
/// Association calcul ↔ plan (`auto_assign` simplifié) : liaison manuelle d'abord, puis machine du
/// même type la plus proche de la station précédente, puis famille voisine (signalée), sinon station
/// « virtuelle » placée sous le plan. Distances entre stations : parcours en équerre (allées
/// orthogonales) ; le serveur calcule, lui, le plus court chemin A* autour des obstacles.
library;

import 'dart:math' as math;

import 'pyfmt.dart';
import 'workshop_catalog.dart';

export 'workshop_catalog.dart';

const double virtualSpacingM = 1.6;

double _n(Object? v, [double d = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? d);

String normType(String? s) {
  const accents = {'à': 'a', 'â': 'a', 'ä': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'î': 'i', 'ï': 'i', 'ô': 'o',
    'ö': 'o', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c'};
  final low = (s ?? '').toLowerCase().trim().split('').map((c) => accents[c] ?? c).join();
  final out = low.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  return out.replaceAll(RegExp(r'^_+|_+$'), '');
}

String machineFamily(String t) {
  final n = normType(t);
  for (final e in machineFamilies.entries) {
    if (e.value.contains(n)) return e.key;
  }
  return n;
}

/// Type machine de la gamme pour une machine du plan ("" pour un chariot, une table de stock…).
String machineTypeOf(Map m) {
  if (m['machine_type'] != null) return normType('${m['machine_type']}');
  final spec = machineCatalog['${m['type']}'];
  return normType(spec?.machineType ?? '${m['type'] ?? ''}');
}

/// Nouveau plan vide (format de l'API).
Map<String, dynamic> newWorkshopPlan({required String id, String name = "Plan de l'atelier", double width = 30, double length = 20}) => {
      'id': id,
      'name': name,
      'version': 'actuel',
      'width_m': width,
      'length_m': length,
      'background': null,
      'elements': <dynamic>[],
      'settings': <String, dynamic>{'grid_m': 0.5},
      'cloud_id': null,
      'dirty': true,
      'updated_at': DateTime.now().toIso8601String(),
    };

List<Map<String, dynamic>> planElements(Map plan) =>
    [for (final e in (plan['elements'] as List? ?? const [])) (e as Map).cast<String, dynamic>()];

List<Map<String, dynamic>> planMachines(Map plan) => [for (final e in planElements(plan)) if (e['kind'] == 'machine') e];

/// Nouvelle machine de la bibliothèque, centrée en (x, y).
Map<String, dynamic> newMachine(String id, String type, double x, double y, {String label = ''}) {
  final spec = machineCatalog[type];
  return {
    'id': id,
    'kind': 'machine',
    'type': type,
    'x': pyRound(x, 2),
    'y': pyRound(y, 2),
    'w': spec?.w ?? 1.2,
    'd': spec?.d ?? 0.6,
    'rot': 0,
    'label': label,
    'status': 'service',
  };
}

/// Coins d'une machine posée (centre, largeur, profondeur, rotation horaire).
List<(double, double)> machineCorners(Map m) {
  final cx = _n(m['x']), cy = _n(m['y']), w = _n(m['w'], 1.2), d = _n(m['d'], 0.6);
  final a = _n(m['rot']) * math.pi / 180;
  final c = math.cos(a), s = math.sin(a);
  return [
    for (final (dx, dy) in [(-w / 2, -d / 2), (w / 2, -d / 2), (w / 2, d / 2), (-w / 2, d / 2)])
      (cx + dx * c - dy * s, cy + dx * s + dy * c),
  ];
}

/// Boîte englobante d'un élément (pour la sélection au toucher).
(double, double, double, double) elementBounds(Map e) {
  switch (e['kind']) {
    case 'machine':
      final pts = machineCorners(e);
      final xs = pts.map((p) => p.$1), ys = pts.map((p) => p.$2);
      return (xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
    case 'wall':
      final t = _n(e['thickness'], 0.2) / 2 + 0.1;
      return (math.min(_n(e['x1']), _n(e['x2'])) - t, math.min(_n(e['y1']), _n(e['y2'])) - t,
          math.max(_n(e['x1']), _n(e['x2'])) + t, math.max(_n(e['y1']), _n(e['y2'])) + t);
    case 'pillar':
      final w = _n(e['w'], 0.4), d = _n(e['d'], 0.4);
      return (_n(e['x']) - w / 2, _n(e['y']) - d / 2, _n(e['x']) + w / 2, _n(e['y']) + d / 2);
    case 'door':
      final w = _n(e['width'], 1);
      return (_n(e['x']) - w / 2, _n(e['y']) - 0.3, _n(e['x']) + w / 2, _n(e['y']) + 0.3);
    default: // aisle, zone, text
      return (_n(e['x']), _n(e['y']), _n(e['x']) + _n(e['w'], 1), _n(e['y']) + _n(e['h'], 1));
  }
}

bool elementContains(Map e, double x, double y, [double tol = 0.15]) {
  final (x0, y0, x1, y1) = elementBounds(e);
  return x >= x0 - tol && x <= x1 + tol && y >= y0 - tol && y <= y1 + tol;
}

/// Déplace un élément de (dx, dy) mètres.
void moveElement(Map<String, dynamic> e, double dx, double dy) {
  if (e['kind'] == 'wall') {
    for (final k in ['x1', 'x2']) {
      e[k] = pyRound(_n(e[k]) + dx, 2);
    }
    for (final k in ['y1', 'y2']) {
      e[k] = pyRound(_n(e[k]) + dy, 2);
    }
  } else {
    e['x'] = pyRound(_n(e['x']) + dx, 2);
    e['y'] = pyRound(_n(e['y']) + dy, 2);
  }
}

double snap(double v, double grid) => grid > 0 ? (v / grid).round() * grid : v;

/// Calibration d'un fond de plan : 2 points (pixels de l'image) + distance réelle → mètres par pixel.
double calibrationScale((double, double) a, (double, double) b, double realMeters) {
  final px = math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
  if (px <= 0 || realMeters <= 0) throw ArgumentError('Calibration impossible : points confondus ou distance nulle.');
  return realMeters / px;
}

// --------------------------------------------------------------------------- association
/// Types machine requis par chaque station du plan de ligne (opérations de la gamme).
List<String> stationPlanMachineTypes(Map st) {
  final out = <String>[];
  for (final t in (st['machine_types'] as List? ?? const [])) {
    final n = normType('$t');
    if (n.isNotEmpty && !out.contains(n)) out.add(n);
  }
  for (final o in (st['operations'] as List? ?? const [])) {
    final n = normType('${(o as Map)['machine_type'] ?? ''}');
    if (n.isNotEmpty && !out.contains(n)) out.add(n);
  }
  return out;
}

(double, double) _center(List<Map<String, dynamic>> ms) {
  var x = 0.0, y = 0.0;
  for (final m in ms) {
    x += _n(m['x']);
    y += _n(m['y']);
  }
  return (x / ms.length, y / ms.length);
}

double _d((double, double) a, (double, double) b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Place les stations d'un calcul sur les machines du plan.
/// Retourne `{assignment: {station: [machine ids]}, missing: [stations], notes: [...]}`.
Map<String, dynamic> autoAssign(List stations, Map plan, [Map? manual]) {
  final machines = [for (final m in planMachines(plan)) if (m['status'] != 'panne' && machineTypeOf(m).isNotEmpty) m];
  final byId = {for (final m in machines) '${m['id']}': m};
  final used = <String>{};
  final assignment = <String, List<String>>{};
  final notes = <String>[];
  final missing = <int>[];
  // 1. liaisons manuelles (machine ↔ station) et machines liées à un poste (ws_id = n° de station)
  for (final st in stations) {
    final sid = '${(st as Map)['station']}';
    final man = [for (final id in ((manual?[sid] as List?) ?? const [])) if (byId.containsKey('$id')) '$id'];
    final linked = [for (final m in machines) if ('${m['ws_id'] ?? ''}' == sid && !man.contains('${m['id']}')) '${m['id']}'];
    final ids = [...man, ...linked].where((id) => !used.contains(id)).toList();
    if (ids.isNotEmpty) {
      assignment[sid] = ids;
      used.addAll(ids);
    }
  }
  // 2. même type, au plus près de la station précédente ; 3. famille voisine
  (double, double)? prev;
  for (final st in stations) {
    final sid = '${(st as Map)['station']}';
    if (assignment.containsKey(sid)) {
      prev = _center([for (final id in assignment[sid]!) byId[id]!]);
      continue;
    }
    final types = stationPlanMachineTypes(st);
    final picked = <String>[];
    for (final t in types.isEmpty ? [''] : types) {
      List<Map<String, dynamic>> cands = [
        for (final m in machines)
          if (!used.contains('${m['id']}') && (t.isEmpty || machineTypeOf(m) == t)) m,
      ];
      var fallback = false;
      if (cands.isEmpty && t.isNotEmpty) {
        final f = machineFamily(t);
        cands = [for (final m in machines) if (!used.contains('${m['id']}') && machineFamily(machineTypeOf(m)) == f) m];
        fallback = cands.isNotEmpty;
      }
      if (cands.isEmpty) continue;
      final ref = prev;
      cands.sort((a, b) => ref == null
          ? '${a['label']}${a['id']}'.compareTo('${b['label']}${b['id']}')
          : _d((_n(a['x']), _n(a['y'])), ref).compareTo(_d((_n(b['x']), _n(b['y'])), ref)));
      final m = cands.first;
      picked.add('${m['id']}');
      used.add('${m['id']}');
      if (fallback) notes.add('Station $sid : ${machineCatalog[m['type']]?.label ?? m['type']} utilisée à la place de « $t » (famille voisine).');
      if (types.isEmpty) break;
    }
    if (picked.isEmpty) {
      missing.add(int.tryParse(sid) ?? 0);
      notes.add('Station $sid : aucune machine disponible sur le plan (station virtuelle).');
    } else {
      assignment[sid] = picked;
      prev = _center([for (final id in picked) byId[id]!]);
    }
  }
  return {'assignment': assignment, 'missing': missing, 'notes': notes, 'unused': [for (final m in machines) if (!used.contains('${m['id']}')) m['id']]};
}

/// Implantation de simulation d'un calcul sur un plan (positions + distances), format `layout` de l'API.
Map<String, dynamic> planLayout(List stations, Map plan, [Map? manual]) {
  final auto = autoAssign(stations, plan, manual);
  final asg = (auto['assignment'] as Map<String, List<String>>);
  final byId = {for (final m in planMachines(plan)) '${m['id']}': m};
  final pos = <String, Map<String, double>>{};
  final virtual = <int>[];
  final width = _n(plan['width_m'], 30), length = _n(plan['length_m'], 20);
  var vx = 1.0;
  for (final st in stations) {
    final sid = '${(st as Map)['station']}';
    final ids = asg[sid] ?? const [];
    if (ids.isNotEmpty) {
      final c = _center([for (final id in ids) byId[id]!]);
      pos[sid] = {'x': pyRound(c.$1, 2), 'y': pyRound(c.$2, 2)};
    } else {
      virtual.add(int.tryParse(sid) ?? 0);
      pos[sid] = {'x': pyRound(math.min(vx, width), 2), 'y': pyRound(length + 1.5, 2)};
      vx += virtualSpacingM;
    }
  }
  final distances = <String, double>{};
  final order = [for (final st in stations) '${(st as Map)['station']}'];
  double rect(String a, String b) => (pos[a]!['x']! - pos[b]!['x']!).abs() + (pos[a]!['y']! - pos[b]!['y']!).abs();
  for (var i = 0; i + 1 < order.length; i++) {
    distances['${order[i]}-${order[i + 1]}'] = pyRound(rect(order[i], order[i + 1]), 2);
  }
  // déplacements des ouvrières partagées entre deux postes
  for (var i = 0; i < order.length; i++) {
    for (var j = i + 2; j < order.length; j++) {
      distances['${order[i]}-${order[j]}'] = pyRound(rect(order[i], order[j]), 2);
    }
  }
  var flow = 0.0;
  for (var i = 0; i + 1 < order.length; i++) {
    flow += distances['${order[i]}-${order[i + 1]}']!;
  }
  return {
    'kind': 'free',
    'positions': pos,
    'distances': distances,
    'plan_id': plan['cloud_id'] ?? plan['id'],
    'local_plan_id': plan['id'],
    'assignment': asg,
    'virtual': virtual,
    'notes': auto['notes'],
    'flow_m': pyRound(flow, 1),
  };
}

/// Postes de travail (WS) déduits des machines du plan (une machine = un poste, chariots exclus).
List<Map<String, dynamic>> inventoryWorkstations(Map plan) => [
      for (final m in planMachines(plan))
        if (machineTypeOf(m).isNotEmpty)
          {
            'id': (m['label'] ?? '').toString().isNotEmpty ? m['label'] : m['id'],
            'machine_type': machineTypeOf(m),
            'available': m['status'] != 'panne' && m['status'] != 'reserve',
            'machine_id': m['id'],
          },
    ];

/// Corps envoyé à `POST/PUT /workshop-plans` (champs locaux retirés, fond d'image non synchronisé).
Map<String, dynamic> planApiBody(Map plan) => {
      'name': plan['name'] ?? "Plan de l'atelier",
      'version': plan['version'] ?? 'actuel',
      'width_m': _n(plan['width_m'], 30).clamp(2, 400),
      'length_m': _n(plan['length_m'], 20).clamp(2, 400),
      'elements': planElements(plan),
      'settings': {
        ...((plan['settings'] as Map?)?.cast<String, dynamic>() ?? const {}),
        'source': 'flutter',
      },
    };
