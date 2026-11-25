/// Diagnostics de faisabilité, validation des résultats et KPI de ligne.
///
/// Portage fidèle de `engine/diagnostics.py` (moteur Python de référence) :
/// mêmes codes (CYCLE_INVALID, PRED_UNKNOWN, OP_GT_CYCLE, MACHINE_MISSING,
/// MACHINE_CAPACITY, SKILL_MISSING, SKILL_CAPACITY, WORKERS_SHORT,
/// CYCLE_EXCEEDED, NO_WORKSTATION, NO_WORKER), mêmes messages, mêmes arrondis.
/// Ajout Dart : PRECEDENCE_VIOLATION (contrôle a posteriori de l'ordre des stations).
library;

import 'dart:math' as math;

import 'models.dart';
import 'pyfmt.dart';

const double eps = 1e-6;

/// Nombre de postes parallèles requis pour tenir le cycle (>= 1).
int parallelReplicas(Operation op, double cycle) {
  if (cycle <= 0) return 1;
  return math.max(1, (op.duration / cycle - eps).ceil());
}

List<Issue> precheck(Problem problem, {bool allowParallel = true}) {
  final issues = <Issue>[];
  final c = problem.targetCycleTime;
  final ops = problem.operations;
  if (c <= 0) {
    return [const Issue('CYCLE_INVALID', 'error', 'Le temps de cycle cible doit être > 0.')];
  }
  final ids = {for (final o in ops) o.id};

  for (final o in ops) {
    for (final p in o.predecessors) {
      if (!ids.contains(p)) {
        issues.add(Issue('PRED_UNKNOWN', 'error', '${o.id} référence un prédécesseur inconnu « $p ».',
            'Corriger la colonne Predecesseurs du fichier SAM.'));
      }
    }
  }

  for (final o in ops.where((o) => o.duration > c + eps)) {
    final n = parallelReplicas(o, c);
    if (allowParallel) {
      issues.add(Issue('OP_GT_CYCLE', 'warning',
          '${o.id} (${pyFixed(o.duration, 2)} min) dépasse le cycle ${pyFixed(c, 2)} min.',
          'Dédoublement automatique sur $n postes parallèles.'));
    } else {
      issues.add(Issue('OP_GT_CYCLE', 'error',
          '${o.id} (${pyFixed(o.duration, 2)} min) dépasse le cycle ${pyFixed(c, 2)} min.',
          'Autoriser $n postes en parallèle ou passer le cycle à ≥ ${pyFixed(o.duration, 2)} min.'));
    }
  }

  final availWs = problem.workstations.where((w) => w.available).toList();
  final wsCount = <String, int>{};
  for (final w in availWs) {
    wsCount[w.machineType] = (wsCount[w.machineType] ?? 0) + 1;
  }
  if (availWs.isNotEmpty) {
    final load = <String, double>{};
    final need = <String, int>{};
    for (final o in ops) {
      if (o.machineType.isNotEmpty) {
        load[o.machineType] = (load[o.machineType] ?? 0.0) + o.duration;
        need[o.machineType] = math.max(need[o.machineType] ?? 0, parallelReplicas(o, c));
      }
    }
    for (final e in load.entries) {
      final m = e.key, total = e.value;
      final have = wsCount[m] ?? 0;
      final mini = math.max((total / c - eps).ceil(), need[m] ?? 0);
      if (have == 0) {
        issues.add(Issue('MACHINE_MISSING', 'error',
            'Aucun poste « $m » disponible (${pyFixed(total, 2)} min de travail).',
            'Ajouter au moins $mini poste(s) $m.'));
      } else if (have < mini) {
        issues.add(Issue(
            'MACHINE_CAPACITY',
            'error',
            '${pyFixed(total, 2)} min sur « $m » demandent ≥ $mini poste(s) au cycle ${pyFixed(c, 2)} ; $have disponible(s).',
            'Ajouter ${mini - have} poste(s) $m ou allonger le cycle à ≥ ${pyFixed(total / have, 2)} min.'));
      }
    }
  }

  final availWorkers = problem.workers.where((w) => w.available).toList();
  if (availWorkers.isNotEmpty) {
    for (final o in ops) {
      if (o.requiredSkills.isNotEmpty &&
          !availWorkers.any((w) => o.requiredSkills.every((s) => w.skills.contains(s)))) {
        issues.add(Issue('SKILL_MISSING', 'error',
            'Aucun ouvrier ne maîtrise ${o.requiredSkills.join(', ')} (${o.id}).',
            'Former un ouvrier ou corriger les compétences requises.'));
      }
    }
    issues.addAll(_skillCapacity(ops, availWorkers, c));
    var total = 0.0;
    for (final o in ops) {
      total += o.duration;
    }
    final mini = (total / c - eps).ceil();
    if (availWorkers.length < mini) {
      issues.add(Issue(
          'WORKERS_SHORT',
          'error',
          '${pyFixed(total, 2)} min de travail exigent ≥ $mini opérateurs au cycle ${pyFixed(c, 2)} ; ${availWorkers.length} disponibles.',
          'Allonger le cycle à ≥ ${pyFixed(total / availWorkers.length, 2)} min ou renforcer l\'effectif.'));
    }
  }
  return issues;
}

