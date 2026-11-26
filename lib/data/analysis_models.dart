/// Lecture typée des résultats serveur de la phase 2 :
/// - simulation détaillée (DES, `routes_des.py` → `des.run`) : indicateurs avec intervalles de confiance ;
/// - optimiseur (NSGA-II, `engine/des/optimize.py`) : front de Pareto, nuage des évaluations.
/// Les écrans n'accèdent jamais aux JSON bruts : un changement de format de l'API se corrige ici.
library;

double? _d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => [for (final e in (v as List? ?? const [])) if (e is Map) e.cast<String, dynamic>()];

/// Moyenne ± intervalle de confiance à 95 % (`engine.des.experiment.ci`).
class Ci {
  const Ci({this.mean, this.lo, this.hi, this.sd, this.n = 0});
  final double? mean, lo, hi, sd;
  final int n;

  factory Ci.fromJson(Object? v) {
    if (v is num) return Ci(mean: v.toDouble(), n: 1);
    final m = _m(v);
    return Ci(mean: _d(m['mean']), lo: _d(m['lo']), hi: _d(m['hi']), sd: _d(m['sd']), n: (m['n'] as num?)?.toInt() ?? 0);
  }

  double? get halfWidth => (hi != null && lo != null) ? (hi! - lo!) / 2 : null;
  bool get hasInterval => n > 1 && halfWidth != null && halfWidth! > 0;
}

/// Statut d'une tâche de fond (`twin_simulations`).
class SimJob {
  SimJob(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id']}';
  String get name => '${raw['name'] ?? ''}';
  String get kind => '${raw['kind'] ?? 'twin'}';
  String get status => '${raw['status'] ?? 'queued'}';
  bool get done => status == 'done';
  bool get failed => status == 'failed';
  String get error => '${raw['error'] ?? ''}';
  DateTime? get createdAt => DateTime.tryParse('${raw['created_at'] ?? ''}');
  Map<String, dynamic> get results => _m(raw['results']);
  Map<String, dynamic> get progress => _m(results['progress']);
  int get pct => (_d(progress['pct']) ?? 0).round();
}

// ============================================================================ DES
class DesStation {
  DesStation(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id']}';
  String get label => '${raw['label'] ?? 'Station ${raw['id']}'}';
  int get pieces => (raw['pieces'] as num?)?.toInt() ?? 0;
  double get utilization => _d(raw['utilization_pct']) ?? 0;
  double get downMin => _d(raw['down_min']) ?? 0;
  double get queueAvgPieces => _d(raw['queue_avg_pieces']) ?? 0;
  Map<String, double> get states => {for (final e in _m(raw['states']).entries) e.key: _d(e.value) ?? 0};
}

class DesScenarioResult {
  DesScenarioResult(this.name, this.raw);
  final String name;
  final Map<String, dynamic> raw;

  Map<String, dynamic> get _res => _m(raw['result']);
  Map<String, dynamic> get _reps => _m(_res['replications']);
  int get replications => (_reps['n'] as num?)?.toInt() ?? 1;
  Ci kpi(String key) => Ci.fromJson(_m(_reps['kpis'])[key] ?? _m(_res['kpis'])[key]);
  String? get bottleneck => (_m(_reps['kpis'])['bottleneck'] ?? _m(_res['kpis'])['bottleneck'])?.toString();
  List<DesStation> get stations => [for (final s in _l(_res['stations'])) DesStation(s)];
  Map<String, Ci> get stationUtil => {for (final e in _m(_reps['station_util']).entries) e.key: Ci.fromJson(e.value)};
  List<int> get hourly => [for (final h in (_m(_res['throughput'])['hourly'] as List? ?? const [])) (h as num).toInt()];
  List<(double, double)> get cumulative => [
        for (final p in (_m(_res['throughput'])['cumulative'] as List? ?? const []))
          if (p is List && p.length >= 2) ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ];
  List<String> get notes => [for (final n in (_res['notes'] as List? ?? const [])) '$n'];
  Map<String, dynamic> get overrides => _m(raw['overrides']);
}

class DesComparisonRow {
  DesComparisonRow(this.key, this.label, this.values);
  final String key;
  final String label;
  final List<Ci> values;
}

class DesResult {
  DesResult(this.raw);
  final Map<String, dynamic> raw;
  factory DesResult.fromSimulation(Map<String, dynamic> sim) => DesResult(_m(sim['results']));

