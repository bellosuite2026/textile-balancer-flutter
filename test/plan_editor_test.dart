// Éditeur de plan : outils (bureau 1440×900), clavier, annuler/rétablir, calques, mesure, convoyeur, 3D.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/features/twin/twin_screen.dart';
import 'package:textile_balancer_flutter/features/workshop/plan_editor_screen.dart';

import 'support/fx.dart';

Future<(Fx, PlanEditorScreenState, Rect)> _open(WidgetTester tester, {Size size = const Size(1440, 900)}) async {
  final fx = await pumpAt(tester, size, (fx) => const SizedBox());
  await tester.runAsync(() async {
    final plan = newWorkshopPlan(id: 'p-ed', name: 'Atelier', width: 20, length: 12);
    (plan['elements'] as List).addAll([
      newMachine('m1', 'piqueuse_plate', 4, 4, label: 'M01'),
      newMachine('m2', 'piqueuse_plate', 8, 5, label: 'M02'),
      newMachine('m3', 'surjeteuse_4_fils', 12, 4.5, label: 'M03'),
      {'id': 'w1', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 20, 'y2': 0, 'thickness': 0.2},
    ]);
    await fx.state.savePlan(plan);
  });
  await tester.pumpWidget(wrap(fx.state, const PlanEditorScreen(planId: 'p-ed')));
  await tester.pumpAndSettle();
  final st = tester.state<PlanEditorScreenState>(find.byType(PlanEditorScreen));
  return (fx, st, tester.getRect(find.byKey(const Key('plan-canvas'))));
}

List<Map> _els(PlanEditorScreenState st) => [for (final e in st.plan!['elements'] as List) e as Map];

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  testWidgets('outils, encadrement, alignement, clavier, annuler/rétablir', (tester) async {
    final (_, st, canvas) = await _open(tester);
    // encadrer les 3 machines (glisser dans le vide sur toute la salle)
    await tester.dragFrom(canvas.topLeft + const Offset(4, 4), canvas.bottomRight - canvas.topLeft - const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('4 éléments'), findsOneWidget); // 3 machines + le mur
    expect(find.byKey(const Key('align-row')), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('align-row')));
    final ys = {for (final e in _els(st)) if (e['kind'] == 'machine') e['y']};
    expect(ys.length, 1);
    // annuler / rétablir (boutons puis clavier)
    await tapVisible(tester, find.byKey(const Key('plan-undo')));
    expect({for (final e in _els(st)) if (e['kind'] == 'machine') e['y']}.length, greaterThan(1));
    await tapVisible(tester, find.byKey(const Key('plan-redo')));
    expect({for (final e in _els(st)) if (e['kind'] == 'machine') e['y']}.length, 1);
    // Ctrl+C / Ctrl+V : 3 machines de plus, renumérotées
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(_els(st).where((e) => e['kind'] == 'machine').length, 6);
    expect(_els(st).map((e) => e['label']), contains('M06'));
    // Suppr efface la sélection (les copies), Ctrl+Z la restaure
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(_els(st).where((e) => e['kind'] == 'machine').length, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(_els(st).where((e) => e['kind'] == 'machine').length, 6);
    // Ctrl+A puis R pivote les machines, flèches déplacent
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_els(st).where((e) => e['kind'] == 'machine' && e['rot'] == 90).length, 6);
    // Échap désélectionne, E = gomme
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(find.textContaining('Touchez un élément pour le supprimer'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gomme, calques, mesure gardée, convoyeur, vue 3D', (tester) async {
    final (_, st, canvas) = await _open(tester);
    final v = PlanEditorProbe(tester, st);
    // gomme sur M01
    await tapVisible(tester, find.byKey(const Key('tool-erase')));
    await tester.pumpAndSettle();
    await tester.tapAt(v.at(4, 4));
    await tester.pumpAndSettle();
    expect(_els(st).any((e) => e['id'] == 'm1'), isFalse);
    // calque Machines masqué : la gomme ne touche plus M02
    await tapVisible(tester, find.byKey(const Key('layer-machine')));
    await tester.tapAt(v.at(8, 5));
    await tester.pumpAndSettle();
    expect(_els(st).any((e) => e['id'] == 'm2'), isTrue);
    await tapVisible(tester, find.byKey(const Key('layer-machine')));
    // mesure : distance gardée comme cote
    await tapVisible(tester, find.byKey(const Key('tool-measure')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('measure-keep')));
    await tester.tapAt(v.at(2, 9));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(v.at(7, 9));
    await tester.pumpAndSettle();
    final dims = _els(st).where((e) => e['kind'] == 'dim').toList();
    expect(dims.length, 1);
    expect(dimText(dims.single), '5,00 m');
    // chemin à pied M02 → M03
    await tapVisible(tester, find.byKey(const Key('measure-walk')));
    await tester.tapAt(v.at(8, 5));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(v.at(12, 4.5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chemin à pied M02 → M03'), findsOneWidget);
    // convoyeur : 3 angles puis retour au 1er point
    await tapVisible(tester, find.byKey(const Key('tool-rail')));
    await tester.pumpAndSettle();
    for (final (x, y) in [(2.0, 2.0), (16.0, 2.0), (16.0, 8.0)]) {
      await tester.tapAt(v.at(x, y));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.tapAt(v.at(2, 2));
    await tester.pumpAndSettle();
    final rail = _els(st).where((e) => e['kind'] == 'rail').toList();
    expect(rail.length, 1);
    expect(railLength(rail.single), closeTo(14 + 6 + 15.23, 0.05));
    // vue 3D du plan
    await tapVisible(tester, find.descendant(of: find.byKey(const Key('plan-dim')), matching: find.text('3D')));
    expect(find.byKey(const Key('plan-3d')), findsOneWidget);
    expect(find.byKey(const Key('scene3d-canvas')), findsOneWidget);
    await tester.drag(find.byKey(const Key('scene3d-canvas')), const Offset(60, 10));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: canvas.center);
    await tester.sendEventToBinding(PointerScrollEvent(position: canvas.center, scrollDelta: const Offset(0, -50)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [sizes.last]) {
    testWidgets('jumeau : bascule 2D / 3D, simple / détaillé — ${size.width.toInt()}', (tester) async {
      await pumpAt(tester, size, (fx) => TwinScreen(runId: fx.run.id));
      await tapVisible(tester, find.text('3D'));
      expect(find.byKey(const Key('twin-3d')), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('twin-play')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('twin-play')));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Simple'));
      expect(find.byKey(const Key('scene3d-canvas')), findsOneWidget);
      await tapVisible(tester, find.text('2D'));
      expect(find.byKey(const Key('twin-canvas')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

/// Conversion mètres → écran pour viser un point du plan dans les tests.
class PlanEditorProbe {
  PlanEditorProbe(this.tester, this.st);
  final WidgetTester tester;
  final PlanEditorScreenState st;
  // le canevas se décale quand la barre d'aide change de hauteur : relu à chaque visée
  Offset at(double x, double y) => tester.getRect(find.byKey(const Key('plan-canvas'))).topLeft + st.debugToPx(x, y);
}