String _setKey(Iterable<String> s) => (s.toSet().toList()..sort()).join('\u0000');

Iterable<List<T>> combinations<T>(List<T> items, int k) sync* {
  final n = items.length;
  if (k > n || k <= 0) return;
  final idx = List<int>.generate(k, (i) => i);
  while (true) {
    yield [for (final i in idx) items[i]];
    var i = k - 1;
    while (i >= 0 && idx[i] == i + n - k) {
      i--;
    }
    if (i < 0) return;
    idx[i]++;
    for (var j = i + 1; j < k; j++) {
      idx[j] = idx[j - 1] + 1;
    }
  }
}

/// Condition de Hall sur les compétences (code SKILL_CAPACITY).
List<Issue> _skillCapacity(List<Operation> ops, List<Worker> workers, double c) {
  final groups = <String, List<Operation>>{};
  final groupSkills = <String, Set<String>>{};
  for (final o in ops) {
    if (o.requiredSkills.isNotEmpty) {
      final k = _setKey(o.requiredSkills);
      groups.putIfAbsent(k, () => []).add(o);
      groupSkills[k] = o.requiredSkills.toSet();
    }
  }
  final keys = groups.keys.toList();
  if (keys.isEmpty) return [];
  final wsk = [for (final w in workers) (w, w.skills.toSet())];
  final maxK = keys.length <= 40 ? 3 : 2;
  final worst = <String, ({int deficit, List<String> combo, double work, List<Worker> able, int need})>{};
  for (var k = 1; k <= math.min(maxK, keys.length); k++) {
    for (final combo in combinations(keys, k)) {
      var work = 0.0;
      for (final g in combo) {
        for (final o in groups[g]!) {
          work += o.duration;
        }
      }
      final able = [
        for (final (w, s) in wsk)
          if (combo.any((g) => s.containsAll(groupSkills[g]!))) w,
      ];
      if (able.isEmpty) continue;
      final need = (work / c - eps).ceil();
      if (able.length < need) {
        final key = _setKey(able.map((w) => w.id));
        final deficit = need - able.length;
        final prev = worst[key];
        if (prev == null || deficit > prev.deficit) {
          worst[key] = (deficit: deficit, combo: combo, work: work, able: able, need: need);
        }
      }
    }
  }
  final sorted = worst.values.toList();
  stableSort(sorted, (a, b) => b.deficit.compareTo(a.deficit));
  final out = <Issue>[];
  for (final t in sorted.take(5)) {
    final opIds = [for (final g in t.combo) for (final o in groups[g]!) o.id]..sort();
    final skills = {for (final g in t.combo) ...groupSkills[g]!}.toList()..sort();
    final names = t.able.map((w) => w.name.isNotEmpty ? w.name : w.id).join(', ');
    out.add(Issue(
        'SKILL_CAPACITY',
        'error',
        '${opIds.join(', ')} (${pyFixed(t.work, 2)} min, compétences ${skills.join(', ')}) ne peuvent être faites '
            'que par ${t.able.length} ouvrier(s) ($names) ; il en faut ≥ ${t.need} '
            'à la cadence ${pyFixed(c, 2)}.',
        'Former ${t.deficit} ouvrier(s) de plus sur ${skills.join(', ')} ou allonger la cadence '
            '(au moins ${pyFixed(t.work / t.able.length, 2)} min, davantage selon le découpage des opérations).'));
  }
  return out;
}

/// KPI de ligne (même définition que `line_kpis` Python).
class LineKpis {
  final int operators;
  final double actualCycleTime;
  final double efficiency;
  final double balanceDelay;
  final double smoothnessIndex;
  const LineKpis(this.operators, this.actualCycleTime, this.efficiency, this.balanceDelay, this.smoothnessIndex);
}

LineKpis lineKpis(Problem problem, List<StationDetail> details) {
  final c = problem.targetCycleTime;
  final placed = {for (final sd in details) ...sd.operations};
  var totalWork = 0.0;
  for (final o in problem.operations) {
    if (placed.contains(o.id)) totalWork += o.duration;
  }
  var operators = 0;
  for (final sd in details) {
    operators += sd.parallel;
  }
  var actual = 0.0;
  if (details.isNotEmpty) {
    actual = details.first.totalTime;
    for (final sd in details) {
      if (sd.totalTime > actual) actual = sd.totalTime;
    }
  }
  final effCycle = math.max(c, actual);
  final eff = (operators > 0 && effCycle > 0) ? totalWork / (operators * effCycle) * 100 : 0.0;
  var sq = 0.0;
  for (final sd in details) {
    final d = actual - sd.totalTime;
    sq += d * d;
  }
  final smooth = details.isNotEmpty ? math.sqrt(sq) : 0.0;
  return LineKpis(operators, pyRound(actual, 3), pyRound(eff, 1), eff > 0 ? pyRound(100 - eff, 1) : 100.0,
      pyRound(smooth, 2));
}

