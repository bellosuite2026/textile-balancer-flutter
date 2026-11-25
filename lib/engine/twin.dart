/// Jumeau numérique 2D — simulation d'une journée de ligne par paquets (hors ligne).
///
/// Portage Dart de `engine/simulation.py` (LineDaySimulator) et de `api/twin.py` du dépôt Python
/// de référence : mêmes entrées (plan de ligne, implantation, scénario) et **même format de
/// résultat** que `POST /v1/orgs/{org}/runs/{id}/simulate`, pour que l'écran du jumeau affiche
/// indifféremment un calcul local (hors ligne) ou le résultat de l'API.
///
/// Modèle : stations dans l'ordre, paquets d'encours (`bundle_size` pièces), ouvrières =
/// ressources (une ouvrière partagée sert plusieurs postes), lancement tiré en tête de ligne avec
/// plafond d'encours CONWIP = Σ(opératrices + 1) paquets, transport = prise/dépose + distance / 50 m/min,
/// pannes planifiées, variabilité normale tronquée. Les tirages aléatoires diffèrent de SimPy :
/// les chiffres sont proches de l'API, pas identiques.
library;

import 'dart:math' as math;

import 'models.dart';
import 'production.dart';
import 'pyfmt.dart';

const double layoutSpacingM = 1.6;
const double layoutAisleM = 1.4;
const double longTransferM = 3.0;
const double farSecondStationM = 2.5;
const double unqualifiedEfficiency = 0.5;

class LineDayConfig {
  final double shiftMinutes;
  final int bundleSize;
  final double efficiency;
  final double variability;
  final double handlingMin;
  final double walkSpeedMPerMin;
  final int startWipBundles;
  final Map<int, int>? initialWip;
  final int? wipCapBundles;
  final int seed;
  final bool trace;
  final int maxTraceEvents;
  final double snapshotEveryMin;

  const LineDayConfig({
    this.shiftMinutes = 480,
    this.bundleSize = 10,
    this.efficiency = 1.0,
    this.variability = 0.10,
    this.handlingMin = 0.10,
    this.walkSpeedMPerMin = 50,
    this.startWipBundles = 1,
    this.initialWip,
    this.wipCapBundles,
    this.seed = 42,
    this.trace = true,
    this.maxTraceEvents = 40000,
    this.snapshotEveryMin = 5,
  });

  /// Paramètres d'un scénario du jumeau (`TwinScenario` de l'API).
  factory LineDayConfig.fromScenario(Map<String, dynamic> s, {int traceEvents = 15000}) => LineDayConfig(
        shiftMinutes: _num(s['shift_minutes'], 480),
        bundleSize: _num(s['bundle_size'], 10).round(),
        efficiency: _num(s['efficiency_pct'], 100) / 100,
        variability: _num(s['variability_pct'], 10) / 100,
        seed: _num(s['seed'], 42).round(),
        maxTraceEvents: traceEvents,
      );
}

double _num(Object? v, [double d = 0]) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}') ?? d;
}

int _int(Object? v, [int d = 0]) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? d);

// --------------------------------------------------------------------------- plan
/// Plan de ligne enrichi (compétences des opérations, ouvrières) — équivalent de `twin.twin_plan`.
Map<String, dynamic> twinPlan(BalanceResult r, Problem? problem, [Map<String, dynamic>? basePlan]) {
  final plan = Map<String, dynamic>.of(basePlan ?? buildPlan(r, problem));
  final ops = {for (final o in problem?.operations ?? const <Operation>[]) o.id: o};
  final stations = <Map<String, dynamic>>[];
  for (final raw in (plan['stations'] as List? ?? const [])) {
    final st = Map<String, dynamic>.of((raw as Map).cast<String, dynamic>());
    st['operations'] = [
      for (final o in (st['operations'] as List? ?? const []))
        {
          ...(o as Map).cast<String, dynamic>(),
          'skills': List<String>.of(ops[o['id']]?.requiredSkills ?? const []),
          'machine_type': ops[o['id']]?.machineType ?? '',
        },
    ];
    stations.add(st);
  }
  plan['stations'] = stations;
  final workers = <String, Map<String, dynamic>>{};
  for (final w in problem?.workers ?? const <Worker>[]) {
    if (!w.available) continue;
    workers[w.id] = {'name': w.name.isNotEmpty ? w.name : w.id, 'skills': List<String>.of(w.skills), 'efficiency': w.efficiency};
  }
  for (final st in stations) {
    final ids = (st['worker_ids'] as List? ?? const []).map((e) => '$e').toList();
    final names = (st['workers'] as List? ?? const []).map((e) => '$e').toList();
    for (var i = 0; i < math.min(ids.length, names.length); i++) {
      workers.putIfAbsent(ids[i], () => {'name': names[i], 'skills': <String>[], 'efficiency': 1.0});
    }
  }
  plan['workers'] = workers;
  return plan;
}

List<int> stationOrder(Map<String, dynamic> plan) =>
    [for (final s in (plan['stations'] as List? ?? const [])) _int((s as Map)['station'])];

/// Positions par défaut (mètres) : en ligne, ou en U (aller puis retour face à face).
Map<String, dynamic> defaultLayout(List<int> ids, [String kind = 'line']) {
  final pos = <String, Map<String, double>>{};
  if (kind == 'u' && ids.length > 2) {
    final half = (ids.length / 2).ceil();
    for (var i = 0; i < ids.length; i++) {
      if (i < half) {
        pos['${ids[i]}'] = {'x': pyRound(i * layoutSpacingM, 2), 'y': 0.0};
      } else {
        final j = ids.length - 1 - i;
        pos['${ids[i]}'] = {
          'x': pyRound(j * layoutSpacingM + (ids.length.isOdd ? layoutSpacingM / 2 : 0), 2),
          'y': layoutAisleM,
        };
      }
    }
    return {'kind': 'u', 'positions': pos};
  }
  for (var i = 0; i < ids.length; i++) {
    pos['${ids[i]}'] = {'x': pyRound(i * layoutSpacingM, 2), 'y': 0.0};
  }
  return {'kind': kind == 'free' ? 'free' : 'line', 'positions': pos};
}

