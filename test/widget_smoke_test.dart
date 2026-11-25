import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/app.dart';
import 'package:textile_balancer_flutter/data/api_client.dart';
import 'package:textile_balancer_flutter/data/local_store.dart';
import 'package:textile_balancer_flutter/data/repository.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';

Future<void> nav(WidgetTester tester, String label) async {
  final bar = find.byType(NavigationBar);
  final scope = bar.evaluate().isNotEmpty ? bar : find.byType(NavigationRail);
  await tester.tap(find.descendant(of: scope, matching: find.text(label)));
}

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  for (final size in const [Size(390, 844), Size(1024, 768), Size(1440, 900)]) {
    testWidgets('démarrage en mode local puis navigation (${size.width.toInt()} px)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(repo: Repository(MemoryLocalStore()), api: ApiClient(), enableNetwork: false);
      await state.init();
      await tester.pumpWidget(TextileBalancerApp(state: state));
      expect(find.text('Mode local sans compte'), findsOneWidget);
      await tester.tap(find.byKey(const Key('local-mode')));
      await tester.pumpAndSettle();
      expect(find.text('Tableau de bord'), findsWidgets);
      // Gammes
      await nav(tester, 'Gammes');
      await tester.pumpAndSettle();
      expect(find.text('Nouvelle gamme'), findsOneWidget);
      // Nouveau calcul sans gamme
      await nav(tester, size.width < 600 ? 'Calcul' : 'Nouveau calcul');
      await tester.pumpAndSettle();
      expect(find.text('Aucune gamme sur cet appareil.'), findsOneWidget);
      // Production
      await nav(tester, 'Production');
      await tester.pumpAndSettle();
      expect(find.text('Démarrer une session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
