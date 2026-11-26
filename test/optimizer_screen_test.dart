// Optimiseur Pareto : état hors ligne, résultats serveur (fixture), choix d'un compromis — téléphone / tablette / bureau.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/data/analysis_models.dart';
import 'package:textile_balancer_flutter/features/analysis/analysis_hub_screen.dart';
import 'package:textile_balancer_flutter/features/optimizer/optimizer_screen.dart';

import 'support/fx.dart';

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  test('solution recommandée = coût minute le plus bas sans perte de production (parité web)', () {
    final res = OptResult.fromSimulation(apiFixture('opt_simulation'));
    final r = res.recommended()!;
    expect(r.id, 2);
    expect(r.metric('pieces'), 285);
    expect(r.metric('cost_minute'), 0.0796);
    expect(r.metric('people'), 13);
    expect(r.metric('wip_avg'), 65);
    final body = optConfigBody(objectives: ['pieces', 'walk_m'], maxPeople: 14, minPerHour: 30);
    expect(body['objectives'], ['pieces', 'walk_m']);
    expect((body['constraints'] as Map)['max_people'], 14);
  });

  for (final size in sizes) {
    final tag = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('optimiseur hors ligne — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => OptimizerScreen(runId: fx.run.id));
      expect(find.text('Optimiseur Pareto'), findsOneWidget);
      expect(find.text('En ligne seulement'), findsOneWidget);
      expect(find.textContaining('Fonction serveur'), findsOneWidget);
      expect(find.byKey(const Key('opt-run')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('optimiseur résultats (fixture API) — $tag', (tester) async {
      final res = OptResult.fromSimulation(apiFixture('opt_simulation'));
      ParetoSolution? applied;
      await pumpAt(
        tester,
        size,
        (fx) => Scaffold(
          body: SingleChildScrollView(
            child: OptResultView(result: res, onApply: (s) async => applied = s),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Front de Pareto · 20 compromis'), findsOneWidget);
      expect(find.byKey(const Key('opt-scatter')), findsOneWidget);
      expect(find.text('Solution 2 — recommandée'), findsOneWidget);
      // couleur = encours
      await tapVisible(tester, find.descendant(of: find.byType(SegmentedButton<String>), matching: find.text('Encours')));
      // choisir le compromis équilibré puis la ligne 10 du tableau
      await tapVisible(tester, find.byKey(const Key('opt-pick-balanced')));
      await tapVisible(tester, find.descendant(of: find.byType(DataTable).last, matching: find.text('10')));
      expect(find.text('Solution 10'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('opt-apply')));
      expect(applied?.id, 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Analyse : optimiseur listé, en ligne uniquement — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => const Scaffold(body: AnalysisHubScreen()));
      expect(find.byKey(const Key('tool-opt')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
