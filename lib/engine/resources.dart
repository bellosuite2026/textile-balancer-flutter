/// Ressources d'une ligne : partage des opérations longues, postes
/// multi-machines, affectation des postes physiques et des ouvriers
/// (compétences + rendement, méthode hongroise).
///
/// Portage fidèle de `engine/resources.py`.
library;

import 'diagnostics.dart' show stableSort;
import 'models.dart';
import 'pyfmt.dart';

const double _eps = 1e-6;
const String partSep = '#';

// ---------------------------------------------------------------------------
// Fractionnement des opérations longues
// ---------------------------------------------------------------------------

/// Parts d'une opération : k parts pleines (= cadence) + reliquat éventuel.
List<double> splitDurations(double duration, double cycle) {
  if (cycle <= 0 || duration <= cycle + _eps) return [duration];
  final k = (duration / cycle + _eps).floor();
  final rest = duration - k * cycle;
  final parts = List<double>.filled(k, cycle, growable: true);
  if (rest > 1e-3) parts.add(rest);
  return parts;
}

class ExpandedProblem {
  final Problem problem;
  final Map<String, String> origin; // part -> opération d'origine
  ExpandedProblem(this.problem, this.origin);
}

/// Développe les opérations > cadence en parts (mode « share »).
ExpandedProblem expandProblem(Problem problem) {
  final c = problem.targetCycleTime;
  final mode = problem.splitMode.toLowerCase();
  final origin = {for (final o in problem.operations) o.id: o.id};
  if (mode != 'share' || !problem.operations.any((o) => o.duration > c + _eps)) {
    return ExpandedProblem(problem, origin);
  }
  final partsOf = <String, List<String>>{};
  for (final o in problem.operations) {
    final durs = splitDurations(o.duration, c);
    if (durs.length == 1) {
      partsOf[o.id] = [o.id];
      continue;
    }
    final ids = [for (var i = 0; i < durs.length; i++) '${o.id}$partSep${i + 1}'];
    partsOf[o.id] = ids;
    for (final pid in ids) {
      origin[pid] = o.id;
    }
  }
  final newOps = <Operation>[];
  for (final o in problem.operations) {
    final preds = [for (final pr in o.predecessors) ...(partsOf[pr] ?? [pr])];
    final ids = partsOf[o.id]!;
    for (var i = 0; i < ids.length; i++) {
      final pid = ids[i];
      final d = ids.length > 1 ? splitDurations(o.duration, c)[i] : o.duration;
      newOps.add(Operation(
        id: pid,
        name: pid == o.id ? o.name : '${o.name} (part ${i + 1})',
        duration: d,
        predecessors: List.of(preds),
        machineType: o.machineType,
        requiredSkills: List.of(o.requiredSkills),
        section: o.section,
        optional: o.optional,
        taskType: o.taskType,
      ));
    }
  }
  final p = problem.shallowCopy(operations: newOps);
  return ExpandedProblem(p, origin);
}

/// Ramène les stations sur les opérations d'origine ; renvoie l'affectation
/// op -> 1re station et les messages sur les opérations partagées.
(Map<String, int>, List<String>) collapseDetails(
    List<StationDetail> details, Map<String, String> origin, Map<String, double> durations) {
  final assign = <String, int>{};
  final where = <String, List<(int, double)>>{};
  for (final sd in details) {
    final ops = <String>[];
    final shares = <String, double>{};
    for (final pid in sd.operations) {
      final oid = origin[pid] ?? pid;
      if (pid != oid) {
        shares[oid] = pyRound((shares[oid] ?? 0.0) + durations[pid]!, 3);
        where.putIfAbsent(oid, () => []).add((sd.station, durations[pid]!));
      }
      if (!ops.contains(oid)) ops.add(oid);
      assign.putIfAbsent(oid, () => sd.station);
    }
    sd.operations = ops;
    if (shares.isNotEmpty) sd.shares = shares;
  }
  final msgs = <String>[];
  for (final e in where.entries) {
    final parts = e.value.map((x) => pyFixed(x.$2, 2)).join(' + ');
    final sts = e.value.map((x) => '${x.$1}').join(', ');
    msgs.add('ℹ️ ${e.key} est partagée entre les stations $sts ($parts min)');
  }
  return (assign, msgs);
}