/// Implantation enregistrée complétée des stations manquantes (`twin.layout_for`).
Map<String, dynamic> layoutFor(Map<String, dynamic> plan, Map<String, dynamic>? saved, [String kind = 'line']) {
  final k = (saved?['kind'] as String?) ?? kind;
  final base = defaultLayout(stationOrder(plan), k == 'free' ? 'line' : k);
  final pos = Map<String, dynamic>.of(base['positions'] as Map<String, dynamic>);
  final given = (saved?['positions'] as Map?) ?? const {};
  for (final e in given.entries) {
    if (pos.containsKey('${e.key}') && e.value is Map) {
      pos['${e.key}'] = {'x': _num((e.value as Map)['x']), 'y': _num((e.value as Map)['y'])};
    }
  }
  return {
    'kind': k,
    'positions': pos,
    if (saved?['distances'] != null) 'distances': saved!['distances'],
    if (saved?['plan_id'] != null) 'plan_id': saved!['plan_id'],
    if (saved?['assignment'] != null) 'assignment': saved!['assignment'],
  };
}

Map<int, (double, double)> _positions(Map<String, dynamic> plan, Map<String, dynamic>? layout) {
  final order = stationOrder(plan);
  final base = defaultLayout(order, (layout?['kind'] as String?) ?? 'line')['positions'] as Map;
  final given = (layout?['positions'] as Map?) ?? const {};
  return {
    for (final sid in order)
      sid: () {
        final p = (given['$sid'] ?? base['$sid']) as Map;
        return (_num(p['x']), _num(p['y']));
      }(),
  };
}

double Function(int, int) _distanceFn(Map<String, dynamic>? layout, Map<int, (double, double)> pos) {
  final over = (layout?['distances'] as Map?) ?? const {};
  return (a, b) {
    final k1 = '$a-$b', k2 = '$b-$a';
    if (over[k1] != null) return _num(over[k1]);
    if (over[k2] != null) return _num(over[k2]);
    final pa = pos[a], pb = pos[b];
    if (pa == null || pb == null) return 0;
    return math.sqrt(math.pow(pa.$1 - pb.$1, 2) + math.pow(pa.$2 - pb.$2, 2));
  };
}

Set<String> _stationSkills(Map st) => {
      for (final op in (st['operations'] as List? ?? const []))
        for (final s in ((op as Map)['skills'] ?? op['required_skills'] ?? const []) as List)
          if ('$s'.isNotEmpty) '$s',
    };

/// Ouvrières de chaque station ; postes sans nom = ouvrières anonymes « `S<n>-<k>` ».
Map<int, List<String>> stationWorkers(Map<String, dynamic> plan) {
  final out = <int, List<String>>{};
  for (final st in (plan['stations'] as List? ?? const [])) {
    final sid = _int((st as Map)['station']);
    final ids = [for (final w in (st['worker_ids'] as List? ?? const [])) if ('$w'.isNotEmpty) '$w'];
    final n = math.max(1, _int(st['operators'], ids.isEmpty ? 1 : ids.length));
    while (ids.length < n) {
      ids.add('S$sid-${ids.length + 1}');
    }
    out[sid] = ids;
  }
  return out;
}

String workerLabel(Map<String, dynamic> plan, String wid) {
  final info = ((plan['workers'] as Map?) ?? const {})[wid] as Map?;
  if (info != null && '${info['name'] ?? ''}'.isNotEmpty) return '${info['name']}';
  for (final st in (plan['stations'] as List? ?? const [])) {
    final ids = [for (final x in ((st as Map)['worker_ids'] as List? ?? const [])) '$x'];
    final names = [for (final x in (st['workers'] as List? ?? const [])) '$x'];
    final i = ids.indexOf(wid);
    if (i >= 0 && i < names.length) return names[i];
  }
  if (wid.startsWith('S') && wid.contains('-')) return 'Opératrice ${wid.substring(1)}';
  return wid;
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> m) => _copy(m) as Map<String, dynamic>;
Object? _copy(Object? v) => switch (v) {
      Map() => <String, dynamic>{for (final e in v.entries) '${e.key}': _copy(e.value)},
      List() => [for (final x in v) _copy(x)],
      _ => v,
    };

