// Phase 2 : écrans d'analyse (téléphone, tablette, bureau) avec l'exemple chemise, hors ligne.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/features/analysis/analysis_hub_screen.dart';
import 'package:textile_balancer_flutter/features/twin/twin_screen.dart';
import 'package:textile_balancer_flutter/features/workshop/plan_editor_screen.dart';

import 'support/fx.dart';

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

    testWidgets("plan d'atelier — $tag", (tester) async {
      final fx = await pumpAt(tester, size, (fx) => const WorkshopPlansScreen());
      expect(find.text("Aucun plan d'atelier sur cet appareil."), findsOneWidget);
      // création directe (évite la boîte de dialogue) puis éditeur
      late Map<String, dynamic> plan;
      await tester.runAsync(() async {
        plan = newWorkshopPlan(id: 'p-test', name: 'Atelier test', width: 20, length: 12);
        await fx.state.savePlan(plan);
      });
      await tester.pumpWidget(wrap(fx.state, const PlanEditorScreen(planId: 'p-test')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-canvas')), findsOneWidget);
      final canvas = tester.getRect(find.byKey(const Key('plan-canvas')));
      // poser une machine
      await tapVisible(tester, find.byKey(const Key('tool-machine')));
      await tester.tapAt(canvas.center);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('el-rotate')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('el-rotate')));
      // tracer un mur
      await tapVisible(tester, find.byKey(const Key('tool-wall')));
      await tester.dragFrom(canvas.center + const Offset(-60, 40), const Offset(120, 0));
      await tester.pumpAndSettle();
      // sélection + déplacement de la machine
      await tapVisible(tester, find.byKey(const Key('tool-select')));
      await tester.dragFrom(canvas.center, const Offset(30, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan-save')));
      await tester.pumpAndSettle();
      final saved = fx.state.repo.plan('p-test')!;
      final kinds = [for (final e in saved['elements'] as List) (e as Map)['kind']];
      expect(kinds, containsAll(['machine', 'wall']));
      final m = (saved['elements'] as List).cast<Map>().firstWhere((e) => e['kind'] == 'machine');
      expect(m['rot'], 90);
      expect(tester.takeException(), isNull);
      // le jumeau utilise le plan
      await tester.pumpWidget(wrap(fx.state, TwinScreen(runId: fx.run.id)));
      await tester.pumpAndSettle();
      expect(find.text('Jumeau numérique 2D'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