// ---------------------------------------------------------------------------
// Temps de station
// ---------------------------------------------------------------------------

List<String> stationMachineTypes(Iterable<String> opIds, Map<String, Operation> ops) {
  final seen = <String>[];
  for (final o in opIds) {
    final m = ops[o]!.machineType;
    if (m.isNotEmpty && !seen.contains(m)) seen.add(m);
  }
  return seen;
}

double stationTime(Iterable<String> opIds, Map<String, Operation> ops, Problem problem) {
  final ids = opIds.toList();
  var t = 0.0;
  for (final o in ids) {
    t += ops[o]!.duration;
  }
  final n = stationMachineTypes(ids, ops).length;
  if (n > 1 && problem.machineChangeTime > 0) t += problem.machineChangeTime * (n - 1);
  return t;
}

// ---------------------------------------------------------------------------
// Compétences et rendement
// ---------------------------------------------------------------------------

bool qualified(Worker worker, Set<String> skills) => worker.skills.toSet().containsAll(skills);

/// Rendement de l'ouvrier sur une opération (matrice de polyvalence).
double opEfficiency(Worker worker, Operation op) {
  final base = worker.efficiency > 0 ? worker.efficiency : 1.0;
  if (op.requiredSkills.isEmpty || worker.skillLevels.isEmpty) return base;
  final lv = [
    for (final s in op.requiredSkills) worker.skillLevels[s] ?? base,
  ].where((v) => v > 0).toList();
  if (lv.isEmpty) return base;
  var m = lv.first;
  for (final v in lv) {
    if (v < m) m = v;
  }
  return m;
}

/// Temps réel d'une station tenue par [worker] (SAM / rendement).
double workerStationTime(Worker worker, Iterable<String> opIds, Map<String, Operation> ops, Problem problem,
    [Map<String, double>? minutes]) {
  final ids = opIds.toList();
  var t = 0.0;
  for (final o in ids) {
    final d = (minutes != null && minutes.isNotEmpty) ? (minutes[o] ?? ops[o]!.duration) : ops[o]!.duration;
    t += d / opEfficiency(worker, ops[o]!);
  }
  final n = stationMachineTypes(ids, ops).length;
  if (n > 1 && problem.machineChangeTime > 0) t += problem.machineChangeTime * (n - 1);
  return t;
}

/// Existe-t-il un ouvrier qualifié DISTINCT pour chaque ensemble de compétences ?
bool staffable(List<Set<String>> skillSets, List<Worker> workers) {
  final sets = skillSets.where((s) => s.isNotEmpty).toList();
  if (sets.isEmpty) return true;
  if (sets.length > workers.length) return false;
  final wsk = [for (final w in workers) w.skills.toSet()];
  final cand = [
    for (final s in sets) [for (var i = 0; i < wsk.length; i++) if (wsk[i].containsAll(s)) i],
  ];
  final match = <int, int>{};

  bool aug(int si, Set<int> seen) {
    for (final wi in cand[si]) {
      if (seen.contains(wi)) continue;
      seen.add(wi);
      if (!match.containsKey(wi) || aug(match[wi]!, seen)) {
        match[wi] = si;
        return true;
      }
    }
    return false;
  }

  final order = List<int>.generate(sets.length, (i) => i);
  stableSort(order, (a, b) => cand[a].length.compareTo(cand[b].length));
  for (final si in order) {
    if (!aug(si, <int>{})) return false;
  }
  return true;
}