Operation _op(Problem p, String id) {
  final o = p.getOperation(id);
  if (o == null) throw ArgumentError('Opération inconnue : $id');
  return o;
}

/// Contrôle a posteriori d'une solution (CYCLE_EXCEEDED, NO_WORKSTATION, NO_WORKER).
List<Issue> validateResult(Problem problem, List<StationDetail> details) {
  final c = problem.targetCycleTime;
  final out = <Issue>[];
  for (final sd in details) {
    if (sd.totalTime > c + eps) {
      out.add(Issue('CYCLE_EXCEEDED', 'error',
          'Station ${sd.station} : ${pyFixed(sd.totalTime, 2)} min > cycle ${pyFixed(c, 2)} min.'));
    }
  }
  if (problem.workstations.isNotEmpty) {
    for (final sd in details) {
      final needsMachine = sd.operations.any((o) => _op(problem, o).machineType.isNotEmpty);
      if (needsMachine && sd.workstation.isEmpty && (sd.workstations == null || sd.workstations!.isEmpty)) {
        out.add(Issue('NO_WORKSTATION', 'error',
            'Station ${sd.station} : aucun poste physique compatible disponible.'));
      }
    }
  }
  if (problem.workers.isNotEmpty) {
    for (final sd in details) {
      final needSkill = sd.operations.any((o) => _op(problem, o).requiredSkills.isNotEmpty);
      final n = (sd.workerIds ?? sd.workers).length;
      if (needSkill && n < sd.parallel) {
        out.add(Issue('NO_WORKER', 'error', 'Station ${sd.station} : ouvrier(s) qualifié(s) manquant(s).'));
      }
    }
  }
  return out;
}

/// Contrôle supplémentaire (Dart) : chaque opération est dans une station
/// postérieure ou égale à celles de ses prédécesseurs.
List<Issue> precedenceViolations(Problem problem, List<StationDetail> details) {
  final first = <String, int>{};
  final last = <String, int>{};
  for (final sd in details) {
    for (final o in sd.operations) {
      first.putIfAbsent(o, () => sd.station);
      last[o] = sd.station;
    }
  }
  final out = <Issue>[];
  for (final o in problem.operations) {
    final so = first[o.id];
    if (so == null) continue;
    for (final p in o.predecessors) {
      final sp = last[p];
      if (sp != null && sp > so) {
        out.add(Issue('PRECEDENCE_VIOLATION', 'error',
            '${o.id} (station $so) est placée avant son prédécesseur $p (station $sp).'));
      }
    }
  }
  return out;
}

/// Cohérence du problème (`LineBalancingProblem.validate()`).
List<String> validateProblem(Problem p) {
  final errors = <String>[];
  final ids = {for (final o in p.operations) o.id};
  for (final o in p.operations) {
    for (final pred in o.predecessors) {
      if (!ids.contains(pred)) errors.add("Opération ${o.id}: prédécesseur inconnu '$pred'");
    }
  }
  if (hasPrecedenceCycle(p)) errors.add('Cycle détecté dans les contraintes de précédence');
  final required = {for (final o in p.operations) if (o.machineType.isNotEmpty) o.machineType};
  final avail = {for (final w in p.workstations) if (w.available) w.machineType};
  for (final m in required) {
    if (!avail.contains(m)) errors.add("Type machine requis '$m' non disponible dans le parc");
  }
  final reqSk = {for (final o in p.operations) ...o.requiredSkills};
  final availSk = {for (final w in p.workers) if (w.available) ...w.skills};
  for (final s in reqSk) {
    if (!availSk.contains(s)) errors.add("Compétence requise '$s' non disponible dans l'effectif");
  }
  return errors;
}

bool hasPrecedenceCycle(Problem p) {
  final byId = {for (final o in p.operations) o.id: o};
  final state = <String, int>{}; // 1 = en cours, 2 = fini
  bool dfs(String id) {
    state[id] = 1;
    for (final pred in byId[id]?.predecessors ?? const <String>[]) {
      final s = state[pred];
      if (s == 1) return true;
      if (s == null && byId.containsKey(pred) && dfs(pred)) return true;
    }
    state[id] = 2;
    return false;
  }

  for (final o in p.operations) {
    if (state[o.id] == null && dfs(o.id)) return true;
  }
  return false;
}

/// Diagnostic complet avant calcul (`POST /v1/precheck`).
PrecheckResult runPrecheck(Problem p) {
  final issues = precheck(p);
  final errors = validateProblem(p);
  final feasible = !issues.any((i) => i.isError) &&
      !errors.any((e) => e.contains('prédécesseur inconnu') || e.contains('Cycle détecté'));
  return PrecheckResult(feasible: feasible, issues: issues, validationErrors: errors);
}

/// Tri stable (List.sort de Dart ne l'est pas ; Python `sorted` l'est).
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