/// Applique un scénario au plan (absences, réaffectation selon compétences, effectif imposé).
(Map<String, dynamic>, List<String>) applyScenario(Map<String, dynamic> plan, [Map<String, dynamic>? scenario]) {
  final scen = scenario ?? const <String, dynamic>{};
  final p = _deepCopy(plan);
  p['workers'] ??= <String, dynamic>{};
  final workers = p['workers'] as Map<String, dynamic>;
  final notes = <String>[];
  final sw = stationWorkers(p);
  final minutes = {for (final s in p['stations'] as List) _int((s as Map)['station']): _num(s['minutes'])};
  final unqualified = <String, Set<int>>{};
  final stById = {for (final s in p['stations'] as List) _int((s as Map)['station']): s};

  for (final e in ((scen['operators'] as Map?) ?? const {}).entries) {
    final sid = _int(e.key), n = math.max(0, _int(e.value));
    final cur = sw[sid];
    if (cur == null) continue;
    if (n > cur.length) {
      final add = n - cur.length;
      for (var i = 0; i < add; i++) {
        final wid = 'R$sid-${i + 1}';
        workers[wid] = {'name': 'Renfort $sid.${i + 1}', 'skills': _stationSkills(stById[sid]!).toList()..sort(), 'efficiency': 1.0};
        cur.add(wid);
      }
      notes.add('Station $sid : effectif porté à $n.');
    } else if (n < cur.length) {
      sw[sid] = cur.sublist(0, n);
      notes.add('Station $sid : effectif réduit à $n.');
    }
  }

  final absent = {for (final w in (scen['absent'] as List? ?? const [])) '$w'};
  for (final sid in sw.keys.toList()) {
    sw[sid] = [for (final w in sw[sid]!) if (!absent.contains(w)) w];
  }
  if (absent.isNotEmpty) {
    final names = (absent.toList()..sort()).map((w) => workerLabel(p, w)).join(', ');
    notes.add('Absente(s) : $names.');
  }

  final reassign = scen['reassign'] != false;
  for (final sid in sw.keys.toList()..sort()) {
    if (sw[sid]!.isNotEmpty) continue;
    if (!reassign) {
      notes.add('Station $sid sans ouvrière : la ligne est bloquée à ce poste.');
      continue;
    }
    final req = _stationSkills(stById[sid]!);
    (bool, double)? bestKey;
    String? bw, mode;
    int? donorBest;
    var bestQualified = false;
    for (final donor in sw.keys) {
      if (donor == sid) continue;
      final ws = sw[donor]!;
      for (final w in ws) {
        if (absent.contains(w)) continue;
        final skills = {for (final s in ((workers[w] as Map?)?['skills'] as List? ?? const [])) '$s'};
        final qualified = req.isEmpty || skills.containsAll(req);
        final n = ws.length;
        final double cost;
        final String m;
        if (n >= 2) {
          cost = math.max(minutes[donor]! / (n - 1), minutes[sid]!);
          m = 'move';
        } else {
          cost = minutes[donor]! / n + minutes[sid]!;
          m = 'share';
        }
        final key = (!qualified, cost);
        final better = bestKey == null ||
            (key.$1 != bestKey.$1 ? (!key.$1 && bestKey.$1) : key.$2 < bestKey.$2);
        if (better) {
          bestKey = key;
          bw = w;
          donorBest = donor;
          mode = m;
          bestQualified = qualified;
        }
      }
    }
    if (bw == null) {
      notes.add('Station $sid sans ouvrière disponible : la ligne est bloquée à ce poste.');
      continue;
    }
    final label = workerLabel(p, bw);
    if (mode == 'move') {
      sw[donorBest!] = [for (final x in sw[donorBest]!) if (x != bw) x];
      notes.add('Station $sid : $label quitte la station $donorBest (réaffectation selon compétences).');
    } else {
      notes.add('Station $sid : $label tient aussi la station $donorBest (poste partagé).');
    }
    sw[sid] = [bw];
    if (!bestQualified) {
      unqualified.putIfAbsent(bw, () => {}).add(sid);
      notes.add('Aucune ouvrière qualifiée pour la station $sid : $label la tient à '
          '${(unqualifiedEfficiency * 100).toInt()} % de rendement.');
    }
  }
  for (final st in p['stations'] as List) {
    final sid = _int((st as Map)['station']);
    st['worker_ids'] = List<String>.of(sw[sid]!);
    st['workers'] = [for (final w in sw[sid]!) workerLabel(p, w)];
    st['operators'] = sw[sid]!.length;
  }
  p['unqualified'] = {for (final e in unqualified.entries) e.key: (e.value.toList()..sort())};
  return (p, notes);
}

/// Contrôle Lean de l'implantation : transferts longs, ouvrière trop loin de son 2e poste.
Map<String, dynamic> leanCheck(Map<String, dynamic> plan, [Map<String, dynamic>? layout]) {
  final pos = _positions(plan, layout);
  final dist = _distanceFn(layout, pos);
  final order = stationOrder(plan);
  final warnings = <Map<String, dynamic>>[];
  var total = 0.0, back = 0;
  for (var i = 0; i + 1 < order.length; i++) {
    final d = dist(order[i], order[i + 1]);
    total += d;
    if (d > longTransferM) {
      warnings.add({
        'kind': 'long_transfer',
        'stations': [order[i], order[i + 1]],
        'message': 'Transfert long entre les stations ${order[i]} et ${order[i + 1]} (${pyFixed(d, 1)} m).',
      });
    }
    if (pos[order[i + 1]]!.$1 < pos[order[i]]!.$1 - 0.01 && (layout?['kind'] ?? 'line') == 'free') back++;
  }
  final sw = stationWorkers(plan);
  final byWorker = <String, List<int>>{};
  sw.forEach((sid, ws) {
    for (final w in ws) {
      byWorker.putIfAbsent(w, () => []).add(sid);
    }
  });
  byWorker.forEach((w, sts) {
    for (var i = 0; i + 1 < sts.length; i++) {
      final d = dist(sts[i], sts[i + 1]);
      if (d > farSecondStationM) {
        warnings.add({
          'kind': 'far_second_station',
          'worker': w,
          'message': '${workerLabel(plan, w)} tient les stations ${sts[i]} et ${sts[i + 1]} distantes de ${pyFixed(d, 1)} m.',
        });
      }
    }
  });
  return {'flow_m': pyRound(total, 1), 'backtracks': back, 'warnings': warnings};
}

// --------------------------------------------------------------------------- moteur
class _Ev implements Comparable<_Ev> {
  final double t;
  final int seq;
  final void Function() fn;
  _Ev(this.t, this.seq, this.fn);
  @override
  int compareTo(_Ev o) => t != o.t ? t.compareTo(o.t) : seq.compareTo(o.seq);
}

