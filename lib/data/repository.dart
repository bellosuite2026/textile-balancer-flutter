/// Accès typé aux données locales (source de vérité hors ligne).
library;

import '../engine/engine.dart';
import 'local_store.dart';
import 'records.dart';

class Repository {
  Repository(this.store);
  final LocalStore store;

  // ---------------------------------------------------------------- réglages
  String? setting(String key) => store.get(Col.settings, key)?['v']?.toString();
  Future<void> setSetting(String key, String? value) =>
      value == null ? store.delete(Col.settings, key) : store.put(Col.settings, key, {'v': value});

  // ---------------------------------------------------------------- ateliers
  List<WorkshopRecord> workshops({String? kind}) {
    final l = [for (final j in store.all(Col.workshops)) WorkshopRecord.fromJson(j)];
    return kind == null ? l : l.where((w) => w.kind == kind).toList();
  }

  WorkshopRecord? workshop(String id) {
    final j = store.get(Col.workshops, id);
    return j == null ? null : WorkshopRecord.fromJson(j);
  }

  Future<void> saveWorkshop(WorkshopRecord w) => store.put(Col.workshops, w.id, w.toJson());
  Future<void> deleteWorkshop(String id) => store.delete(Col.workshops, id);

  // ---------------------------------------------------------------- gammes
  List<GammeRecord> gammes(String workshopId) {
    final l = [
      for (final j in store.all(Col.gammes))
        if (j['workshop_id'] == workshopId) GammeRecord.fromJson(j),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  GammeRecord? gamme(String id) {
    final j = store.get(Col.gammes, id);
    return j == null ? null : GammeRecord.fromJson(j);
  }

  GammeRecord? gammeByCloudId(String cloudId) {
    for (final j in store.all(Col.gammes)) {
      if (j['cloud_id'] == cloudId) return GammeRecord.fromJson(j);
    }
    return null;
  }

  Future<void> saveGamme(GammeRecord g) => store.put(Col.gammes, g.id, g.toJson());
  Future<void> deleteGamme(String id) => store.delete(Col.gammes, id);

  // ---------------------------------------------------------------- calculs
  List<RunRecord> runs(String workshopId) {
    final l = [
      for (final j in store.all(Col.runs))
        if (j['workshop_id'] == workshopId) RunRecord.fromJson(j),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  RunRecord? run(String id) {
    final j = store.get(Col.runs, id);
    return j == null ? null : RunRecord.fromJson(j);
  }

  RunRecord? runByCloudId(String cloudId) {
    for (final j in store.all(Col.runs)) {
      if (j['cloud_id'] == cloudId) return RunRecord.fromJson(j);
    }
    return null;
  }

  Future<void> saveRun(RunRecord r) => store.put(Col.runs, r.id, r.toJson());
  Future<void> deleteRun(String id) => store.delete(Col.runs, id);

  // ---------------------------------------------------------------- production
  List<SessionRecord> sessions(String workshopId) {
    final l = [
      for (final j in store.all(Col.sessions))
        if (j['workshop_id'] == workshopId) SessionRecord.fromJson(j),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  SessionRecord? session(String id) {
    final j = store.get(Col.sessions, id);
    return j == null ? null : SessionRecord.fromJson(j);
  }

  SessionRecord? sessionByCloudId(String cloudId) {
    for (final j in store.all(Col.sessions)) {
      if (j['cloud_id'] == cloudId) return SessionRecord.fromJson(j);
    }
    return null;
  }

  Future<void> saveSession(SessionRecord s) => store.put(Col.sessions, s.id, s.toJson());

  List<EntryRecord> entries(String sessionId) {
    final l = [
      for (final j in store.all(Col.entries))
        if (j['session_id'] == sessionId) EntryRecord.fromJson(j),
    ]..sort((a, b) => a.enteredAt.compareTo(b.enteredAt));
    return l;
  }

  EntryRecord? entry(String clientId) {
    final j = store.get(Col.entries, clientId);
    return j == null ? null : EntryRecord.fromJson(j);
  }

  Future<void> saveEntry(EntryRecord e) => store.put(Col.entries, e.clientId, e.toJson());

  // ---------------------------------------------------------------- file d'envoi
  List<OutboxOp> outbox() =>
      [for (final j in store.all(Col.outbox)) OutboxOp.fromJson(j)]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Future<void> enqueue(OutboxOp op) => store.put(Col.outbox, op.id, op.toJson());
  Future<void> saveOp(OutboxOp op) => store.put(Col.outbox, op.id, op.toJson());
  Future<void> removeOp(String id) => store.delete(Col.outbox, id);

  int pendingCount() {
    var n = store.all(Col.outbox).length;
    for (final j in store.all(Col.entries)) {
      if (j['synced'] != true) {
        final s = store.get(Col.sessions, j['session_id'].toString());
        final w = s == null ? null : store.get(Col.workshops, s['workshop_id'].toString());
        if (w != null && w['kind'] == 'cloud') n++;
      }
    }
    return n;
  }

  /// Plan de production (session) à partir d'un calcul terminé.
  Map<String, dynamic>? planFor(RunRecord r) {
    final b = r.balance;
    if (b == null || b.stationDetails.isEmpty) return null;
    return buildPlan(b, r.problem);
  }

  // ---------------------------------------------------------------- plans d'atelier, implantations (phase 2)
  List<Map<String, dynamic>> plans(String workshopId) => [
        for (final j in store.all(Col.plans))
          if (j['workshop_id'] == workshopId) j,
      ]..sort((a, b) => '${b['updated_at']}'.compareTo('${a['updated_at']}'));

  Map<String, dynamic>? plan(String id) => store.get(Col.plans, id);
  Future<void> savePlan(Map<String, dynamic> p) => store.put(Col.plans, '${p['id']}', p);
  Future<void> deletePlan(String id) => store.delete(Col.plans, id);

  /// Implantation du jumeau pour un calcul : `{kind, positions, local_plan_id?, assignment?}`.
  Map<String, dynamic>? runLayout(String runId) => store.get(Col.layouts, runId);
  Future<void> saveRunLayout(String runId, Map<String, dynamic> layout) => store.put(Col.layouts, runId, layout);
}
