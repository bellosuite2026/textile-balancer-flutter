/// Modèle de données du moteur (Dart pur, aucune dépendance Flutter).
///
/// Miroir exact des schémas de l'API (`api/schemas.py` : OperationIn,
/// WorkstationIn, WorkerIn, ProblemIn, ResultOut, IssueOut) : un même JSON
/// circule entre le stockage local, le moteur Dart et l'API cloud.
library;

double _d(Object? v, [double def = 0.0]) {
  if (v == null) return def;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(',', '.')) ?? def;
}

int _i(Object? v, [int def = 0]) {
  if (v == null) return def;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? def;
}

bool _b(Object? v, [bool def = false]) {
  if (v == null) return def;
  if (v is bool) return v;
  final s = v.toString().toLowerCase().trim();
  return const {'1', 'true', 'oui', 'yes', 'x'}.contains(s);
}

List<String> _sl(Object? v) {
  if (v == null) return [];
  if (v is List) return v.map((e) => e.toString()).toList();
  return v
      .toString()
      .replaceAll(',', ';')
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Une opération de la gamme (SAM en minutes).
class Operation {
  String id;
  String name;
  double duration;
  List<String> predecessors;
  String machineType;
  List<String> requiredSkills;
  String section;
  bool optional;
  String taskType;

  Operation({
    required this.id,
    this.name = '',
    this.duration = 0,
    List<String>? predecessors,
    this.machineType = '',
    List<String>? requiredSkills,
    this.section = '',
    this.optional = false,
    this.taskType = 'VA',
  })  : predecessors = predecessors ?? [],
        requiredSkills = requiredSkills ?? [];

  factory Operation.fromJson(Map<String, dynamic> j) => Operation(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        duration: _d(j['duration']),
        predecessors: _sl(j['predecessors']),
        machineType: (j['machine_type'] ?? '').toString(),
        requiredSkills: _sl(j['required_skills']),
        section: (j['section'] ?? '').toString(),
        optional: _b(j['optional']),
        taskType: (j['task_type'] ?? 'VA').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'duration': duration,
        'predecessors': predecessors,
        'machine_type': machineType,
        'required_skills': requiredSkills,
        'section': section,
        'optional': optional,
        'task_type': taskType,
      };

  Operation copy() => Operation.fromJson(toJson());
}

/// Un poste physique (une machine).
class Workstation {
  String id;
  String name;
  String machineType;
  bool available;
  int maxWorkers;
  String section;

  Workstation({
    required this.id,
    this.name = '',
    this.machineType = '',
    this.available = true,
    this.maxWorkers = 1,
    this.section = '',
  });

  factory Workstation.fromJson(Map<String, dynamic> j) => Workstation(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        machineType: (j['machine_type'] ?? '').toString(),
        available: _b(j['available'], true),
        maxWorkers: _i(j['max_workers'], 1),
        section: (j['section'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'machine_type': machineType,
        'available': available,
        'max_workers': maxWorkers,
        'section': section,
      };

  Workstation copy() => Workstation.fromJson(toJson());
}

/// Un ouvrier, ses compétences et son rendement (1 = 100 %).
class Worker {
  String id;
  String name;
  List<String> skills;
  double efficiency;
  String? assignedStation;
  bool available;

  /// Matrice de polyvalence : rendement par compétence.
  Map<String, double> skillLevels;

  Worker({
    required this.id,
    this.name = '',
    List<String>? skills,
    this.efficiency = 1.0,
    this.assignedStation,
    this.available = true,
    Map<String, double>? skillLevels,
  })  : skills = skills ?? [],
        skillLevels = skillLevels ?? {};

  factory Worker.fromJson(Map<String, dynamic> j) => Worker(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        skills: _sl(j['skills']),
        efficiency: _d(j['efficiency'], 1.0),
        assignedStation: j['assigned_station']?.toString(),
        available: _b(j['available'], true),
        skillLevels: {
          for (final e in ((j['skill_levels'] as Map?) ?? {}).entries)
            e.key.toString(): _d(e.value, 1.0),
        },
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'skills': skills,
        'efficiency': efficiency,
        'assigned_station': assignedStation,
        'available': available,
        'skill_levels': skillLevels,
      };

  Worker copy() => Worker.fromJson(toJson());
}

/// Problème d'équilibrage (= `ProblemIn` de l'API = `payload` d'une gamme).
class Problem {
  String name;
  double targetCycleTime;
  List<Operation> operations;
  List<Workstation> workstations;
  List<Worker> workers;
  int? maxStations;
  Map<String, int> forcedAssignments;
  Map<String, List<int>> forbiddenAssignments;
  List<List<String>> sameStationGroups;
  int maxMachinesPerStation;
  double machineChangeTime;
  String sectionPolicy; // prefer | strict
  String splitMode; // share | parallel

  Problem({
    this.name = 'ligne',
    required this.targetCycleTime,
    List<Operation>? operations,
    List<Workstation>? workstations,
    List<Worker>? workers,
    this.maxStations,
    Map<String, int>? forcedAssignments,
    Map<String, List<int>>? forbiddenAssignments,
    List<List<String>>? sameStationGroups,
    this.maxMachinesPerStation = 3,
    this.machineChangeTime = 0.0,
    this.sectionPolicy = 'prefer',
    this.splitMode = 'share',
  })  : operations = operations ?? [],
        workstations = workstations ?? [],
        workers = workers ?? [],
        forcedAssignments = forcedAssignments ?? {},
        forbiddenAssignments = forbiddenAssignments ?? {},
        sameStationGroups = sameStationGroups ?? [];

  factory Problem.fromJson(Map<String, dynamic> j) => Problem(
        name: (j['name'] ?? 'ligne').toString(),
        targetCycleTime: _d(j['target_cycle_time'], 1.0),
        operations: [for (final o in (j['operations'] as List? ?? [])) Operation.fromJson(Map<String, dynamic>.from(o as Map))],
        workstations: [for (final o in (j['workstations'] as List? ?? [])) Workstation.fromJson(Map<String, dynamic>.from(o as Map))],
        workers: [for (final o in (j['workers'] as List? ?? [])) Worker.fromJson(Map<String, dynamic>.from(o as Map))],
        maxStations: j['max_stations'] == null ? null : _i(j['max_stations']),
        forcedAssignments: {
          for (final e in ((j['forced_assignments'] as Map?) ?? {}).entries) e.key.toString(): _i(e.value),
        },
        forbiddenAssignments: {
          for (final e in ((j['forbidden_assignments'] as Map?) ?? {}).entries)
            e.key.toString(): [for (final v in (e.value as List)) _i(v)],
        },
        sameStationGroups: [
          for (final g in (j['same_station_groups'] as List? ?? [])) [for (final v in (g as List)) v.toString()],
        ],
        maxMachinesPerStation: _i(j['max_machines_per_station'], 3),
        machineChangeTime: _d(j['machine_change_time'], 0.0),
        sectionPolicy: (j['section_policy'] ?? 'prefer').toString(),
        splitMode: (j['split_mode'] ?? 'share').toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'target_cycle_time': targetCycleTime,
        'operations': [for (final o in operations) o.toJson()],
        'workstations': [for (final o in workstations) o.toJson()],
        'workers': [for (final o in workers) o.toJson()],
        'max_stations': maxStations,
        'forced_assignments': forcedAssignments,
        'forbidden_assignments': forbiddenAssignments,
        'same_station_groups': sameStationGroups,
        'max_machines_per_station': maxMachinesPerStation,
        'machine_change_time': machineChangeTime,
        'section_policy': sectionPolicy,
        'split_mode': splitMode,
      };

  /// Copie superficielle (équivalent `copy.copy` Python) avec surcharges.
  Problem shallowCopy({
    double? targetCycleTime,
    int? maxMachinesPerStation,
    String? sectionPolicy,
    List<Operation>? operations,
  }) =>
      Problem(
        name: name,
        targetCycleTime: targetCycleTime ?? this.targetCycleTime,
        operations: operations ?? this.operations,
        workstations: workstations,
        workers: workers,
        maxStations: maxStations,
        forcedAssignments: forcedAssignments,
        forbiddenAssignments: forbiddenAssignments,
        sameStationGroups: sameStationGroups,
        maxMachinesPerStation: maxMachinesPerStation ?? this.maxMachinesPerStation,
        machineChangeTime: machineChangeTime,
        sectionPolicy: sectionPolicy ?? this.sectionPolicy,
        splitMode: splitMode,
      );

  /// Copie profonde (pour l'édition).
  Problem deepCopy() => Problem.fromJson(toJson());

  double get totalSam => operations.fold(0.0, (s, o) => s + o.duration);

  Operation? getOperation(String id) {
    for (final o in operations) {
      if (o.id == id) return o;
    }
    return null;
  }

  Worker? getWorker(String id) {
    for (final w in workers) {
      if (w.id == id) return w;
    }
    return null;
  }
}

/// Point de diagnostic (`IssueOut`).
class Issue {
  final String code;
  final String severity; // error | warning | info
  final String message;
  final String suggestion;

  const Issue(this.code, this.severity, this.message, [this.suggestion = '']);

  factory Issue.fromJson(Map<String, dynamic> j) => Issue(
        (j['code'] ?? '').toString(),
        (j['severity'] ?? 'warning').toString(),
        (j['message'] ?? '').toString(),
        (j['suggestion'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'code': code, 'severity': severity, 'message': message, 'suggestion': suggestion};

  bool get isError => severity == 'error';

  @override
  String toString() {
    final s = '[$code] $message';
    return suggestion.isNotEmpty ? '$s → $suggestion' : s;
  }
}

/// Détail d'une station (mêmes clés que le dict Python `station_details`).
class StationDetail {
  int station;
  double totalTime;
  double loadPct;
  List<String> operations;
  List<String> workers;
  String workstation;
  int parallel;
  Map<String, double>? shares;
  List<String>? machineTypes;
  List<String>? sections;
  List<String>? workstations;
  List<String>? workerIds;
  double? workerTime;
  double? workerEfficiency;

  StationDetail({
    required this.station,
    required this.totalTime,
    required this.loadPct,
    required this.operations,
    List<String>? workers,
    this.workstation = '',
    this.parallel = 1,
    this.shares,
    this.machineTypes,
    this.sections,
    this.workstations,
    this.workerIds,
    this.workerTime,
    this.workerEfficiency,
  }) : workers = workers ?? [];

  factory StationDetail.fromJson(Map<String, dynamic> j) => StationDetail(
        station: _i(j['station']),
        totalTime: _d(j['total_time']),
        loadPct: _d(j['load_pct']),
        operations: _sl(j['operations']),
        workers: _sl(j['workers']),
        workstation: (j['workstation'] ?? '').toString(),
        parallel: _i(j['parallel'], 1),
        shares: j['shares'] == null
            ? null
            : {for (final e in (j['shares'] as Map).entries) e.key.toString(): _d(e.value)},
        machineTypes: j['machine_types'] == null ? null : _sl(j['machine_types']),
        sections: j['sections'] == null ? null : _sl(j['sections']),
        workstations: j['workstations'] == null ? null : _sl(j['workstations']),
        workerIds: j['worker_ids'] == null ? null : _sl(j['worker_ids']),
        workerTime: j['worker_time'] == null ? null : _d(j['worker_time']),
        workerEfficiency: j['worker_efficiency'] == null ? null : _d(j['worker_efficiency']),
      );

  Map<String, dynamic> toJson() => {
        'station': station,
        'total_time': totalTime,
        'load_pct': loadPct,
        'operations': operations,
        'workers': workers,
        'workstation': workstation,
        'parallel': parallel,
        if (shares != null) 'shares': shares,
        if (machineTypes != null) 'machine_types': machineTypes,
        if (sections != null) 'sections': sections,
        if (workstations != null) 'workstations': workstations,
        if (workerIds != null) 'worker_ids': workerIds,
        if (workerTime != null) 'worker_time': workerTime,
        if (workerEfficiency != null) 'worker_efficiency': workerEfficiency,
      };

  /// Postes physiques affichables.
  List<String> get allWorkstations =>
      workstations ?? (workstation.isNotEmpty ? [workstation] : const []);
}

/// Résultat d'un équilibrage (= `ResultOut` de l'API).
class BalanceResult {
  bool success;
  bool compliant;
  String status;
  String solver;
  double solveTimeSeconds;
  double targetCycleTime;
  int stationsUsed;
  double actualCycleTime;
  double efficiency;
  double balanceDelay;
  double smoothnessIndex;
  int operators;
  List<StationDetail> stationDetails;
  Map<String, int> operationAssignments;
  Map<String, String> workerAssignments;
  List<String> warnings;
  String errorMessage;
  List<Issue> violations;

  BalanceResult({
    required this.success,
    required this.compliant,
    required this.status,
    required this.solver,
    this.solveTimeSeconds = 0,
    required this.targetCycleTime,
    required this.stationsUsed,
    required this.actualCycleTime,
    required this.efficiency,
    required this.balanceDelay,
    required this.smoothnessIndex,
    required this.operators,
    required this.stationDetails,
    Map<String, int>? operationAssignments,
    Map<String, String>? workerAssignments,
    List<String>? warnings,
    this.errorMessage = '',
    List<Issue>? violations,
  })  : operationAssignments = operationAssignments ?? {},
        workerAssignments = workerAssignments ?? {},
        warnings = warnings ?? [],
        violations = violations ?? [];

  factory BalanceResult.fromJson(Map<String, dynamic> j) => BalanceResult(
        success: _b(j['success']),
        compliant: _b(j['compliant']),
        status: (j['status'] ?? '').toString(),
        solver: (j['solver'] ?? '').toString(),
        solveTimeSeconds: _d(j['solve_time_seconds']),
        targetCycleTime: _d(j['target_cycle_time']),
        stationsUsed: _i(j['stations_used']),
        actualCycleTime: _d(j['actual_cycle_time']),
        efficiency: _d(j['efficiency']),
        balanceDelay: _d(j['balance_delay']),
        smoothnessIndex: _d(j['smoothness_index']),
        operators: _i(j['operators']),
        stationDetails: [
          for (final s in (j['station_details'] as List? ?? [])) StationDetail.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
        operationAssignments: {
          for (final e in ((j['operation_assignments'] as Map?) ?? {}).entries) e.key.toString(): _i(e.value),
        },
        workerAssignments: {
          for (final e in ((j['worker_assignments'] as Map?) ?? {}).entries) e.key.toString(): e.value.toString(),
        },
        warnings: [for (final w in (j['warnings'] as List? ?? [])) w.toString()],
        errorMessage: (j['error_message'] ?? '').toString(),
        violations: [
          for (final v in (j['violations'] as List? ?? [])) Issue.fromJson(Map<String, dynamic>.from(v as Map)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'success': success,
        'compliant': compliant,
        'status': status,
        'solver': solver,
        'solve_time_seconds': solveTimeSeconds,
        'target_cycle_time': targetCycleTime,
        'stations_used': stationsUsed,
        'actual_cycle_time': actualCycleTime,
        'efficiency': efficiency,
        'balance_delay': balanceDelay,
        'smoothness_index': smoothnessIndex,
        'operators': operators,
        'station_details': [for (final s in stationDetails) s.toJson()],
        'operation_assignments': operationAssignments,
        'worker_assignments': workerAssignments,
        'warnings': warnings,
        'error_message': errorMessage,
        'violations': [for (final v in violations) v.toJson()],
      };

  /// Production horaire au cycle réel (pièces/h).
  double get outputPerHour => actualCycleTime > 0 ? 60 / actualCycleTime : 0;

  /// Station goulot (la plus chargée, par opérateur).
  StationDetail? get bottleneck {
    StationDetail? best;
    for (final s in stationDetails) {
      if (best == null || s.totalTime > best.totalTime) best = s;
    }
    return best;
  }
}

/// Résultat d'une recherche de cadence minimale (`MinCycleOut`).
class MinCycleResult {
  final bool found;
  final double? minCycleTime;
  final BalanceResult? result;

  const MinCycleResult({required this.found, this.minCycleTime, this.result});

  factory MinCycleResult.fromJson(Map<String, dynamic> j) => MinCycleResult(
        found: _b(j['found']),
        minCycleTime: j['min_cycle_time'] == null ? null : _d(j['min_cycle_time']),
        result: j['result'] == null ? null : BalanceResult.fromJson(Map<String, dynamic>.from(j['result'] as Map)),
      );

  Map<String, dynamic> toJson() => {'found': found, 'min_cycle_time': minCycleTime, 'result': result?.toJson()};
}

/// Diagnostic avant calcul (`PrecheckOut`).
class PrecheckResult {
  final bool feasible;
  final List<Issue> issues;
  final List<String> validationErrors;

  const PrecheckResult({required this.feasible, required this.issues, required this.validationErrors});

  factory PrecheckResult.fromJson(Map<String, dynamic> j) => PrecheckResult(
        feasible: _b(j['feasible']),
        issues: [for (final v in (j['issues'] as List? ?? [])) Issue.fromJson(Map<String, dynamic>.from(v as Map))],
        validationErrors: [for (final v in (j['validation_errors'] as List? ?? [])) v.toString()],
      );

  Map<String, dynamic> toJson() => {
        'feasible': feasible,
        'issues': [for (final i in issues) i.toJson()],
        'validation_errors': validationErrors,
      };
}