/// Tas binaire minimal (file d'événements).
class _Heap {
  final _a = <_Ev>[];
  bool get isEmpty => _a.isEmpty;
  _Ev get first => _a.first;
  void add(_Ev e) {
    _a.add(e);
    var i = _a.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_a[p].compareTo(_a[i]) <= 0) break;
      final t = _a[p];
      _a[p] = _a[i];
      _a[i] = t;
      i = p;
    }
  }

  _Ev pop() {
    final top = _a.first;
    final last = _a.removeLast();
    if (_a.isNotEmpty) {
      _a[0] = last;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _a.length && _a[l].compareTo(_a[m]) < 0) m = l;
        if (r < _a.length && _a[r].compareTo(_a[m]) < 0) m = r;
        if (m == i) break;
        final t = _a[m];
        _a[m] = _a[i];
        _a[i] = t;
        i = m;
      }
    }
    return top;
  }
}

class _Bundle {
  final int id;
  final int size;
  int idx;
  final double t0;
  final bool fresh;
  final int startIndex;
  double arrive = 0;
  _Bundle(this.id, this.size, this.idx, this.t0, this.fresh) : startIndex = idx;
}

class _St {
  int wip = 0, maxWip = 0, done = 0;
  double busy = 0, downMin = 0;
  final waits = <double>[];
  final queue = <_Bundle>[];
}

class LineDaySimulator {
  LineDaySimulator(this.plan, [Map<String, dynamic>? layout, LineDayConfig? config, List? breakdowns])
      : cfg = config ?? const LineDayConfig(),
        layout = layout {
    rng = math.Random(cfg.seed);
    order = stationOrder(plan);
    pos = _positions(plan, layout);
    dist = _distanceFn(layout, pos);
    sw = stationWorkers(plan);
    for (final st in plan['stations'] as List) {
      final m = st as Map;
      if (m.containsKey('operators') && _int(m['operators']) == 0 && (m['worker_ids'] as List? ?? const []).isEmpty) {
        sw[_int(m['station'])] = [];
      }
    }
    minutes = {for (final s in plan['stations'] as List) _int((s as Map)['station']): _num(s['minutes'])};
    final winfo = (plan['workers'] as Map?) ?? const {};
    final unq = (plan['unqualified'] as Map?) ?? const {};
    sw.forEach((sid, ws) {
      for (final w in ws) {
        var e = _num((winfo[w] as Map?)?['efficiency'], 1.0);
        if (e <= 0) e = 1.0;
        if (((unq[w] as List?) ?? const []).map(_int).contains(sid)) e *= unqualifiedEfficiency;
        weff['$w|$sid'] = e;
        free[w] = true;
        wbusy[w] = 0;
        wwalk[w] = 0;
        wStations.putIfAbsent(w, () => []).add(sid);
      }
    });
    for (final sid in order) {
      down[sid] = [];
      st[sid] = _St();
    }
    for (final b in breakdowns ?? const []) {
      final sid = _int((b as Map)['station']);
      if (down.containsKey(sid)) {
        final s0 = math.max(0.0, _num(b['start_min']));
        down[sid]!.add((s0, s0 + math.max(0.0, _num(b['duration_min']))));
      }
    }
    final size = math.max(1, cfg.bundleSize);
    final capB = cfg.wipCapBundles ?? order.fold<int>(0, (a, s) => a + (sw[s]?.length ?? 0) + 1);
    capPieces = math.max(1, capB) * size;
  }

  final Map<String, dynamic> plan;
  final Map<String, dynamic>? layout;
  final LineDayConfig cfg;
  late final math.Random rng;
  late final List<int> order;
  late final Map<int, (double, double)> pos;
  late final double Function(int, int) dist;
  late final Map<int, List<String>> sw;
  late final Map<int, double> minutes;
  final weff = <String, double>{};
  final free = <String, bool>{};
  final wbusy = <String, double>{};
  final wwalk = <String, double>{};
  final wlast = <String, int>{};
  final wStations = <String, List<int>>{};
  final down = <int, List<(double, double)>>{};
  final st = <int, _St>{};
  final events = <List<Object>>[];
  final bundles = <String, int>{};
  bool traceTruncated = false;
  final finished = <(double, int)>[];
  final leadTimes = <double>[];
  double transportM = 0;
  int launched = 0, nextId = 0, inTransit = 0;
  final snapshots = <List<Object>>[];
  late final int capPieces;

  final _heap = _Heap();
  int _seq = 0;
  double now = 0;

  void _at(double t, void Function() fn) => _heap.add(_Ev(t, _seq++, fn));

  void _ev(List<Object> row) {
    if (!cfg.trace) return;
    if (events.length >= cfg.maxTraceEvents) {
      traceTruncated = true;
      return;
    }
    events.add([pyRound(now, 2), ...row]);
  }

  double? _downUntil(int sid, double t) {
    for (final (a, b) in down[sid]!) {
      if (a <= t && t < b) return b;
    }
    return null;
  }

  double _extendForDowntime(int sid, double start, double dur) {
    var end = start + dur;
    final counted = <int>{};
    var changed = true;
    final d = down[sid]!;
    while (changed) {
      changed = false;
      for (var i = 0; i < d.length; i++) {
        if (counted.contains(i)) continue;
        final (a, b) = d[i];
        if (a < end && b > start) {
          counted.add(i);
          end += a >= start ? math.min(b, end) - math.max(a, start) : b - start;
          changed = true;
        }
      }
    }
    return end - start;
  }