/// Affectation de coût minimal (n lignes <= m colonnes). Renvoie la colonne par ligne.
List<int> hungarian(List<List<double>> cost) {
  final n = cost.length;
  if (n == 0) return [];
  final m = cost[0].length;
  const inf = double.infinity;
  final u = List<double>.filled(n + 1, 0.0);
  final v = List<double>.filled(m + 1, 0.0);
  final p = List<int>.filled(m + 1, 0);
  final way = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List<double>.filled(m + 1, inf);
    final used = List<bool>.filled(m + 1, false);
    while (true) {
      used[j0] = true;
      final i0 = p[j0];
      var delta = inf;
      var j1 = 0;
      for (var j = 1; j <= m; j++) {
        if (!used[j]) {
          final cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
          if (cur < minv[j]) {
            minv[j] = cur;
            way[j] = j0;
          }
          if (minv[j] < delta) {
            delta = minv[j];
            j1 = j;
          }
        }
      }
      for (var j = 0; j <= m; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
      if (p[j0] == 0) break;
    }
    while (true) {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
      if (j0 == 0) break;
    }
  }
  final res = List<int>.filled(n, -1);
  for (var j = 1; j <= m; j++) {
    if (p[j] != 0) res[p[j] - 1] = j - 1;
  }
  return res;
}

// ---------------------------------------------------------------------------
// Affectation des postes physiques
// ---------------------------------------------------------------------------

void assignWorkstations(Problem problem, List<StationDetail> details, Map<String, Operation> ops, List<String> warnings) {
  final pool = problem.workstations.where((w) => w.available).toList();
  final used = <String>{};
  final demanded = <String, int>{};
  for (final sd in details) {
    final mts = stationMachineTypes(sd.operations, ops);
    sd.machineTypes = mts;
    final secs = {
      for (final o in sd.operations)
        if (ops[o]!.section.isNotEmpty) ops[o]!.section,
    }.toList()
      ..sort();
    sd.sections = secs;
    for (final m in mts) {
      demanded[m] = (demanded[m] ?? 0) + sd.parallel;
    }
  }
  for (final sd in details) {
    sd.workstation = '';
    sd.workstations = null;
    final mts = sd.machineTypes!;
    if (mts.isEmpty) continue;
    final par = sd.parallel;
    final picked = <String>[];
    final missing = <String>[];
    for (final m in mts) {
      final cands = pool.where((ws) => !used.contains(ws.id) && ws.machineType == m).toList();
      int rank(Workstation w) => (w.section.isNotEmpty && sd.sections!.contains(w.section)) ? 0 : 1;
      stableSort(cands, (a, b) => rank(a).compareTo(rank(b)));
      final take = cands.take(par).toList();
      if (take.length < par) missing.add(m);
      for (final w in take) {
        used.add(w.id);
        picked.add(w.id);
      }
    }
    if (picked.isNotEmpty && missing.isEmpty) {
      sd.workstation = picked.first;
      sd.workstations = picked;
    } else {
      for (final w in picked) {
        used.remove(w);
      }
      warnings.add('⚠️ Station ${sd.station} : aucun poste disponible pour la/les machine(s) '
          '${(missing.isNotEmpty ? missing : mts).join(', ')}');
    }
  }
  for (final sd in details) {
    if (sd.machineTypes!.isNotEmpty) continue;
    final free = pool.where((ws) => !used.contains(ws.id) && (demanded[ws.machineType] ?? 0) == 0).toList();
    if (free.isNotEmpty) {
      used.add(free.first.id);
      sd.workstation = free.first.id;
      sd.workstations = [free.first.id];
    }
  }
}

// ---------------------------------------------------------------------------
// Affectation des ouvriers (méthode hongroise)
// ---------------------------------------------------------------------------

