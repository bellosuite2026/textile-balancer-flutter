/// Enregistrements applicatifs (stockés localement, miroir des tables Supabase).
///
/// | Local              | Supabase / API                         |
/// |--------------------|----------------------------------------|
/// | WorkshopRecord     | organizations (+ memberships.role)     |
/// | GammeRecord        | problems (payload = ProblemIn)         |
/// | RunRecord          | runs (result = ResultOut / MinCycleOut)|
/// | SessionRecord      | production_sessions (plan figé)        |
/// | EntryRecord        | production_entries (client_id)         |
library;

import '../engine/engine.dart';

DateTime _date(Object? v) => DateTime.tryParse(v?.toString() ?? '') ?? DateTime.now();

class WorkshopRecord {
  final String id; // id local ; = id de l'organisation en mode cloud
  String name;
  final String kind; // local | cloud
  String role;
  String country;
  String? planCode;
  String? planStatus;

  WorkshopRecord({
    required this.id,
    required this.name,
    required this.kind,
    this.role = 'owner',
    this.country = 'TN',
    this.planCode,
    this.planStatus,
  });

  bool get isCloud => kind == 'cloud';
  bool get canWrite => role != 'lecteur';

  factory WorkshopRecord.fromJson(Map<String, dynamic> j) => WorkshopRecord(
        id: j['id'].toString(),
        name: (j['name'] ?? '').toString(),
        kind: (j['kind'] ?? 'local').toString(),
        role: (j['role'] ?? 'owner').toString(),
        country: (j['country'] ?? 'TN').toString(),
        planCode: j['plan_code']?.toString(),
        planStatus: j['plan_status']?.toString(),
      );

  /// Depuis `GET /v1/me` → orgs[].
  factory WorkshopRecord.fromOrg(Map<String, dynamic> o) {
    final sub = o['subscription'];
    final s = sub is List ? (sub.isNotEmpty ? sub.first as Map : null) : sub as Map?;
    return WorkshopRecord(
      id: o['id'].toString(),
      name: (o['name'] ?? '').toString(),
      kind: 'cloud',
      role: (o['role'] ?? 'lecteur').toString(),
      country: (o['country'] ?? 'TN').toString(),
      planCode: s?['plan_code']?.toString(),
      planStatus: s?['status']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'role': role,
        'country': country,
        'plan_code': planCode,
        'plan_status': planStatus,
      };
}

class GammeRecord {
  final String id;
  final String workshopId;
  Problem problem;
  String? cloudId; // id de la ligne `problems` côté serveur
  String? lineId;
  bool dirty; // modifiée localement depuis le dernier envoi
  DateTime createdAt;
  DateTime updatedAt;

