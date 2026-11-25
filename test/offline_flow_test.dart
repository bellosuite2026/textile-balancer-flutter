// Parcours hors ligne complet (mode local, sans réseau) + file d'envoi du mode cloud.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/data/api_client.dart';
import 'package:textile_balancer_flutter/data/exporters.dart';
import 'package:textile_balancer_flutter/data/local_store.dart';
import 'package:textile_balancer_flutter/data/records.dart';
import 'package:textile_balancer_flutter/data/repository.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';

Problem chemise() => Problem(
      name: 'Chemise homme',
      targetCycleTime: 1.5,
      operations: parseSamCsv(File('test/fixtures/csv/sam_chemise_homme.csv').readAsStringSync()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('fr_FR'));

  test('mode local : gamme → RPW → session → saisies → tableau de bord → exports', () async {
    final offline = MockClient((_) async => throw const SocketException('hors ligne'));
    final s = AppState(repo: Repository(MemoryLocalStore()), api: ApiClient(httpClient: offline), enableNetwork: false);
    await s.init();
    await s.startLocalMode();
    expect(s.mode, AppMode.local);
    expect(s.workshop, isNotNull);

    final g = await s.saveGamme(s.newGamme(chemise()));
    expect(s.gammes.single.id, g.id);
    expect(g.dirty, isFalse);

    final run = await s.runLocal(g.problem, gammeId: g.id);
    expect(run.isDone, isTrue);
    expect(run.result!.compliant, isTrue);
    expect(run.pushState, 'none'); // rien à envoyer en mode local
    expect(s.repo.outbox(), isEmpty);

    final mc = await s.runLocal(g.problem, kind: 'min_cycle');
    expect(mc.minCycle!.found, isTrue);
    expect(mc.balance, isNotNull);

    final sess = await s.openSession(run, model: 'Chemise', date: '2026-11-24');
    expect(sess.plan['stations'], isNotEmpty);
    final st = (sess.plan['stations'] as List).first['station'] as int;
    await s.addEntry(sess, st, pieces: 10);
    final stop = await s.addEntry(sess, st, downtimeReason: 'panne');
    await s.endStop(stop);
    final e = await s.addEntry(sess, st, pieces: 5);
    await s.voidEntry(e);
    final d = s.dashboardFor(sess);
    final row = (d['stations'] as List).firstWhere((r) => r['station'] == st);
    expect(row['pieces'], 10);
    expect((d['stops'] as List).length, 1);

    await s.setSessionStatus(sess, 'closed');
    expect(s.repo.session(sess.id)!.isOpen, isFalse);

    expect(resultCsv(run.result!, run.problem).length, greaterThan(100));
    expect(resultXlsx(run.result!, run.problem).length, greaterThan(1000));
    final pdf = await resultPdf(run.result!, run.problem);
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
  });

  test('mode cloud hors ligne : les envois sont mis en file puis rejoués dans l\'ordre', () async {
    var online = false;
    final calls = <String>[];
    final api = MockClient((req) async {
      if (!online) throw const SocketException('hors ligne');
      calls.add('${req.method} ${req.url.path}');
      final p = req.url.path;
      if (p.endsWith('/problems')) return http.Response('{"id":"p-1"}', 201);
      if (p.endsWith('/runs')) return http.Response('{"id":"r-1","status":"queued"}', 202);
      if (p.endsWith('/production/sessions')) return http.Response('{"id":"s-1"}', 201);
      if (p.endsWith('/entries')) return http.Response('{"saved":1,"entries":[]}', 200);
      return http.Response('{}', 200);
    });
    final client = _SignedInApi(api);
    final repo = Repository(MemoryLocalStore());
    final s = AppState(repo: repo, api: client, enableNetwork: false);
    await s.init();
    s.mode = AppMode.cloud;
    final w = WorkshopRecord(id: 'org-1', name: 'Atelier', kind: 'cloud', role: 'methodes');
    await repo.saveWorkshop(w);
    s.workshop = w;

    final g = await s.saveGamme(s.newGamme(chemise()));
    final run = await s.runLocal(g.problem, gammeId: g.id);
    final sess = await s.openSession(run, model: 'Chemise', date: '2026-11-24');
    await s.addEntry(sess, 1, pieces: 3);
    await _settle(s);
    await s.sync(); // hors ligne
    expect(repo.outbox().map((o) => o.type).toList(), ['save_gamme', 'push_run', 'open_session']);
    expect(s.net, NetStatus.offline);

    online = true;
    await _settle(s);
    await s.sync();
    expect(repo.outbox(), isEmpty);
    expect(repo.gamme(g.id)!.cloudId, 'p-1');
    expect(repo.run(run.id)!.cloudId, 'r-1');
    expect(repo.session(sess.id)!.cloudId, 's-1');
    expect(repo.entries(sess.id).every((e) => e.synced), isTrue);
    expect(calls.where((c) => c.startsWith('POST')).length, 4);
  });
}

Future<void> _settle(AppState s) async {
  while (s.syncing) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Client API « connecté » pour les tests (jeton factice, aucune clé réelle).
class _SignedInApi extends ApiClient {
  _SignedInApi(http.Client c) : super(httpClient: c, base: 'https://api.test');
  @override
  String? get accessToken => 'test-token';
}
