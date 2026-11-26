// Simulation détaillée (DES) : écran hors ligne et résultats serveur (fixture), téléphone / tablette / bureau.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/features/analysis/analysis_hub_screen.dart';
import 'package:textile_balancer_flutter/features/des/des_screen.dart';

import 'support/fx.dart';

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  for (final size in sizes) {
    final tag = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('DES hors ligne — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => DesScreen(runId: fx.run.id));
      expect(find.text('Simulation détaillée'), findsOneWidget);
      expect(find.textContaining('Fonction serveur'), findsOneWidget);
      expect(find.byKey(const Key('des-run')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('DES résultats (fixture API) — $tag', (tester) async {
      final sim = apiFixture('des_simulation');
      await pumpAt(tester, size, (fx) => DesResultScreen(simId: '${sim['id']}', initial: sim));
      await tester.pumpAndSettle();
      expect(find.text('Flutter live DES'), findsWidgets);
      expect(find.text('3 réplication(s) · IC 95 %'), findsOneWidget);
      expect(find.text('280'), findsWidgets); // référence : pièces / jour sans IC
      // 2e scénario : pièces / jour avec intervalle de confiance
      await tester.tap(find.text('Pannes + variabilité').first);
      await tester.pumpAndSettle();
      expect(find.text('207 ± 38'), findsOneWidget);
      expect(find.text('Comparaison (moyenne [IC 95 %])'), findsOneWidget);
      expect(find.textContaining('Occupation des stations'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Analyse : outil DES en ligne seulement — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => const Scaffold(body: AnalysisHubScreen()));
      expect(find.byKey(const Key('tool-des')), findsOneWidget);
      expect(find.text('En ligne uniquement'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