  GammeRecord({
    required this.id,
    required this.workshopId,
    required this.problem,
    this.cloudId,
    this.lineId,
    this.dirty = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  String get name => problem.name;

  factory GammeRecord.fromJson(Map<String, dynamic> j) => GammeRecord(
        id: j['id'].toString(),
        workshopId: j['workshop_id'].toString(),
        problem: Problem.fromJson((j['problem'] as Map).cast<String, dynamic>()),
        cloudId: j['cloud_id']?.toString(),
        lineId: j['line_id']?.toString(),
        dirty: j['dirty'] == true,
        createdAt: _date(j['created_at']),
        updatedAt: _date(j['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'workshop_id': workshopId,
        'problem': problem.toJson(),
        'cloud_id': cloudId,
        'line_id': lineId,
        'dirty': dirty,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}

class RunRecord {
  final String id;
  final String workshopId;
  String? gammeId;
  Problem problem; // instantané de la gamme calculée
  final String kind; // balance | min_cycle
  final String solver; // rpw | cp_sat
  final String source; // local (moteur Dart) | cloud (API)
  String status; // queued | running | done | failed
  BalanceResult? result;
  MinCycleResult? minCycle;
  String error;
  String? cloudId;
  String pushState; // none | pending | pushed (copie dans l'historique cloud)
  final DateTime createdAt;
  DateTime? finishedAt;

  RunRecord({
    required this.id,
    required this.workshopId,
    this.gammeId,
    required this.problem,
    required this.kind,
    required this.solver,
    required this.source,
    this.status = 'queued',
    this.result,
    this.minCycle,
    this.error = '',
    this.cloudId,
    this.pushState = 'none',
    DateTime? createdAt,
    this.finishedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Répartition à afficher (pour une cadence minimale : le résultat à cette cadence).
  BalanceResult? get balance => kind == 'min_cycle' ? minCycle?.result : result;

  bool get isDone => status == 'done';

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        id: j['id'].toString(),
        workshopId: j['workshop_id'].toString(),
        gammeId: j['gamme_id']?.toString(),
        problem: Problem.fromJson((j['problem'] as Map).cast<String, dynamic>()),
        kind: (j['kind'] ?? 'balance').toString(),
        solver: (j['solver'] ?? 'rpw').toString(),
        source: (j['source'] ?? 'local').toString(),
        status: (j['status'] ?? 'done').toString(),
        result: j['result'] == null ? null : BalanceResult.fromJson((j['result'] as Map).cast<String, dynamic>()),
        minCycle:
            j['min_cycle'] == null ? null : MinCycleResult.fromJson((j['min_cycle'] as Map).cast<String, dynamic>()),
        error: (j['error'] ?? '').toString(),
        cloudId: j['cloud_id']?.toString(),
        pushState: (j['push_state'] ?? 'none').toString(),
        createdAt: _date(j['created_at']),
        finishedAt: j['finished_at'] == null ? null : _date(j['finished_at']),
      );

  /// Depuis `GET /v1/orgs/{org}/runs/{id}` (avec `result`).
  factory RunRecord.fromCloud(String workshopId, Map<String, dynamic> row, Problem? problem) {
    final kind = (row['kind'] ?? 'balance').toString();
    final res = row['result'] as Map?;
    return RunRecord(
      id: 'cloud-${row['id']}',
      workshopId: workshopId,
      problem: problem ?? Problem(name: 'Gamme serveur', targetCycleTime: 1),
      kind: kind,
      solver: (row['solver'] ?? 'rpw').toString(),
      source: 'cloud',
      status: (row['status'] ?? 'queued').toString(),
      result: (kind == 'balance' && res != null) ? BalanceResult.fromJson(res.cast<String, dynamic>()) : null,
      minCycle: (kind == 'min_cycle' && res != null) ? MinCycleResult.fromJson(res.cast<String, dynamic>()) : null,
      error: (row['error'] ?? '').toString(),
      cloudId: row['id'].toString(),
      pushState: 'pushed',
      createdAt: _date(row['created_at']),
      finishedAt: row['finished_at'] == null ? null : _date(row['finished_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'workshop_id': workshopId,
        'gamme_id': gammeId,
        'problem': problem.toJson(),
        'kind': kind,
        'solver': solver,
        'source': source,
        'status': status,
        'result': result?.toJson(),
        'min_cycle': minCycle?.toJson(),
        'error': error,
        'cloud_id': cloudId,
        'push_state': pushState,
        'created_at': createdAt.toIso8601String(),
        'finished_at': finishedAt?.toIso8601String(),
      };
}

/// Session de production (même champs que `production_sessions`).
class SessionRecord {
  final String id;
  final String workshopId;
  final String runId; // RunRecord.id local
  String? cloudId;
  String model;
  String sessionDate; // AAAA-MM-JJ
  String shiftStart; // HH:MM
  double shiftHours;
  double targetPerHour;
  String status; // open | closed
  String? closedAt;
  Map<String, dynamic> plan;
  final DateTime createdAt;

  SessionRecord({
    required this.id,
    required this.workshopId,
    required this.runId,
    this.cloudId,
    this.model = '',
    required this.sessionDate,
    this.shiftStart = '08:00',
    this.shiftHours = 8,
    required this.targetPerHour,
    this.status = 'open',
    this.closedAt,
    required this.plan,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isOpen => status == 'open';

  factory SessionRecord.fromJson(Map<String, dynamic> j) => SessionRecord(
        id: j['id'].toString(),
        workshopId: j['workshop_id'].toString(),
        runId: (j['run_id'] ?? '').toString(),
        cloudId: j['cloud_id']?.toString(),
        model: (j['model'] ?? '').toString(),
        sessionDate: (j['session_date'] ?? '').toString(),
        shiftStart: (j['shift_start'] ?? '08:00').toString().substring(0, 5),
        shiftHours: ((j['shift_hours'] ?? 8) as num).toDouble(),
        targetPerHour: ((j['target_per_hour'] ?? 0) as num).toDouble(),
        status: (j['status'] ?? 'open').toString(),
        closedAt: j['closed_at']?.toString(),
        plan: ((j['plan'] as Map?) ?? {}).cast<String, dynamic>(),
        createdAt: _date(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'workshop_id': workshopId,
        'run_id': runId,
        'cloud_id': cloudId,
        'model': model,
        'session_date': sessionDate,
        'shift_start': shiftStart,
        'shift_hours': shiftHours,
        'target_per_hour': targetPerHour,
        'status': status,
        'closed_at': closedAt,
        'plan': plan,
        'created_at': createdAt.toIso8601String(),
        'timezone': 'Africa/Tunis',
      };
}

/// Saisie tablette (idempotente par `client_id`).
class EntryRecord {
  final String clientId;
  final String sessionId; // SessionRecord.id
  final int station;
  final int slotHour;
  int pieces;
  int defects;
  int rework;
  String? downtimeReason;
  String? downtimeStart;
  double? downtimeMinutes;
  String comment;
  bool voided;
  final String enteredAt;
  bool synced;

  EntryRecord({
    required this.clientId,
    required this.sessionId,
    required this.station,
    required this.slotHour,
    this.pieces = 0,
    this.defects = 0,
    this.rework = 0,
    this.downtimeReason,
    this.downtimeStart,
    this.downtimeMinutes,
    this.comment = '',
    this.voided = false,
    required this.enteredAt,
    this.synced = false,
  });

  factory EntryRecord.fromJson(Map<String, dynamic> j) => EntryRecord(
        clientId: j['client_id'].toString(),
        sessionId: (j['session_id'] ?? '').toString(),
        station: ((j['station'] ?? 0) as num).toInt(),
        slotHour: ((j['slot_hour'] ?? 0) as num).toInt(),
        pieces: ((j['pieces'] ?? 0) as num).toInt(),
        defects: ((j['defects'] ?? 0) as num).toInt(),
        rework: ((j['rework'] ?? 0) as num).toInt(),
        downtimeReason: j['downtime_reason']?.toString(),
        downtimeStart: j['downtime_start']?.toString(),
        downtimeMinutes: (j['downtime_minutes'] as num?)?.toDouble(),
        comment: (j['comment'] ?? '').toString(),
        voided: j['voided'] == true,
        enteredAt: (j['entered_at'] ?? DateTime.now().toUtc().toIso8601String()).toString(),
        synced: j['synced'] == true,
      );

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'session_id': sessionId,
        'station': station,
        'slot_hour': slotHour,
        'pieces': pieces,
        'defects': defects,
        'rework': rework,
        'downtime_reason': downtimeReason,
        'downtime_start': downtimeStart,
        'downtime_minutes': downtimeMinutes,
        'comment': comment,
        'voided': voided,
        'entered_at': enteredAt,
        'synced': synced,
      };

  /// Corps attendu par `POST .../entries` (EntryIn).
  Map<String, dynamic> toApi() => {
        'client_id': clientId,
        'station': station,
        'slot_hour': slotHour,
        'pieces': pieces,
        'defects': defects,
        'rework': rework,
        if (downtimeReason != null) 'downtime_reason': downtimeReason,
        if (downtimeReason != null && downtimeStart != null) 'downtime_start': downtimeStart,
        if (downtimeReason != null && downtimeMinutes != null) 'downtime_minutes': downtimeMinutes,
        'comment': comment,
        'voided': voided,
        'entered_at': enteredAt,
      };
}

/// Opération en attente d'envoi au serveur.
class OutboxOp {
  final String id;
  final String type; // save_gamme | push_run | open_session | push_entries | patch_session
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  int attempts;
  String lastError;

  OutboxOp({
    required this.id,
    required this.type,
    required this.payload,
    DateTime? createdAt,
    this.attempts = 0,
    this.lastError = '',
  }) : createdAt = createdAt ?? DateTime.now();

  factory OutboxOp.fromJson(Map<String, dynamic> j) => OutboxOp(
        id: j['id'].toString(),
        type: j['type'].toString(),
        payload: ((j['payload'] as Map?) ?? {}).cast<String, dynamic>(),
        createdAt: _date(j['created_at']),
        attempts: ((j['attempts'] ?? 0) as num).toInt(),
        lastError: (j['last_error'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'payload': payload,
        'created_at': createdAt.toIso8601String(),
        'attempts': attempts,
        'last_error': lastError,
      };
}
