// Rendu des écrans principaux (téléphone, tablette, bureau) avec l'exemple chemise.
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
import 'package:textile_balancer_flutter/features/calcul/new_run_screen.dart';
import 'package:textile_balancer_flutter/features/gamme/gamme_editor_screen.dart';
import 'package:textile_balancer_flutter/features/production/production_dashboard_screen.dart';
import 'package:textile_balancer_flutter/features/production/production_entry_screen.dart';
import 'package:textile_balancer_flutter/features/results/result_screen.dart';
import 'package:textile_balancer_flutter/features/simulation/simulation_screen.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';
import 'package:textile_balancer_flutter/ui/shell.dart';
import 'package:textile_balancer_flutter/ui/theme.dart';

String _f(String n) => File('test/fixtures/csv/$n').readAsStringSync();

Future<(AppState, GammeRecord, RunRecord, SessionRecord)> _setup() async {
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
  await s.addEntry(sess, 2, downtimeReason: 'panne');
  return (s, g, run, sess);
}

Widget _wrap(AppState s, Widget child) => MultiProvider(
      providers: [ChangeNotifierProvider.value(value: s), ChangeNotifierProvider(create: (_) => ShellNav())],
      child: MaterialApp(theme: buildTheme(), home: child),
    );

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  const sizes = [Size(390, 844), Size(820, 1180), Size(1440, 900)];
  final screens = <String, Widget Function(GammeRecord g, RunRecord r, SessionRecord x)>{
    'éditeur de gamme': (g, r, x) => GammeEditorScreen(gammeId: g.id),
    'nouveau calcul': (g, r, x) => const Scaffold(body: NewRunScreen()),
    'résultat': (g, r, x) => ResultScreen(runId: r.id),
    'simulation': (g, r, x) => SimulationScreen(runId: r.id),
    'saisie tablette': (g, r, x) => ProductionEntryScreen(sessionId: x.id),
    'tableau de bord production': (g, r, x) => ProductionDashboardScreen(sessionId: x.id),
  };

  for (final size in sizes) {
    for (final e in screens.entries) {
      testWidgets('${e.key} — ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late (AppState, GammeRecord, RunRecord, SessionRecord) d;
        await tester.runAsync(() async => d = await _setup());
        await tester.pumpWidget(_wrap(d.$1, e.value(d.$2, d.$3, d.$4)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        // onglets de l'éditeur
        if (e.key == 'éditeur de gamme') {
          for (final t in ['Postes', 'Ouvriers', 'Diagnostic']) {
            await tester.tap(find.textContaining(t).first);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.text('Vérifier').last);
          await tester.pumpAndSettle();
          expect(find.textContaining('MACHINE_CAPACITY'), findsWidgets);
        }
        if (e.key == 'résultat') {
          expect(find.text('Yamazumi — charge par station'), findsOneWidget);
          expect(find.text('Répartition'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
