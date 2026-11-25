/// État global de l'application (provider / ChangeNotifier).
///
/// - Mode « local » : aucun compte, tout est sur l'appareil (Windows hors ligne…).
/// - Mode « cloud » : connexion Supabase ; ateliers = organisations du SaaS ;
///   les données restent mises en cache localement et les modifications sont
///   placées dans une file d'envoi (outbox) rejouée dès que le serveur répond.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../data/api_client.dart';
import '../data/records.dart';
import '../data/repository.dart';
import '../engine/engine.dart';

enum AppMode { none, local, cloud }

enum NetStatus { unknown, online, offline }

/// Calcul RPW hors du fil d'interface (isolat sur les plateformes natives).
Map<String, dynamic> _runEngine(Map<String, dynamic> args) {
  final p = Problem.fromJson((args['problem'] as Map).cast<String, dynamic>());
  if (args['kind'] == 'min_cycle') {
    return findMinCycleRpw(p, precision: (args['precision'] as num).toDouble()).toJson();
  }
  return solveRpw(p, maxStations: p.maxStations).toJson();
}

class AppState extends ChangeNotifier {
  AppState({required this.repo, required this.api, this.enableNetwork = true});

  final Repository repo;
  final ApiClient api;
  final bool enableNetwork;

  AppMode mode = AppMode.none;
  NetStatus net = NetStatus.unknown;
  bool syncing = false;
  String? lastSyncError;
  DateTime? lastSync;
  String? userEmail;
  bool isSuperAdmin = false;
  WorkshopRecord? workshop;
  Timer? _timer;
  bool _ready = false;

  bool get ready => _ready;
  bool get isCloud => mode == AppMode.cloud;
  bool get online => net == NetStatus.online;
  bool get cloudAvailable => isCloud && online && api.isSignedIn;
  int get pendingCount => repo.pendingCount();

