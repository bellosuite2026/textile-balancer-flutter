// Process Flow : disposition par niveaux, chemin critique, anomalies de gamme ; écran (téléphone / tablette / bureau).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/engine/flow.dart';
import 'package:textile_balancer_flutter/features/analysis/analysis_hub_screen.dart';
import 'package:textile_balancer_flutter/features/flow/process_flow_screen.dart';

import 'support/fx.dart';

Operation op(String id, double d, [List<String> p = const []]) => Operation(id: id, name: 'Op $id', duration: d, predecessors: [...p]);

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  group('graphe', () {
    test('niveaux = plus long chemin, chemin critique pondéré par les SAM', () {
      // A → B → D ; A → C → D ; C plus long que B ; E isolée
      final g = FlowGraph.build([
        op('A', 1),
        op('B', 0.5, ['A']),
        op('C', 2, ['A']),
        op('D', 1, ['B', 'C']),
        op('E', 0.2),
      ]);
      expect({for (final n in g.nodes) n.id: n.level}, {'A': 0, 'B': 1, 'C': 1, 'D': 2, 'E': 0});
      expect(g.levels, 3);
      expect(g.edges, hasLength(4));
      expect(g.critical, ['A', 'C', 'D']);
      expect(g.criticalMinutes, 4);
      expect(g.criticalEdges, {('A', 'C'), ('C', 'D')});
      expect(g.predecessorsOf('D'), unorderedEquals(['B', 'C']));
      expect(g.cycle, isEmpty);
      // pas de chevauchement dans un niveau
      for (final l in {for (final n in g.nodes) n.level}) {
        final rows = [
          for (final n in g.nodes)
            if (n.level == l) n.row,
        ];
        expect(rows.toSet().length, rows.length);
      }
    });

    test('précédences inconnues ignorées, cycles détectés', () {
      final g = FlowGraph.build([
        op('A', 1, ['Z']),
        op('B', 1, ['C']),
        op('C', 1, ['B']),
      ]);
      expect(g.unknownPredecessors, [('A', 'Z')]);
      expect(g.cycle, {'B', 'C'});
      expect(g.nodes, hasLength(3));
      expect(g.critical, ['A']);
    });

    test('gamme chemise : toutes les opérations, chemin critique ≤ SAM total', () {
      final ops = parseSamCsv(fixtureCsv('sam_chemise_homme.csv'));
      final g = FlowGraph.build(ops);
      expect(g.nodes, hasLength(ops.length));
      expect(g.cycle, isEmpty);
      final total = ops.fold(0.0, (a, o) => a + o.duration);
      expect(g.criticalMinutes, greaterThan(0));
      expect(g.criticalMinutes, lessThanOrEqualTo(total + 1e-9));
      expect(
        g.critical.first,
        isIn([
          for (final o in ops)
            if (o.predecessors.isEmpty) o.id,
        ]),
      );
    });
  });

  for (final size in sizes) {
    final tag = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('Process Flow depuis un résultat — $tag', (tester) async {
      final fx = await pumpAt(tester, size, (fx) => ProcessFlowScreen(runId: fx.run.id));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('flow-canvas')), findsOneWidget);
      final b = fx.run.balance!;
      expect(find.text('Goulot : station ${b.bottleneck!.station}'), findsOneWidget);
      expect(find.textContaining('${fx.run.problem.operations.length} opérations'), findsOneWidget);
      // zoom, ajuster, options
      await tester.tap(find.byKey(const Key('flow-zoom-in')));
      await tester.tap(find.byKey(const Key('flow-zoom-out')));
      await tester.tap(find.byKey(const Key('flow-fit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('flow-critical')));
      await tester.tap(find.byKey(const Key('flow-by-station')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('flow-by-station')));
      await tester.pumpAndSettle();
      // toucher le premier nœud → détail (position calculée dans le repère du graphe)
      final g = FlowGraph.build(fx.run.problem.operations);
      final n = g.nodes.first;
      final local = flowNodeOrigin(n) + const Offset(40, 30);
      final canvas = find.byKey(const Key('flow-canvas'));
      final box = tester.renderObject<RenderBox>(canvas);
      await tester.tapAt(box.localToGlobal(local));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('flow-details')), findsOneWidget);
      expect(find.textContaining('Station ${b.operationAssignments[n.id]}'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Analyse : Process Flow hors ligne — $tag', (tester) async {
      await pumpAt(tester, size, (fx) => const Scaffold(body: AnalysisHubScreen()));
      await tapVisible(tester, find.byKey(const Key('tool-flow')));
      await tester.tap(find.text('Chemise homme').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('flow-canvas')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