Map<String, int> assignWorkers(Problem problem, List<StationDetail> details, Map<String, Operation> ops, List<String> warnings) {
  final workers = problem.workers.where((w) => w.available).toList();
  for (final sd in details) {
    sd.workers = [];
    sd.workerIds = [];
  }
  if (workers.isEmpty) return {};
  final slots = <(StationDetail, Set<String>)>[];
  final needOf = <StationDetail, Set<String>>{};
  for (final sd in details) {
    final need = <String>{};
    for (final o in sd.operations) {
      need.addAll(ops[o]!.requiredSkills);
    }
    needOf[sd] = need;
    for (var k = 0; k < sd.parallel; k++) {
      slots.add((sd, need));
    }
  }
  final order = List<int>.generate(slots.length, (i) => i);
  stableSort(order, (a, b) => (slots[a].$2.isNotEmpty ? 0 : 1).compareTo(slots[b].$2.isNotEmpty ? 0 : 1));
  final skillSlots = [for (final i in order) if (slots[i].$2.isNotEmpty) i];
  final freeSlots = [for (final i in order) if (slots[i].$2.isEmpty) i];
  const big = 1e6;
  final taken = <int, int>{};

  void solve(List<int> slotIds, List<int> wkIds, bool requireSkill) {
    if (slotIds.isEmpty || wkIds.isEmpty) return;
    final rows = slotIds, cols = wkIds;
    var cost = <List<double>>[];
    for (final si in rows) {
      final (sd, need) = slots[si];
      final par = sd.parallel;
      final row = <double>[];
      for (final wi in cols) {
        final w = workers[wi];
        if (requireSkill && !qualified(w, need)) {
          row.add(big);
        } else {
          final t = workerStationTime(w, sd.operations, ops, problem, sd.shares) / par;
          row.add(t + 1e-4 * w.skills.length);
        }
      }
      cost.add(row);
    }
    final transposed = rows.length > cols.length;
    if (transposed) {
      cost = [
        for (var j = 0; j < cols.length; j++) [for (var i = 0; i < rows.length; i++) cost[i][j]],
      ];
    }
    final res = hungarian(cost);
    for (var a = 0; a < res.length; a++) {
      final b = res[a];
      if (b < 0) continue;
      final si = transposed ? rows[b] : rows[a];
      final wi = transposed ? cols[a] : cols[b];
      final need = slots[si].$2;
      if (requireSkill && !qualified(workers[wi], need)) continue;
      taken[si] = wi;
    }
  }

  solve(skillSlots, List<int>.generate(workers.length, (i) => i), true);
  final takenW = taken.values.toSet();
  final rest = [for (var wi = 0; wi < workers.length; wi++) if (!takenW.contains(wi)) wi];
  solve(freeSlots, rest, false);

  final out = <String, int>{};
  final keys = taken.keys.toList()..sort();
  for (final si in keys) {
    final sd = slots[si].$1;
    final w = workers[taken[si]!];
    sd.workers.add(w.name);
    sd.workerIds!.add(w.id);
    out[w.id] = sd.station;
  }
  final c = problem.targetCycleTime;
  for (final sd in details) {
    final need = needOf[sd] ?? <String>{};
    final par = sd.parallel;
    if (sd.workerIds!.isNotEmpty) {
      final ws = [for (final i in sd.workerIds!) problem.getWorker(i)!];
      final times = [for (final w in ws) workerStationTime(w, sd.operations, ops, problem, sd.shares) / par];
      var sum = 0.0;
      for (final t in times) {
        sum += t;
      }
      final wt = pyRound(sum / times.length, 3);
      final base = sd.totalTime;
      sd.workerTime = wt;
      sd.workerEfficiency = wt > 0 ? pyRound(base / wt, 3) : 1.0;
      if (wt > c + _eps && sd.totalTime <= c + _eps) {
        warnings.add('⚠️ Station ${sd.station} : ${pyFixed(wt, 2)} min au rendement de '
            '${ws.map((w) => w.name).join(', ')} (> cadence ${pyFixed(c, 2)})');
      }
    }
    if (need.isNotEmpty && sd.workerIds!.length < par) {
      final sk = need.toList()..sort();
      warnings.add('⚠️ Station ${sd.station} : aucun ouvrier disponible ne maîtrise TOUTES les compétences '
          'requises (${sk.join(', ')})');
    }
  }
  return out;
}