  // ================================================================ démarrage
  Future<void> init() async {
    final m = repo.setting('mode');
    mode = m == 'cloud' ? AppMode.cloud : (m == 'local' ? AppMode.local : AppMode.none);
    if (mode == AppMode.cloud) {
      userEmail = repo.setting('email');
      isSuperAdmin = repo.setting('super_admin') == '1';
      if (!api.isSignedIn) {
        // Session expirée : on garde le cache mais on redemandera la connexion.
        userEmail ??= api.email;
      }
    }
    final wid = repo.setting('workshop');
    if (wid != null) workshop = repo.workshop(wid);
    _ready = true;
    notifyListeners();
    if (enableNetwork) {
      unawaited(checkNetwork());
      _timer = Timer.periodic(const Duration(seconds: 45), (_) => checkNetwork());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> checkNetwork() async {
    final ok = await api.health();
    final was = net;
    net = ok ? NetStatus.online : NetStatus.offline;
    if (was != net) notifyListeners();
    if (ok && isCloud && api.isSignedIn) await sync();
  }

  // ================================================================ modes
  Future<void> startLocalMode() async {
    mode = AppMode.local;
    await repo.setSetting('mode', 'local');
    if (repo.workshops(kind: 'local').isEmpty) {
      await repo.saveWorkshop(WorkshopRecord(id: uuid4(), name: 'Mon atelier', kind: 'local'));
    }
    final ws = repo.workshops(kind: 'local');
    if (ws.length == 1) await selectWorkshop(ws.first);
    notifyListeners();
  }

  Future<void> signIn(String email, String password) async {
    await api.signIn(email, password);
    mode = AppMode.cloud;
    userEmail = email;
    await repo.setSetting('mode', 'cloud');
    await repo.setSetting('email', email);
    net = NetStatus.online;
    await refreshWorkshops();
    final cloud = repo.workshops(kind: 'cloud');
    if (cloud.length == 1) await selectWorkshop(cloud.first);
    notifyListeners();
  }

  /// Ateliers (organisations) depuis `/v1/me`, mis en cache.
  Future<void> refreshWorkshops() async {
    final me = await api.me();
    isSuperAdmin = me['is_super_admin'] == true;
    await repo.setSetting('super_admin', isSuperAdmin ? '1' : '0');
    final orgs = [for (final o in (me['orgs'] as List? ?? [])) WorkshopRecord.fromOrg((o as Map).cast<String, dynamic>())];
    final ids = orgs.map((o) => o.id).toSet();
    for (final old in repo.workshops(kind: 'cloud')) {
      if (!ids.contains(old.id)) await repo.deleteWorkshop(old.id);
    }
    for (final o in orgs) {
      await repo.saveWorkshop(o);
    }
    if (workshop != null && workshop!.isCloud) workshop = repo.workshop(workshop!.id);
    notifyListeners();
  }

  Future<WorkshopRecord> createWorkshop(String name) async {
    WorkshopRecord w;
    if (isCloud) {
      final o = await api.createOrg(name);
      w = WorkshopRecord.fromOrg({...o, 'role': 'owner'});
    } else {
      w = WorkshopRecord(id: uuid4(), name: name, kind: 'local');
    }
    await repo.saveWorkshop(w);
    notifyListeners();
    return w;
  }

  Future<void> renameLocalWorkshop(WorkshopRecord w, String name) async {
    w.name = name;
    await repo.saveWorkshop(w);
    notifyListeners();
  }

  Future<void> selectWorkshop(WorkshopRecord? w) async {
    workshop = w;
    await repo.setSetting('workshop', w?.id);
    notifyListeners();
    if (w != null && w.isCloud && online) unawaited(pullCloud());
  }

  List<WorkshopRecord> get workshops => repo.workshops(kind: isCloud ? 'cloud' : 'local');

  /// Déconnexion / changement de mode. Les données locales sont conservées.
  Future<void> leaveMode() async {
    if (isCloud) await api.signOut();
    mode = AppMode.none;
    workshop = null;
    userEmail = null;
    await repo.setSetting('mode', null);
    await repo.setSetting('workshop', null);
    notifyListeners();
  }

  // ================================================================ gammes
  List<GammeRecord> get gammes => workshop == null ? [] : repo.gammes(workshop!.id);

  /// Gammes enregistrées côté serveur (résumés), hors celles déjà en cache.
  List<Map<String, dynamic>> cloudGammes = [];

  Future<GammeRecord> saveGamme(GammeRecord g) async {
    g.updatedAt = DateTime.now();
    if (workshop?.isCloud == true) {
      g.dirty = true;
      await repo.saveGamme(g);
      final pending = repo.outbox().any((o) => o.type == 'save_gamme' && o.payload['gamme_id'] == g.id);
      if (!pending) {
        await repo.enqueue(OutboxOp(id: uuid4(), type: 'save_gamme', payload: {'gamme_id': g.id}));
      }
      unawaited(sync());
    } else {
      g.dirty = false;
      await repo.saveGamme(g);
    }
    notifyListeners();
    return g;
  }

  Future<void> deleteGamme(GammeRecord g) async {
    await repo.deleteGamme(g.id);
    notifyListeners();
  }

  GammeRecord newGamme([Problem? p]) => GammeRecord(
        id: uuid4(),
        workshopId: workshop!.id,
        problem: p ?? Problem(name: 'Nouvelle gamme', targetCycleTime: 1.0),
      );

  /// Ouvre une gamme serveur : la télécharge et la met en cache local.
  Future<GammeRecord> openCloudGamme(String cloudId) async {
    final existing = repo.gammeByCloudId(cloudId);
    if (existing != null) return existing;
    final row = await api.problem(workshop!.id, cloudId);
    final g = GammeRecord(
      id: uuid4(),
      workshopId: workshop!.id,
      problem: Problem.fromJson((row['payload'] as Map).cast<String, dynamic>()),
      cloudId: cloudId,
      lineId: row['line_id']?.toString(),
      dirty: false,
      createdAt: DateTime.tryParse(row['created_at']?.toString() ?? ''),
    );
    await repo.saveGamme(g);
    cloudGammes.removeWhere((r) => r['id'] == cloudId);
    notifyListeners();
    return g;
  }

  // ================================================================ calculs
  List<RunRecord> get runs => workshop == null ? [] : repo.runs(workshop!.id);
  List<Map<String, dynamic>> cloudRuns = [];

  /// Calcul local (moteur Dart). En mode cloud, une copie est placée dans la
  /// file d'envoi pour figurer dans l'historique de l'atelier (le serveur
  /// recalcule à l'identique : parité testée).
  Future<RunRecord> runLocal(Problem problem,
      {String kind = 'balance', String? gammeId, double precision = 0.05, bool pushToCloud = true}) async {
    final rec = RunRecord(
      id: uuid4(),
      workshopId: workshop!.id,
      gammeId: gammeId,
      problem: problem.deepCopy(),
      kind: kind,
      solver: 'rpw',
      source: 'local',
      status: 'running',
    );
    final out = await compute(_runEngine, {'problem': problem.toJson(), 'kind': kind, 'precision': precision});
    if (kind == 'min_cycle') {
      rec.minCycle = MinCycleResult.fromJson(out);
      if (rec.minCycle!.result != null) {
        rec.problem = rec.problem.shallowCopy(targetCycleTime: rec.minCycle!.minCycleTime);
      }
    } else {
      rec.result = BalanceResult.fromJson(out);
    }
    rec.status = 'done';
    rec.finishedAt = DateTime.now();
    if (workshop!.isCloud && pushToCloud && workshop!.canWrite) {
      rec.pushState = 'pending';
      await repo.enqueue(OutboxOp(id: uuid4(), type: 'push_run', payload: {'run_id': rec.id}));
    }
    await repo.saveRun(rec);
    notifyListeners();
    if (rec.pushState == 'pending') unawaited(sync());
    return rec;
  }

  /// Calcul serveur (CP-SAT ou RPW) : exige le mode cloud et le réseau.
  Future<RunRecord> runCloud(Problem problem,
      {String kind = 'balance', String solver = 'cp_sat', int timeLimit = 20, String? gammeId, double precision = 0.05}) async {
    if (!cloudAvailable) {
      throw ApiException(0, 'Le calcul CP-SAT nécessite une connexion au serveur (mode cloud, en ligne).');
    }
    final row = await api.createRun(workshop!.id,
        problem: problem, kind: kind, solver: solver, timeLimitSeconds: timeLimit, precision: precision);
    final rec = RunRecord(
      id: 'cloud-${row['id']}',
      workshopId: workshop!.id,
      gammeId: gammeId,
      problem: problem.deepCopy(),
      kind: kind,
      solver: solver,
      source: 'cloud',
      status: (row['status'] ?? 'queued').toString(),
      cloudId: row['id'].toString(),
      pushState: 'pushed',
    );
    await repo.saveRun(rec);
    notifyListeners();
    return rec;
  }

  /// Interroge le serveur jusqu'à la fin d'un calcul cloud.
  Stream<RunRecord> pollCloudRun(RunRecord rec, {Duration every = const Duration(seconds: 2), int maxTries = 240}) async* {
    var r = rec;
    for (var i = 0; i < maxTries && (r.status == 'queued' || r.status == 'running'); i++) {
      await Future<void>.delayed(every);
      try {
        final row = await api.run(workshop!.id, r.cloudId!);
        final upd = RunRecord.fromCloud(r.workshopId, row, r.problem);
        upd.gammeId = r.gammeId;
        r = upd;
        await repo.saveRun(r);
        notifyListeners();
        yield r;
      } on ApiException catch (e) {
        if (!e.isTransient) rethrow;
      }
    }
  }

  /// Détail d'un calcul de l'historique cloud (résultat + gamme), mis en cache.
  Future<RunRecord> openCloudRun(String cloudId) async {
    final cached = repo.runByCloudId(cloudId);
    if (cached != null && cached.isDone && cached.balance != null) return cached;
    final row = await api.run(workshop!.id, cloudId);
    Problem? problem;
    final pid = row['problem_id']?.toString();
    if (pid != null) {
      try {
        final g = repo.gammeByCloudId(pid);
        problem = g?.problem ?? Problem.fromJson(((await api.problem(workshop!.id, pid))['payload'] as Map).cast<String, dynamic>());
      } on ApiException {
        problem = null;
      }
    }
    final rec = RunRecord.fromCloud(workshop!.id, row, problem);
    if (cached != null) {
      // calcul local déjà envoyé : on garde l'enregistrement local
      cached.status = rec.status;
      await repo.saveRun(cached);
      return cached;
    }
    await repo.saveRun(rec);
    notifyListeners();
    return rec;
  }

  Future<void> deleteRun(RunRecord r) async {
    await repo.deleteRun(r.id);
    notifyListeners();
  }

  // ================================================================ production
  List<SessionRecord> get sessions => workshop == null ? [] : repo.sessions(workshop!.id);

  Future<SessionRecord> openSession(RunRecord run,
      {required String model, required String date, String shiftStart = '08:00', double shiftHours = 8, double? targetPerHour}) async {
    final plan = repo.planFor(run);
    if (plan == null) throw StateError('Ce calcul ne contient aucune station à suivre.');
    final target = targetPerHour ?? defaultTargetPerHour(plan) ?? 0;
    final s = SessionRecord(
      id: uuid4(),
      workshopId: workshop!.id,
      runId: run.id,
      model: model.isEmpty ? run.problem.name : model,
      sessionDate: date,
      shiftStart: shiftStart,
      shiftHours: shiftHours,
      targetPerHour: target,
      plan: plan,
    );
    await repo.saveSession(s);
    if (workshop!.isCloud && workshop!.canWrite) {
      await repo.enqueue(OutboxOp(id: uuid4(), type: 'open_session', payload: {'session_id': s.id}));
      unawaited(sync());
    }
    notifyListeners();
    return s;
  }

  Future<EntryRecord> addEntry(SessionRecord s, int station,
      {int pieces = 0, int defects = 0, int rework = 0, String? downtimeReason, String comment = ''}) async {
    final now = DateTime.now();
    final e = EntryRecord(
      clientId: uuid4(),
      sessionId: s.id,
      station: station,
      slotHour: now.hour,
      pieces: pieces,
      defects: defects,
      rework: rework,
      downtimeReason: downtimeReason,
      downtimeStart: downtimeReason != null ? now.toUtc().toIso8601String() : null,
      comment: comment,
      enteredAt: now.toUtc().toIso8601String(),
    );
    await repo.saveEntry(e);
    notifyListeners();
    _scheduleEntrySync();
    return e;
  }

  /// Fin d'un arrêt en cours : durée figée (même client_id → mise à jour idempotente).
  Future<void> endStop(EntryRecord e) async {
    final start = DateTime.tryParse(e.downtimeStart ?? '') ?? DateTime.now();
    e.downtimeMinutes = pyRound(DateTime.now().difference(start).inSeconds / 60.0, 1);
    e.synced = false;
    await repo.saveEntry(e);
    notifyListeners();
    _scheduleEntrySync();
  }

  Future<void> voidEntry(EntryRecord e) async {
    e.voided = true;
    e.synced = false;
    await repo.saveEntry(e);
    notifyListeners();
    _scheduleEntrySync();
  }

  Future<void> setSessionStatus(SessionRecord s, String status) async {
    s.status = status;
    s.closedAt = status == 'closed' ? DateTime.now().toUtc().toIso8601String() : null;
    await repo.saveSession(s);
    if (workshop!.isCloud) {
      await repo.enqueue(OutboxOp(id: uuid4(), type: 'patch_session', payload: {'session_id': s.id, 'status': status}));
      unawaited(sync());
    }
    notifyListeners();
  }

  Map<String, dynamic> dashboardFor(SessionRecord s) => productionDashboard(
        s.toJson(),
        [for (final e in repo.entries(s.id)) e.toJson()],
      );

  Timer? _entryTimer;
  void _scheduleEntrySync() {
    if (workshop?.isCloud != true) return;
    _entryTimer?.cancel();
    _entryTimer = Timer(const Duration(seconds: 3), () => sync());
  }

  // ================================================================ synchronisation
  /// Rejoue la file d'envoi puis rafraîchit les listes serveur.
  Future<void> sync() async {
    if (syncing || !isCloud || !api.isSignedIn) return;
    syncing = true;
    notifyListeners();
    try {
      await _flushOutbox();
      await _pushEntries();
      lastSyncError = null;
      lastSync = DateTime.now();
      net = NetStatus.online;
    } on ApiException catch (e) {
      lastSyncError = e.message;
      if (e.isTransient) net = NetStatus.offline;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _flushOutbox() async {
    for (final op in repo.outbox()) {
      try {
        final done = await _apply(op);
        if (done) {
          await repo.removeOp(op.id);
        }
      } on ApiException catch (e) {
        if (e.isTransient) rethrow; // hors ligne : on réessaiera
        op.attempts++;
        op.lastError = e.message;
        if (op.attempts >= 5) {
          await repo.removeOp(op.id); // rejet définitif (droits, quota…) : on abandonne l'envoi
        } else {
          await repo.saveOp(op);
        }
      }
    }
  }

  /// Applique une opération ; `false` = à différer (dépendance pas encore envoyée).
  Future<bool> _apply(OutboxOp op) async {
    switch (op.type) {
      case 'save_gamme':
        final g = repo.gamme(op.payload['gamme_id'].toString());
        if (g == null) return true;
        final ws = repo.workshop(g.workshopId);
        if (ws == null || !ws.isCloud) return true;
        final row = await api.saveProblem(ws.id, g.problem, lineId: g.lineId);
        g.cloudId = row['id']?.toString();
        g.dirty = false;
        await repo.saveGamme(g);
        return true;
      case 'push_run':
        final r = repo.run(op.payload['run_id'].toString());
        if (r == null || r.cloudId != null) return true;
        final ws = repo.workshop(r.workshopId);
        if (ws == null || !ws.isCloud) return true;
        final g = r.gammeId == null ? null : repo.gamme(r.gammeId!);
        final useId = g != null &&
            g.cloudId != null &&
            !g.dirty &&
            r.kind == 'balance' &&
            g.problem.targetCycleTime == r.problem.targetCycleTime;
        final row = await api.createRun(ws.id,
            problem: useId ? null : r.problem, problemId: useId ? g.cloudId : null, kind: 'balance', solver: 'rpw');
        r.cloudId = row['id'].toString();
        r.pushState = 'pushed';
        await repo.saveRun(r);
        return true;
      case 'open_session':
        final s = repo.session(op.payload['session_id'].toString());
        if (s == null || s.cloudId != null) return true;
        final r = repo.run(s.runId);
        if (r == null) return true;
        if (r.cloudId == null) return false; // le calcul doit d'abord être envoyé
        final ws = repo.workshop(s.workshopId)!;
        Map<String, dynamic> row;
        try {
          row = await api.openSession(ws.id, {
            'run_id': r.cloudId,
            'model': s.model,
            'session_date': s.sessionDate,
            'shift_start': s.shiftStart,
            'shift_hours': s.shiftHours,
            'target_per_hour': s.targetPerHour,
            'timezone': 'Africa/Tunis',
          });
        } on ApiException catch (e) {
          if (e.status == 409) return false; // calcul serveur pas encore terminé
          rethrow;
        }
        s.cloudId = row['id'].toString();
        await repo.saveSession(s);
        return true;
      case 'patch_session':
        final s = repo.session(op.payload['session_id'].toString());
        if (s == null) return true;
        if (s.cloudId == null) return false;
        await api.patchSession(s.workshopId, s.cloudId!, {'status': op.payload['status']});
        return true;
    }
    return true;
  }

  Future<void> _pushEntries() async {
    for (final w in repo.workshops(kind: 'cloud')) {
      for (final s in repo.sessions(w.id)) {
        if (s.cloudId == null) continue;
        final pending = repo.entries(s.id).where((e) => !e.synced).toList();
        if (pending.isEmpty || !s.isOpen) continue;
        for (var i = 0; i < pending.length; i += 200) {
          final chunk = pending.sublist(i, i + 200 > pending.length ? pending.length : i + 200);
          await api.pushEntries(w.id, s.cloudId!, [for (final e in chunk) e.toApi()]);
          for (final e in chunk) {
            // n'acquitte que si la saisie n'a pas changé entre-temps
            final cur = repo.entry(e.clientId);
            if (cur != null && cur.toApi().toString() == e.toApi().toString()) {
              cur.synced = true;
              await repo.saveEntry(cur);
            }
          }
        }
      }
    }
  }

  /// Récupère les saisies des autres tablettes d'une session cloud.
  Future<void> pullEntries(SessionRecord s) async {
    if (!cloudAvailable || s.cloudId == null) return;
    try {
      final rows = await api.entries(workshop!.id, s.cloudId!);
      for (final row in rows) {
        final cid = row['client_id']?.toString();
        if (cid == null) continue;
        final local = repo.entry(cid);
        if (local != null && !local.synced) continue; // la version locale non envoyée prime
        final e = EntryRecord.fromJson({...row, 'session_id': s.id, 'synced': true});
        await repo.saveEntry(e);
      }
      notifyListeners();
    } on ApiException {
      // hors ligne : le tableau de bord reste calculé sur les saisies locales
    }
  }

  /// Listes serveur de l'atelier courant (gammes, historique, sessions).
  Future<void> pullCloud() async {
    final w = workshop;
    if (w == null || !w.isCloud || !api.isSignedIn) return;
    try {
      final probs = await api.problems(w.id);
      cloudGammes = [for (final p in probs) if (repo.gammeByCloudId(p['id'].toString()) == null) p];
      final rows = await api.runs(w.id);
      cloudRuns = [for (final r in rows) if (repo.runByCloudId(r['id'].toString()) == null) r];
      final sess = await api.sessions(w.id);
      for (final row in sess) {
        if (repo.sessionByCloudId(row['id'].toString()) != null) continue;
        final run = repo.runByCloudId(row['run_id']?.toString() ?? '');
        final full = row['plan'] == null ? null : row;
        if (full == null) continue; // le résumé n'a pas le plan ; ouvert à la demande
        await repo.saveSession(SessionRecord.fromJson({
          ...full,
          'id': uuid4(),
          'workshop_id': w.id,
          'run_id': run?.id ?? '',
          'cloud_id': row['id'],
        }));
      }
      cloudSessions = [for (final r in sess) if (repo.sessionByCloudId(r['id'].toString()) == null) r];
      net = NetStatus.online;
    } on ApiException catch (e) {
      lastSyncError = e.message;
      if (e.isTransient) net = NetStatus.offline;
    }
    notifyListeners();
  }

  List<Map<String, dynamic>> cloudSessions = [];

  /// Ouvre une session serveur (avec son plan) et la met en cache.
  Future<SessionRecord> openCloudSession(String cloudId) async {
    final existing = repo.sessionByCloudId(cloudId);
    if (existing != null) return existing;
    final rows = await api.sessions(workshop!.id);
    final row = rows.firstWhere((r) => r['id'].toString() == cloudId, orElse: () => {});
    final detail = row['plan'] == null ? await _sessionDetail(cloudId) : row;
    final run = repo.runByCloudId(detail['run_id']?.toString() ?? '');
    final s = SessionRecord.fromJson({
      ...detail,
      'id': uuid4(),
      'workshop_id': workshop!.id,
      'run_id': run?.id ?? '',
      'cloud_id': cloudId,
    });
    await repo.saveSession(s);
    cloudSessions.removeWhere((r) => r['id'].toString() == cloudId);
    await pullEntries(s);
    notifyListeners();
    return s;
  }

  Future<Map<String, dynamic>> _sessionDetail(String cloudId) async {
    return api.session(workshop!.id, cloudId);
  }
}
