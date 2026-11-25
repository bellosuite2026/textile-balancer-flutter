// Phase 2 : écrans d'analyse (téléphone, tablette, bureau) avec l'exemple chemise, hors ligne.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:textile_balancer_flutter/data/api_client.dart';
import 'package:textile_balancer_flutter/data/local_store.dart';
import 'package:textile_balancer_flutter/data/records.dart';
import 'package:textile_balancer_flutter/data/repository.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/features/analysis/analysis_hub_screen.dart';
import 'package:textile_balancer_flutter/features/twin/twin_screen.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';
import 'package:textile_balancer_flutter/ui/shell.dart';
import 'package:textile_balancer_flutter/ui/theme.dart';

String _f(String n) => File('test/fixtures/csv/$n').readAsStringSync();

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
    operations: parseSamCsv(_f('sam_chemise_homme.csv')),
    workstations: parseWorkstationsCsv(_f('workstations_chemise.csv')),
    workers: parseWorkersCsv(_f('workers_chemise.csv')),
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

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  for (final size in sizes) {
    final tag = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('jumeau numérique — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => TwinScreen(runId: fx.run.id));
      expect(find.text('Jumeau numérique 2D'), findsOneWidget);
      expect(find.text('Production / h'), findsOneWidget);
      expect(find.text('Goulot'), findsOneWidget);
      expect(find.byKey(const Key('twin-canvas')), findsOneWidget);
      // lecture puis pause
      await tapVisible(tester, find.byKey(const Key('twin-play')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('twin-play')));
      await tester.pumpAndSettle();
      expect(find.textContaining('pièces finies'), findsOneWidget);
      // dispositions U puis libre
      await tapVisible(tester, find.text('U'));
      await tapVisible(tester, find.text('Libre'));
      expect(find.text('Glissez les postes pour les déplacer.'), findsOneWidget);
      // 2e scénario + comparaison
      await tapVisible(tester, find.byKey(const Key('twin-add-scenario')));
      await tapVisible(tester, find.byKey(const Key('twin-simulate')));
      expect(find.text('Comparaison des scénarios'), findsOneWidget);
      expect(find.text('Pièces / heure'), findsOneWidget);
      // réel vs simulé
      await tapVisible(tester, find.textContaining('Chemise · 2026-11-24'));
      expect(find.text('Prévision fin de journée'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('section Analyse — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => const Scaffold(body: AnalysisHubScreen()));
      expect(find.text('Jumeau numérique 2D'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('tool-twin')));
      expect(find.textContaining('choisir un calcul'), findsOneWidget);
      await tester.tap(find.text('Chemise homme').last);
      await tester.pumpAndSettle();
      expect(find.text('Jumeau numérique 2D'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