  double _gauss() {
    final u1 = math.max(1e-12, rng.nextDouble()), u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  double _duration(int sid, int size, String w) {
    final m = minutes[sid]! / math.max(1e-6, cfg.efficiency * (weff['$w|$sid'] ?? 1.0));
    final mean = size * m;
    final cv = math.max(0.0, cfg.variability);
    if (cv <= 0 || mean <= 0) return mean;
    final sd = m * cv * math.sqrt(size);
    return math.max(0.3 * mean, mean + sd * _gauss());
  }

  void _launch(int atIndex, int size, {bool fresh = true}) {
    nextId++;
    final b = _Bundle(nextId, size, atIndex, now, fresh);
    bundles['$nextId'] = size;
    if (fresh) launched += size;
    _arrive(b);
  }

  void _arrive(_Bundle b) {
    final sid = order[b.idx];
    final s = st[sid]!;
    s.wip += b.size;
    s.maxWip = math.max(s.maxWip, s.wip);
    b.arrive = now;
    _ev([b.id, sid, 0]);
    if ((sw[sid] ?? const []).isEmpty) return; // poste sans ouvrière : paquet bloqué
    s.queue.add(b);
    _dispatch();
  }

  /// Affecte les ouvrières libres aux paquets en attente (le plus ancien d'abord).
  void _dispatch() {
    for (final w in free.keys) {
      if (free[w] != true) continue;
      _Bundle? best;
      int? bestSid;
      for (final sid in wStations[w] ?? const <int>[]) {
        final q = st[sid]!.queue;
        if (q.isEmpty) continue;
        final up = _downUntil(sid, now);
        if (up != null) {
          _at(up, _dispatch);
          continue;
        }
        if (best == null || q.first.arrive < best.arrive) {
          best = q.first;
          bestSid = sid;
        }
      }
      if (best != null) _start(w, bestSid!, best);
    }
  }

  void _start(String w, int sid, _Bundle b) {
    final s = st[sid]!;
    s.queue.removeAt(0);
    s.waits.add(now - b.arrive);
    final last = wlast[w];
    if (last != null && last != sid) wwalk[w] = wwalk[w]! + dist(last, sid);
    wlast[w] = sid;
    free[w] = false;
    final work = _duration(sid, b.size, w);
    final total = _extendForDowntime(sid, now, work);
    s.downMin += total - work;
    _ev([b.id, sid, 1, w]);
    _at(now + total, () => _finish(w, sid, b, work));
  }

  void _finish(String w, int sid, _Bundle b, double work) {
    final s = st[sid]!;
    free[w] = true;
    s.busy += work;
    wbusy[w] = wbusy[w]! + work;
    s.done += b.size;
    s.wip -= b.size;
    _ev([b.id, sid, 2, w]);
    if (b.idx + 1 < order.length) {
      final nxt = order[b.idx + 1];
      final d = dist(sid, nxt);
      transportM += d;
      inTransit += b.size;
      b.idx++;
      _at(now + cfg.handlingMin + d / math.max(1e-6, cfg.walkSpeedMPerMin), () {
        inTransit -= b.size;
        _arrive(b);
      });
    } else {
      finished.add((now, b.size));
      if (b.startIndex == 0 && b.fresh) leadTimes.add(now - b.t0);
    }
    _dispatch();
  }

  void _feeder() {
    final size = math.max(1, cfg.bundleSize);
    final first = st[order.first]!;
    final lineWip = st.values.fold<int>(0, (a, s) => a + s.wip) + inTransit;
    if (first.queue.isEmpty && lineWip + size <= capPieces) _launch(0, size);
    _at(now + 0.25, _feeder);
  }

  void _snapshot() {
    snapshots.add([pyRound(now, 1), [for (final sid in order) st[sid]!.wip], finished.fold<int>(0, (a, f) => a + f.$2)]);
    _at(now + math.max(0.5, cfg.snapshotEveryMin), _snapshot);
  }

  Map<String, dynamic> run() {
    if (order.isEmpty) return {'success': false, 'error': 'Aucune station dans ce calcul.'};
    final size = math.max(1, cfg.bundleSize);
    final init = cfg.initialWip;
    for (var idx = 0; idx < order.length; idx++) {
      final sid = order[idx];
      var pieces = init != null ? (init[sid] ?? 0) : (idx > 0 ? cfg.startWipBundles * size : 0);
      while (pieces > 0) {
        final n = math.min(size, pieces);
        _launch(idx, n, fresh: false);
        pieces -= n;
      }
    }
    final firstOps = math.max(1, (sw[order.first] ?? const ['x']).length);
    for (var i = 0; i < firstOps; i++) {
      _launch(0, size);
    }
    _at(0, _feeder);
    _at(0, _snapshot);
    final horizon = cfg.shiftMinutes;
    while (!_heap.isEmpty && _heap.first.t < horizon) {
      final e = _heap.pop();
      now = e.t;
      e.fn();
    }
    now = horizon;
    return _result();
  }

  Map<String, dynamic> _result() {
    final T = math.max(1e-6, cfg.shiftMinutes);
    final done = finished.fold<int>(0, (a, f) => a + f.$2);
    final stations = <Map<String, dynamic>>[];
    for (var i = 0; i < order.length; i++) {
      final sid = order[i];
      final s = st[sid]!;
      final nw = sw[sid]?.length ?? 0;
      final util = nw > 0 ? s.busy / (nw * T) * 100 : 0.0;
      final series = [for (final snap in snapshots) (snap[1] as List)[i] as int];
      stations.add({
        'station': sid,
        'operators': nw,
        'workers': List<String>.of(sw[sid] ?? const []),
        'pieces': s.done,
        'utilization_pct': pyRound(math.min(100.0, util), 1),
        'avg_wait_min': s.waits.isEmpty ? 0.0 : pyRound(_mean(s.waits), 2),
        'max_wip': s.maxWip,
        'avg_wip': series.isEmpty ? 0.0 : pyRound(_mean(series), 1),
        'down_min': pyRound(s.downMin, 1),
        'minutes_per_piece': pyRound(minutes[sid]!, 4),
        'load_per_operator': nw > 0 ? pyRound(minutes[sid]! / nw, 4) : null,
      });
    }
    final blocked = [for (final s in stations) if (s['operators'] == 0) s['station'] as int];
    final wutil = {for (final w in free.keys) w: wbusy[w]! / T};
    final wload = {for (final w in free.keys) w: 0.0};
    sw.forEach((sid, ws) {
      for (final w in ws) {
        wload[w] = wload[w]! + minutes[sid]! / ws.length;
      }
    });
    final eff = math.max(1e-6, cfg.efficiency);
    for (final s in stations) {
      final sid = s['station'] as int;
      final ws = s['workers'] as List<String>;
      s['worker_util_max'] = pyRound(ws.fold<double>(0, (a, w) => math.max(a, wutil[w] ?? 0)) * 100, 1);
      final dn = down[sid]!.fold<double>(0, (a, d) => a + math.max(0.0, math.min(d.$2, T) - math.max(d.$1, 0.0)));
      final caps = [
        for (final w in ws)
          if (wload[w]! > 0) (T - dn) * eff * (weff['$w|$sid'] ?? 1.0) / wload[w]! * ws.length,
      ];
      s['capacity_pieces'] = caps.isEmpty ? 0 : caps.reduce(math.min).round();
    }
    int? bottleneck;
    if (blocked.isNotEmpty) {
      bottleneck = blocked.first;
    } else if (stations.isNotEmpty) {
      var best = stations.first;
      for (final s in stations) {
        final c = s['capacity_pieces'] as int, bc = best['capacity_pieces'] as int;
        if (c < bc || (c == bc && (s['avg_wip'] as double) > (best['avg_wip'] as double))) best = s;
      }
      bottleneck = best['station'] as int;
    }
    final hours = math.max(1, (T / 60).ceil());
    final hourly = List<int>.filled(hours, 0);
    for (final (t, n) in finished) {
      hourly[math.min(hours - 1, t ~/ 60)] += n;
    }
    final workers = [
      for (final w in free.keys)
        {
          'id': w,
          'name': workerLabel(plan, w),
          'stations': [for (final e in sw.entries) if (e.value.contains(w)) e.key],
          'utilization_pct': pyRound(math.min(100.0, wbusy[w]! / T * 100), 1),
          'walk_m': pyRound(wwalk[w]!, 1),
        },
    ];
    final totals = [for (final s in snapshots) (s[1] as List).fold<int>(0, (a, x) => a + (x as int))];
    final allWaits = [for (final sid in order) ...st[sid]!.waits];
    return {
      'success': true,
      'pieces': done,
      'per_hour': pyRound(done / T * 60, 1),
      'shift_minutes': pyRound(T, 1),
      'bottleneck': bottleneck,
      'blocked_stations': blocked,
      'wip_max': totals.isEmpty ? 0 : totals.reduce(math.max),
      'wip_avg': totals.isEmpty ? 0.0 : pyRound(_mean(totals), 1),
      'lead_time_min': leadTimes.isEmpty ? null : pyRound(_mean(leadTimes), 1),
      'avg_wait_min': allWaits.isEmpty ? 0.0 : pyRound(_mean(allWaits), 2),
      'transport_m': pyRound(transportM, 1),
      'walk_m': pyRound(wwalk.values.fold<double>(0, (a, b) => a + b), 1),
      'hourly': hourly,
      'stations': stations,
      'workers': workers,
      'snapshots': snapshots,
      'trace': {
        'events': events,
        'bundles': bundles,
        'truncated': traceTruncated,
        'codes': {'0': 'arrivée', '1': 'début', '2': 'fin'},
      },
      'config': {
        'bundle_size': math.max(1, cfg.bundleSize),
        'efficiency': cfg.efficiency,
        'variability': cfg.variability,
        'handling_min': cfg.handlingMin,
        'seed': cfg.seed,
      },
    };
  }
}

double _mean(Iterable<num> v) => v.isEmpty ? 0 : v.fold<double>(0, (a, b) => a + b) / v.length;

/// Point d'entrée : applique le scénario, simule la journée, ajoute le contrôle Lean.
Map<String, dynamic> simulateLineDay(Map<String, dynamic> plan,
    [Map<String, dynamic>? layout, LineDayConfig? config, Map<String, dynamic>? scenario]) {
  final scen = scenario ?? const <String, dynamic>{};
  final (p, notes) = applyScenario(plan, scen);
  final sim = LineDaySimulator(p, layout, config, scen['breakdowns'] as List?);
  final res = sim.run();
  res['notes'] = notes;
  res['lean'] = leanCheck(p, layout);
  res['plan'] = {
    'stations': [
      for (final s in p['stations'] as List)
        {
          'station': _int((s as Map)['station']),
          'worker_ids': s['worker_ids'] ?? const [],
          'workers': s['workers'] ?? const [],
          'operators': s['operators'] ?? 0,
          'minutes': _num(s['minutes']),
        },
    ],
    'unqualified': p['unqualified'] ?? const {},
  };
  for (final b in (scen['breakdowns'] as List? ?? const [])) {
    (res['notes'] as List<String>).add('Panne station ${_int((b as Map)['station'])} : '
        '${pyFixed(_num(b['duration_min']), 0)} min à partir de la minute ${pyFixed(_num(b['start_min']), 0)}.');
  }
  return res;
}

/// Scénario par défaut au format `TwinScenario` de l'API.
Map<String, dynamic> twinScenario({
  String name = 'Scénario',
  List<String> absent = const [],
  bool reassign = true,
  Map<String, int> operators = const {},
  List<Map<String, dynamic>> breakdowns = const [],
  int bundleSize = 10,
  double efficiencyPct = 100,
  double variabilityPct = 10,
  double shiftMinutes = 480,
  int seed = 42,
}) =>
    {
      'name': name,
      'absent': absent,
      'reassign': reassign,
      'operators': operators,
      'breakdowns': breakdowns,
      'bundle_size': bundleSize,
      'efficiency_pct': efficiencyPct,
      'variability_pct': variabilityPct,
      'shift_minutes': shiftMinutes,
      'seed': seed,
    };

Map<String, dynamic> _engineScenario(Map<String, dynamic> s) => {
      'absent': [for (final x in (s['absent'] as List? ?? const [])) '$x'],
      'reassign': s['reassign'] != false,
      'operators': {for (final e in ((s['operators'] as Map?) ?? const {}).entries) '${e.key}': _int(e.value)},
      'breakdowns': [for (final b in (s['breakdowns'] as List? ?? const [])) Map<String, dynamic>.of((b as Map).cast())],
    };

/// Simule 1–3 scénarios et prépare la comparaison (même format que `results` de l'API).
Map<String, dynamic> runTwinScenarios(Map<String, dynamic> plan, Map<String, dynamic> layout, List<Map<String, dynamic>> scenarios) {
  final out = <Map<String, dynamic>>[];
  for (final s in scenarios.take(3)) {
    final res = simulateLineDay(plan, layout, LineDayConfig.fromScenario(s), _engineScenario(s));
    out.add({'name': s['name'] ?? 'Scénario', 'params': s, 'result': res});
  }
  return {'scenarios': out, 'comparison': twinComparison(out), 'engine': 'local-dart'};
}

const twinComparisonRows = [
  ('pieces', 'Pièces / jour'),
  ('per_hour', 'Pièces / heure'),
  ('bottleneck', 'Goulot (station)'),
  ('wip_max', 'Encours max (pièces)'),
  ('wip_avg', 'Encours moyen (pièces)'),
  ('lead_time_min', 'Temps de traversée (min)'),
  ('avg_wait_min', 'Attente moyenne par paquet (min)'),
  ('utilization_avg', 'Occupation moyenne (%)'),
  ('operators', 'Ouvrières'),
  ('transport_m', 'Paquets transportés (m)'),
  ('walk_m', 'Déplacements ouvrières (m)'),
];

List<Map<String, dynamic>> twinComparison(List<Map<String, dynamic>> items) {
  final vals = <Map<String, dynamic>>[];
  for (final it in items) {
    final r = it['result'] as Map<String, dynamic>;
    final ws = (r['workers'] as List? ?? const []).cast<Map>();
    r['utilization_avg'] = ws.isEmpty ? 0 : pyRound(_mean([for (final w in ws) _num(w['utilization_pct'])]), 1);
    r['operators'] = {for (final w in ws) w['id']}.length;
    vals.add(r);
  }
  return [
    for (final (k, label) in twinComparisonRows) {'key': k, 'label': label, 'values': [for (final v in vals) v[k]]},
  ];
}

// --------------------------------------------------------------------------- réel vs simulé
/// Réel (suivi de production) vs simulé + prévision fin de journée — équivalent de `twin.sync`.
Map<String, dynamic> twinSync(Map<String, dynamic> dash, Map<String, dynamic> plan, Map<String, dynamic> layout,
    {int bundleSize = 10}) {
  final shift = math.min(_num(dash['shift_minutes'], 480) > 0 ? _num(dash['shift_minutes'], 480) : 480.0, 600.0);
  final elapsed = _num(dash['elapsed_minutes']);
  final effReal = dash['efficiency'] as num?;
  final eff = ((effReal ?? 100) / 100).clamp(0.1, 2.0).toDouble();
  final planned = simulateLineDay(plan, layout, LineDayConfig(shiftMinutes: shift, bundleSize: bundleSize, trace: false));
  final calibrated =
      simulateLineDay(plan, layout, LineDayConfig(shiftMinutes: shift, bundleSize: bundleSize, efficiency: eff, trace: false));
  final ph = planned['hourly'] as List<int>, ch = calibrated['hourly'] as List<int>;
  final hourly = <Map<String, dynamic>>[];
  final dh = (dash['hourly'] as List? ?? const []).cast<Map>();
  for (var i = 0; i < dh.length; i++) {
    hourly.add({
      'hour': dh[i]['hour'],
      'target': dh[i]['target'],
      'real': dh[i]['output'],
      'simulated': i < ph.length ? ph[i] : null,
      'simulated_calibrated': i < ch.length ? ch[i] : null,
    });
  }
  final realSt = {for (final s in (dash['stations'] as List? ?? const []).cast<Map>()) _int(s['station']): s};
  final ratio = shift > 0 ? elapsed / shift : 0.0;
  final byStation = [
    for (final s in (planned['stations'] as List).cast<Map>())
      {
        'station': s['station'],
        'real': realSt[s['station']]?['pieces'] ?? 0,
        'simulated_to_date': ((s['pieces'] as int) * ratio).round(),
        'simulated_day': s['pieces'],
        'real_efficiency': realSt[s['station']]?['efficiency'],
        'downtime_minutes': realSt[s['station']]?['downtime_minutes'] ?? 0,
      },
  ];
  final remaining = math.max(0.0, shift - elapsed);
  final order = [for (final s in (dash['stations'] as List? ?? const []).cast<Map>()) _int(s['station'])];
  final pieces = {for (final s in (dash['stations'] as List? ?? const []).cast<Map>()) _int(s['station']): _int(s['pieces'])};
  final notes = <String>[];
  var forecastRest = 0;
  if (remaining > 0 && order.isNotEmpty) {
    final init = <int, int>{};
    for (var i = 0; i + 1 < order.length; i++) {
      init[order[i + 1]] = elapsed > 0 ? math.max(0, (pieces[order[i]] ?? 0) - (pieces[order[i + 1]] ?? 0)) : bundleSize;
    }
    final scen = <String, dynamic>{'absent': <String>[], 'breakdowns': <Map<String, dynamic>>[]};
    for (final s in (dash['stations'] as List? ?? const []).cast<Map>()) {
      final stop = s['ongoing_stop'] as Map?;
      if (stop == null) continue;
      if (stop['reason'] == 'absence') {
        final stPlan = (plan['stations'] as List).cast<Map>().firstWhere((p) => _int(p['station']) == _int(s['station']),
            orElse: () => const {});
        final ids = (stPlan['worker_ids'] as List? ?? const []);
        if (ids.isNotEmpty) {
          (scen['absent'] as List<String>).add('${ids.first}');
          notes.add('Station ${s['station']} : absence en cours prise en compte jusqu\'à la fin du poste.');
        }
      } else {
        (scen['breakdowns'] as List).add({'station': s['station'], 'start_min': 0, 'duration_min': 15.0});
        notes.add('Station ${s['station']} : arrêt en cours supposé durer encore 15 min.');
      }
    }
    final rest = simulateLineDay(plan, layout,
        LineDayConfig(shiftMinutes: remaining, bundleSize: bundleSize, efficiency: eff, initialWip: init, trace: false), scen);
    forecastRest = rest['pieces'] as int;
    notes.addAll([for (final n in rest['notes'] as List<String>) if (!n.startsWith('Panne')) n]);
  }
  final output = _int(dash['output']);
  return {
    'elapsed_minutes': elapsed,
    'shift_minutes': shift,
    'real_efficiency': effReal,
    'efficiency_used_pct': pyRound(eff * 100, 1),
    'output': output,
    'target_shift': dash['target_shift'],
    'planned_day': planned['pieces'],
    'calibrated_day': calibrated['pieces'],
    'forecast_end_of_day': output + forecastRest,
    'forecast_linear': elapsed >= 15 ? (output / elapsed * shift).round() : null,
    'bottleneck_planned': planned['bottleneck'],
    'bottleneck_observed': dash['bottleneck_observed'],
    'hourly': hourly,
    'stations': byStation,
    'notes': notes,
  };
}

// --------------------------------------------------------------------------- animation
/// État d'un paquet à l'instant t, reconstitué depuis la trace `[t, paquet, station, code, ouvrière?]`.
class BundleView {
  final int id;
  final int size;
  final String state; // queue | work | transit
  final int station; // station courante (ou de départ en transit)
  final int? toStation;
  final double progress; // 0..1 en transit / en travail
  final String? worker;
  const BundleView(this.id, this.size, this.state, this.station, {this.toStation, this.progress = 0, this.worker});
}

/// Index de la trace pour l'animation (une passe, puis lecture à n'importe quel instant).
class TwinTrace {
  TwinTrace(Map<String, dynamic> result) {
    final tr = (result['trace'] as Map?) ?? const {};
    final sizes = (tr['bundles'] as Map?) ?? const {};
    for (final e in (tr['bundles'] as Map? ?? const {}).entries) {
      _size[_int(e.key)] = _int(e.value);
    }
    for (final raw in (tr['events'] as List? ?? const [])) {
      final e = raw as List;
      final b = _int(e[1]);
      _byBundle.putIfAbsent(b, () => []).add(e);
    }
    truncated = tr['truncated'] == true;
    order = [for (final s in (result['stations'] as List? ?? const [])) _int((s as Map)['station'])];
    _sizesFallback = sizes.isEmpty ? _int((result['config'] as Map?)?['bundle_size'], 10) : 10;
    snapshots = [for (final s in (result['snapshots'] as List? ?? const [])) s as List];
  }

