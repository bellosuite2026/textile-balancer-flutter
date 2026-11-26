// Outils communs aux tests des écrans d'analyse : atelier local avec l'exemple chemise.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:textile_balancer_flutter/data/api_client.dart';
import 'package:textile_balancer_flutter/data/local_store.dart';
import 'package:textile_balancer_flutter/data/records.dart';
import 'package:textile_balancer_flutter/data/repository.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';
import 'package:textile_balancer_flutter/ui/shell.dart';
import 'package:textile_balancer_flutter/ui/theme.dart';

Map<String, dynamic> apiFixture(String n) =>
    (jsonDecodeFile('test/fixtures/api/$n.json') as Map).cast<String, dynamic>();

Object? jsonDecodeFile(String path) => const JsonDecoder().convert(File(path).readAsStringSync());

String fixtureCsv(String n) => File('test/fixtures/csv/$n').readAsStringSync();

class Fx {
  Fx(this.state, this.run, this.session);
  final AppState state;
  final RunRecord run;
  final SessionRecord session;
}

Future<Fx> setupFx() async {
  final s = AppState(repo: Repository(MemoryLocalStore()), api: ApiClient(), enableNetwork: false);
  await s.init();
  await s.startLocalMode();
  final p = Problem(
    name: 'Chemise homme',
    targetCycleTime: 1.5,
    operations: parseSamCsv(fixtureCsv('sam_chemise_homme.csv')),
    workstations: parseWorkstationsCsv(fixtureCsv('workstations_chemise.csv')),
    workers: parseWorkersCsv(fixtureCsv('workers_chemise.csv')),
  );
  final g = await s.saveGamme(s.newGamme(p));
  final run = RunRecord(
    id: 'r1',
    workshopId: s.workshop!.id,
    gammeId: g.id,
    problem: p,
    kind: 'balance',
    solver: 'rpw',
    source: 'local',
    status: 'done',
    result: solveRpw(p),
  );
  await s.repo.saveRun(run);
  final sess = await s.openSession(run, model: 'Chemise', date: '2026-11-24');
  await s.addEntry(sess, 1, pieces: 12);
  return Fx(s, run, sess);
}

Widget wrap(AppState s, Widget child) => MultiProvider(
      providers: [ChangeNotifierProvider.value(value: s), ChangeNotifierProvider(create: (_) => ShellNav())],
      child: MaterialApp(theme: buildTheme(), home: child),
    );

const sizes = [Size(390, 844), Size(820, 1180), Size(1440, 900)];

Future<Fx> pumpAt(WidgetTester tester, Size size, Widget Function(Fx) screen) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late Fx fx;
  await tester.runAsync(() async => fx = await setupFx());
  await tester.pumpWidget(wrap(fx.state, screen(fx)));
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
  return fx;
}

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

