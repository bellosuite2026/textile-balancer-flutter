/// Solveur RPW (Ranked Positional Weight, Helgeson & Birnie 1961) v2.2 :
/// stations multi-machines, opérations longues partagées (parts + reliquat),
/// sections en préférence ou strictes, pourvoi des stations par des ouvriers
/// distincts (couplage), puis postes et ouvriers (méthode hongroise).
///
/// Portage fidèle de `engine/solvers/rpw_solver.py` + `find_min_cycle`
/// (`engine/solvers/__init__.py`) + `result_out` (`api/conversion.py`).
/// Les tests de parité (test/engine_parity_test.dart) comparent ce code aux
/// sorties du moteur Python sur des cas réels.
library;

import 'dart:math' as math;

import 'diagnostics.dart';
import 'models.dart';
import 'pyfmt.dart';
import 'resources.dart';

class _Cur {
  List<String> ops = [];
  List<String> types = [];
  String section = '';
  int par = 1;
}

class _Raw {
  final bool success;
  final String status;
  final List<StationDetail> details;
  final LineKpis kpis;
  final Map<String, int> opAssign;
  final Map<String, String> workerAssign;
  final List<String> warnings;
  final String error;
  _Raw(this.success, this.status, this.details, this.kpis, this.opAssign, this.workerAssign, this.warnings, this.error);
}

/// Poids positionnel : durée + somme des poids des successeurs immédiats.
Map<String, double> computeRpw(Problem p) {
  final ops = {for (final o in p.operations) o.id: o};
  final successors = <String, List<String>>{};
  for (final op in p.operations) {
    for (final pred in op.predecessors) {
      successors.putIfAbsent(pred, () => []).add(op.id);
    }
  }
  final rpw = <String, double>{};
  final visiting = <String>{};
  double calc(String id) {
    final known = rpw[id];
    if (known != null) return known;
    if (!visiting.add(id)) return ops[id]!.duration; // cycle : garde-fou
    var s = 0.0;
    for (final succ in successors[id] ?? const <String>[]) {
      s += calc(succ);
    }
    visiting.remove(id);
    return rpw[id] = ops[id]!.duration + s;
  }

  for (final op in p.operations) {
    calc(op.id);
  }
  return rpw;
}