  String get engine => '${raw['engine'] ?? ''}';
  int get replications => (raw['replications'] as num?)?.toInt() ?? 1;
  List<DesScenarioResult> get scenarios => [for (final s in _l(raw['scenarios'])) DesScenarioResult('${s['name'] ?? 'Scénario'}', s)];
  List<DesComparisonRow> get comparison => [
        for (final r in _l(raw['comparison']))
          DesComparisonRow('${r['key']}', '${r['label']}', [for (final v in (r['values'] as List? ?? const [])) Ci.fromJson(v)]),
      ];
}

/// Scénario DES du formulaire → `DesScenario` de l'API (`{name, overrides, absent}`).
Map<String, dynamic> desScenarioBody({
  required String name,
  double efficiencyPct = 100,
  double cvPct = 10,
  double mtbfMin = 0,
  double mttrMin = 0,
  double shiftMinutes = 480,
  int bundleSize = 10,
  List<String> absent = const [],
  bool reference = false,
}) =>
    {
      'name': name,
      'overrides': reference
          ? <String, dynamic>{}
          : {
              'settings': {
                'efficiency': efficiencyPct / 100,
                'dist': {'kind': 'normal', 'cv': cvPct / 100},
                'mtbf_min': mtbfMin,
                'mttr_min': mttrMin,
              },
              'shift': {'minutes': shiftMinutes},
              'source': {'bundle_size': bundleSize},
            },
      'absent': absent,
    };

// ============================================================================ optimiseur
class OptObjective {
  OptObjective(this.key, this.label, this.unit, this.sense);
  final String key, label, unit, sense;
}

/// Indicateurs affichables d'une solution (axes du nuage) : clé → (libellé, unité, sens).
const optMetrics = <String, (String, String, String)>{
  'pieces': ('Pièces / jour', 'pcs', 'max'),
  'per_hour': ('Pièces / heure', 'pcs/h', 'max'),
  'people': ('Effectif (personnes)', '', 'min'),
  'operator_util_avg': ('Rendement / occupation opératrices', '%', 'max'),
  'cost_minute': ('Coût minute', 'TND/min', 'min'),
  'cost_piece': ('Coût par pièce', 'TND', 'min'),
  'wip_avg': ('Encours moyen', 'pcs', 'min'),
  'walk_m': ('Marche + transport', 'm', 'min'),
  'lead_time_avg': ('Traversée', 'min', 'min'),
};

class ParetoSolution {
  ParetoSolution(this.raw);
  final Map<String, dynamic> raw;
  int get id => (raw['id'] as num?)?.toInt() ?? 0;
  Map<String, dynamic> get mean => _m(raw['mean']);
  double? metric(String k) => _d(mean[k]);
  Ci kpi(String k) => Ci.fromJson(_m(raw['kpis'])[k] ?? mean[k]);
  List<String> get changes => [for (final c in (raw['changes'] as List? ?? const [])) '$c'];
  Map<String, double?> get vsBase => {for (final e in _m(raw['vs_base']).entries) e.key: _d(e.value)};
  bool get feasible => raw['feasible'] != false;
  String? get bottleneck => mean['bottleneck']?.toString();
}

class OptResult {
  OptResult(this.raw);
  final Map<String, dynamic> raw;
  factory OptResult.fromSimulation(Map<String, dynamic> sim) => OptResult(_m(sim['results']));

  List<OptObjective> get objectives => [
        for (final o in _l(raw['objectives'])) OptObjective('${o['key']}', '${o['label']}', '${o['unit'] ?? ''}', '${o['sense'] ?? 'max'}'),
      ];
  ParetoSolution? get base => raw['base'] == null ? null : ParetoSolution(_m(raw['base']));
  List<ParetoSolution> get pareto => [for (final s in _l(raw['pareto'])) ParetoSolution(s)];

  /// Nuage de toutes les évaluations : (moyennes, réalisable).
  List<(Map<String, dynamic>, bool)> get cloud => [for (final c in _l(raw['cloud'])) (_m(c['mean']), c['feasible'] != false)];
  int get evals => (raw['evals'] as num?)?.toInt() ?? 0;
  double get elapsedS => _d(raw['elapsed_s']) ?? 0;
  String get stoppedBy => '${raw['stopped_by'] ?? ''}';
  bool get feasibleFound => raw['feasible_found'] != false;

  /// Compromis : solution la plus proche du point idéal (indicateurs normalisés sur le front).
  ParetoSolution? compromise([List<String>? keys]) {
    final sols = pareto;
    if (sols.isEmpty) return null;
    final ks = keys ?? [for (final o in objectives) o.key];
    final sense = {for (final o in objectives) o.key: o.sense};
    double score(ParetoSolution s) {
      var sum = 0.0;
      for (final k in ks) {
        final vals = [for (final x in sols) x.metric(k)].whereType<double>().toList();
        final v = s.metric(k);
        if (vals.isEmpty || v == null) continue;
        final lo = vals.reduce((a, b) => a < b ? a : b), hi = vals.reduce((a, b) => a > b ? a : b);
        if (hi - lo < 1e-12) continue;
        final norm = (v - lo) / (hi - lo);
        final gap = (sense[k] ?? optMetrics[k]?.$3 ?? 'max') == 'max' ? 1 - norm : norm;
        sum += gap * gap;
      }
      return sum;
    }

    return sols.reduce((a, b) => score(b) < score(a) ? b : a);
  }
}

/// Configuration de l'optimiseur (`normalize_config`) depuis le formulaire.
Map<String, dynamic> optConfigBody({
  required List<String> objectives,
  double timeBudgetS = 45,
  int replications = 3,
  double costPerMinute = 0.06,
  double? minPerHour,
  int? maxPeople,
  Map<String, bool> vary = const {},
}) =>
    {
      'objectives': objectives,
      'time_budget_s': timeBudgetS,
      'replications': replications,
      'cost_per_minute': costPerMinute,
      'vary': vary,
      'constraints': {
        'min_per_hour': minPerHour,
        'max_people': maxPeople,
      },
    };