  final _byBundle = <int, List<List>>{};
  final _size = <int, int>{};
  late final int _sizesFallback;
  late final List<int> order;
  late final List<List> snapshots;
  bool truncated = false;
  bool get isEmpty => _byBundle.isEmpty;

  double get lastTime {
    var t = 0.0;
    for (final evs in _byBundle.values) {
      t = math.max(t, _num(evs.last[0]));
    }
    return t;
  }

  List<BundleView> at(double t) {
    final out = <BundleView>[];
    for (final e in _byBundle.entries) {
      final evs = e.value;
      if (_num(evs.first[0]) > t) continue;
      var i = 0;
      while (i + 1 < evs.length && _num(evs[i + 1][0]) <= t) {
        i++;
      }
      final cur = evs[i];
      final sid = _int(cur[2]), code = _int(cur[3]);
      final size = _size[e.key] ?? _sizesFallback;
      if (code == 0) {
        out.add(BundleView(e.key, size, 'queue', sid));
      } else if (code == 1) {
        final end = i + 1 < evs.length ? _num(evs[i + 1][0]) : t;
        final t0 = _num(cur[0]);
        out.add(BundleView(e.key, size, 'work', sid,
            worker: cur.length > 4 ? '${cur[4]}' : null, progress: end > t0 ? ((t - t0) / (end - t0)).clamp(0, 1) : 0));
      } else {
        if (i + 1 < evs.length) {
          final nxt = evs[i + 1];
          final t0 = _num(cur[0]), t1 = _num(nxt[0]);
          out.add(BundleView(e.key, size, 'transit', sid,
              toStation: _int(nxt[2]), progress: t1 > t0 ? ((t - t0) / (t1 - t0)).clamp(0, 1) : 1));
        } else {
          final idx = order.indexOf(sid);
          if (idx >= 0 && idx + 1 < order.length) {
            out.add(BundleView(e.key, size, 'transit', sid, toStation: order[idx + 1], progress: 0.5));
          }
          // dernier poste : paquet terminé, hors de la ligne
        }
      }
    }
    return out;
  }

  /// Pièces finies jusqu'à t (dernier instantané ≤ t).
  int finishedAt(double t) {
    var n = 0;
    for (final s in snapshots) {
      if (_num(s[0]) <= t) n = _int(s[2]);
    }
    return n;
  }
}