int _cmpKey(List<double> a, List<double> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

/// Premier maximum (comme `max()` Python).
T _maxBy<T>(List<T> items, List<double> Function(T) key) {
  var best = items.first;
  var bk = key(best);
  for (final it in items.skip(1)) {
    final k = key(it);
    if (_cmpKey(k, bk) > 0) {
      best = it;
      bk = k;
    }
  }
  return best;
}

_Raw _solveOnce(Problem original, int? maxStationsArg, {required bool reserveSlack, required int reserveMargin}) {
  final ex = expandProblem(original);
  final p = ex.problem;
  final origin = ex.origin;
  final maxStations = maxStationsArg ?? p.operations.length;
  final c = p.targetCycleTime;
  final mct = math.max(0.0, p.machineChangeTime);
  final maxm = math.max(1, p.maxMachinesPerStation <= 0 ? 1 : p.maxMachinesPerStation);
  final strictSec = p.sectionPolicy.toLowerCase() == 'strict';
  final legacyParallel = p.splitMode.toLowerCase() == 'parallel';
  final ops = {for (final o in p.operations) o.id: o};
  final rpw = computeRpw(p);

  final hasWs = p.workstations.any((w) => w.available);
  final remaining = <String, int>{};
  for (final ws in p.workstations) {
    if (ws.available) remaining[ws.machineType] = (remaining[ws.machineType] ?? 0) + 1;
  }
  int rem(String m) => remaining[m] ?? 0;
  final workers = p.workers.where((w) => w.available).toList();
  final anyWorkerAvailable = workers.isNotEmpty;
  final closedSets = <Set<String>>[];

  final assigned = <String>{};
  final details = <StationDetail>[];
  final cur = _Cur();
  var currentStation = 1;

  double tOf(List<String> list) {
    final n = stationMachineTypes(list, ops).length;
    var s = 0.0;
    for (final o in list) {
      s += ops[o]!.duration;
    }
    return s + (n > 1 ? mct * (n - 1) : 0.0);
  }

  Set<String> needOf(List<String> list) => {for (final o in list) ...ops[o]!.requiredSkills};

  final remWork = <String, double>{};
  for (final o in p.operations) {
    if (o.machineType.isNotEmpty) remWork[o.machineType] = (remWork[o.machineType] ?? 0.0) + o.duration;
  }

  bool machineReserveOk(String opId, double tNew, [int par = 1]) {
    final m = ops[opId]!.machineType;
    if (!(hasWs && m.isNotEmpty)) return true;
    final rw = remWork[m] ?? 0.0;
    final left = rw - ops[opId]!.duration - (reserveSlack ? math.max(0.0, c - tNew) : 0.0);
    final need = c > 0 ? (math.max(0.0, left) / c - 1e-6).ceil() : 0;
    final margin = (cur.ops.isNotEmpty && rw - ops[opId]!.duration > 1e-6) ? reserveMargin : 0;
    return rem(m) - par >= need + margin;
  }

  bool fits(String opId) {
    final o = ops[opId]!;
    final st = cur.ops;
    if (st.isEmpty) {
      final par = legacyParallel ? parallelReplicas(o, c) : 1;
      if (o.machineType.isNotEmpty && hasWs && rem(o.machineType) < par) return false;
      if (maxm > 1 && !machineReserveOk(opId, o.duration / par, par)) return false;
      if (workers.isNotEmpty &&
          o.requiredSkills.isNotEmpty &&
          !staffable([...closedSets, for (var i = 0; i < par; i++) o.requiredSkills.toSet()], workers)) {
        return false;
      }
      return true;
    }
    if (cur.par > 1) return false;
    final next = [...st, opId];
    if (tOf(next) > c + 1e-6) return false;
    final m = o.machineType;
    if (m.isNotEmpty && !cur.types.contains(m)) {
      if (cur.types.length + 1 > maxm) return false;
      if (hasWs && rem(m) < 1) return false;
      if (!machineReserveOk(opId, tOf(next))) return false;
    }
    if (strictSec && cur.section.isNotEmpty && o.section.isNotEmpty && o.section != cur.section) return false;
    if (workers.isNotEmpty) {
      final need = needOf(next);
      if (need.isNotEmpty && !staffable([...closedSets, need], workers)) return false;
    }
    return true;
  }

  void add(String opId) {
    final o = ops[opId]!;
    if (cur.ops.isEmpty) {
      cur.par = (legacyParallel && o.duration > c + 1e-6) ? parallelReplicas(o, c) : 1;
    }
    if (o.machineType.isNotEmpty && !cur.types.contains(o.machineType)) {
      cur.types.add(o.machineType);
      if (hasWs) remaining[o.machineType] = rem(o.machineType) - cur.par;
    }
    if (o.section.isNotEmpty && cur.section.isEmpty) cur.section = o.section;
    cur.ops.add(opId);
    if (o.machineType.isNotEmpty) remWork[o.machineType] = (remWork[o.machineType] ?? 0.0) - o.duration;
    assigned.add(opId);
  }

  void close() {
    final par = cur.par;
    final t = tOf(cur.ops) / par;
    final need = needOf(cur.ops);
    if (workers.isNotEmpty && need.isNotEmpty && staffable([...closedSets, for (var i = 0; i < par; i++) need], workers)) {
      for (var i = 0; i < par; i++) {
        closedSets.add(need);
      }
    }
    details.add(StationDetail(
      station: currentStation,
      totalTime: pyRound(t, 3),
      loadPct: c > 0 ? pyRound(t / c * 100, 1) : 0,
      operations: List.of(cur.ops),
      workers: [],
      workstation: '',
      parallel: par,
    ));
    cur
      ..ops = []
      ..types = []
      ..section = ''
      ..par = 1;
  }

  List<String> available() {
    final out = <String>[];
    final anyWs = p.workstations.any((ws) => ws.available);
    for (final op in p.operations) {
      if (assigned.contains(op.id)) continue;
      if (op.predecessors.every(assigned.contains)) {
        if (op.machineType.isNotEmpty && anyWs) {
          final hasMachine = p.workstations.any((ws) => ws.machineType == op.machineType && ws.available);
          if (!hasMachine) continue;
        }
        if (op.requiredSkills.isNotEmpty && anyWorkerAvailable) {
          final hasSkill = p.workers.any((w) => w.available && op.requiredSkills.every(w.skills.contains));
          if (!hasSkill) continue;
        }
        out.add(op.id);
      }
    }
    return out;
  }

  final nOps = p.operations.length;
  while (assigned.length < nOps && currentStation <= maxStations) {
    final avail = available();
    var candidates = avail.where(fits).toList();
    if (candidates.isEmpty) {
      if (cur.ops.isNotEmpty) {
        close();
        currentStation += 1;
        continue;
      }
      if (avail.isEmpty) break;
      var pool = avail
          .where((o) => !(hasWs && ops[o]!.machineType.isNotEmpty && rem(ops[o]!.machineType) < 1))
          .toList();
      if (pool.isEmpty) pool = avail;
      candidates = [_maxBy(pool, (o) => [rpw[o] ?? 0.0])];
    }
    List<double> key(String o) {
      final op = ops[o]!;
      if (cur.ops.isEmpty) return [rpw[o] ?? 0.0];
      final sameM = (op.machineType.isEmpty || cur.types.contains(op.machineType)) ? 1.0 : 0.0;
      final sameS = (cur.section.isNotEmpty && op.section == cur.section) ? 1.0 : 0.0;
      return [sameM, sameS, rpw[o] ?? 0.0];
    }

    add(_maxBy(candidates, key));
  }
  if (cur.ops.isNotEmpty) close();

  // Retour aux opérations d'origine (parts d'opérations partagées)
  final durations = {for (final o in p.operations) o.id: o.duration};
  final (opAssign, splitMsgs) = collapseDetails(details, origin, durations);

  final warnings = <String>['Solution RPW (heuristique) - non garantie optimale'];
  final origOps = {for (final o in original.operations) o.id: o};
  assignWorkstations(original, details, origOps, warnings);
  assignWorkers(original, details, origOps, warnings);
  warnings.addAll(splitMsgs);

  final k = lineKpis(original, details);
  final issues = precheck(original);
  warnings.insertAll(1, [for (final i in issues) if (i.severity == 'warning') i.toString()]);
  final violations = validateResult(original, details);
  final unassigned = [for (final o in original.operations) if (!opAssign.containsKey(o.id)) o.id];
  final ok = violations.isEmpty && unassigned.isEmpty;
  var err = '';
  if (!ok) {
    final msgs = [for (final v in violations) v.toString()];
    if (unassigned.isNotEmpty) msgs.insert(0, 'Opérations non affectées : ${unassigned.join(', ')}');
    final hints = [for (final i in issues) if (i.severity == 'error') i.toString()];
    err = 'Solution non conforme : ${[...msgs, ...hints].join(' | ')}';
  }
  final workerAssign = <String, String>{
    for (final sd in details)
      for (final wid in sd.workerIds ?? const <String>[]) wid: 'WS${sd.station}',
  };
  return _Raw(ok, ok ? 'FEASIBLE' : 'INFEASIBLE_CONSTRAINTS', details, k, opAssign, workerAssign, warnings, err);
}

/// Point d'entrée RPW (multi-départ, comme `solve_rpw` Python). [maxStations]
/// n'est appliqué que s'il est donné (l'API passe `problem.max_stations`). Renvoie le
/// résultat au format `ResultOut` de l'API (KPI et violations recalculés sur
/// le problème d'origine, champ `compliant`).
BalanceResult solveRpw(Problem problem, {int? maxStations}) {
  final sw = Stopwatch()..start();
  final variants = <(int?, String?, bool, int)>[(null, null, true, 0)];
  if (problem.maxMachinesPerStation > 1) {
    variants.addAll([
      (null, null, false, 0),
      (null, null, false, 1),
      (null, 'strict', false, 1),
      (1, 'strict', true, 0),
    ]);
  }
  _Raw? first;
  _Raw? best;
  (int, double)? bestKey;
  for (final (mm, sec, slack, margin) in variants) {
    final p = (mm == null && sec == null)
        ? problem
        : problem.shallowCopy(maxMachinesPerStation: mm, sectionPolicy: sec);
    final r = _solveOnce(p, maxStations, reserveSlack: slack, reserveMargin: margin);
    first ??= r;
    if (r.success) {
      var ops = 0;
      for (final sd in r.details) {
        ops += sd.parallel;
      }
      final key = (ops, -r.kpis.efficiency);
      if (bestKey == null || key.$1 < bestKey.$1 || (key.$1 == bestKey.$1 && key.$2 < bestKey.$2)) {
        bestKey = key;
        best = r;
      }
    }
  }
  final r = best ?? first!;
  sw.stop();
  return _resultOut(problem, r, sw.elapsedMicroseconds / 1e6);
}

BalanceResult _resultOut(Problem prob, _Raw r, double seconds) {
  final details = r.details;
  final kpis = details.isNotEmpty ? lineKpis(prob, details) : null;
  final violations = details.isNotEmpty ? validateResult(prob, details) : <Issue>[];
  return BalanceResult(
    success: r.success,
    compliant: r.success && violations.isEmpty,
    status: r.status,
    solver: 'RPW',
    solveTimeSeconds: pyRound(seconds, 4),
    targetCycleTime: prob.targetCycleTime,
    stationsUsed: details.length,
    actualCycleTime: r.kpis.actualCycleTime,
    efficiency: r.kpis.efficiency,
    balanceDelay: r.kpis.balanceDelay,
    smoothnessIndex: r.kpis.smoothnessIndex,
    operators: kpis?.operators ?? 0,
    stationDetails: details,
    operationAssignments: r.opAssign,
    workerAssignments: r.workerAssign,
    warnings: r.warnings,
    errorMessage: r.error,
    violations: violations,
  );
}

/// Plus petite cadence (min/pièce) pour laquelle RPW trouve une solution
/// conforme (recherche dichotomique, `find_min_cycle` Python).
MinCycleResult findMinCycleRpw(Problem problem, {double precision = 0.05}) {
  final ops = problem.operations;
  if (ops.isEmpty) return const MinCycleResult(found: false);
  var total = 0.0;
  for (final o in ops) {
    total += o.duration;
  }
  final nAvail = problem.workers.where((w) => w.available).length;
  var lo = math.max(total / math.max(1, nAvail != 0 ? nAvail : ops.length), 1e-3);
  final cnt = <String, int>{};
  for (final ws in problem.workstations) {
    if (ws.available) cnt[ws.machineType] = (cnt[ws.machineType] ?? 0) + 1;
  }
  if (cnt.isNotEmpty) {
    final load = <String, double>{};
    for (final o in ops) {
      if (o.machineType.isNotEmpty) load[o.machineType] = (load[o.machineType] ?? 0.0) + o.duration;
    }
    for (final e in load.entries) {
      final n = cnt[e.key] ?? 0;
      if (n > 0) lo = math.max(lo, e.value / n);
    }
  }
  var hi = math.max(total, lo) * 1.01;

  BalanceResult? run(double c) {
    final p = problem.shallowCopy(targetCycleTime: c);
    final r = solveRpw(p);
    return r.success ? r : null;
  }

  var best = run(hi);
  if (best == null) return const MinCycleResult(found: false);
  var bestC = hi;
  while (hi - lo > precision) {
    final mid = (lo + hi) / 2;
    final r = run(mid);
    if (r != null) {
      hi = mid;
      best = r;
      bestC = mid;
    } else {
      lo = mid;
    }
  }
  return MinCycleResult(found: true, minCycleTime: pyRound(bestC, 3), result: best);
}

/// Nombre minimal théorique de stations N_min = ⌈T / C⌉.
int theoreticalMinStations(double totalSam, double cycle) =>
    cycle > 0 ? (totalSam / cycle - 1e-9).ceil() : 0;

/// Takt (min/pièce) = minutes productives disponibles / quantité demandée.
double taktTime({required double availableMinutes, required double quantity}) =>
    quantity > 0 ? availableMinutes / quantity : 0;

/// Cadence à planifier = takt × rendement attendu (85 % par défaut).
double cycleFromObjective({
  required double quantity,
  required double days,
  required double hoursPerDay,
  double expectedEfficiency = 0.85,
}) =>
    taktTime(availableMinutes: days * hoursPerDay * 60, quantity: quantity) * expectedEfficiency;
