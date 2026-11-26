// Lecture typée des réponses serveur de la phase 2 (fixtures capturées sur l'API réelle).
import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/data/analysis_models.dart';

import 'support/fx.dart';

void main() {
  group('DES', () {
    final sim = apiFixture('des_simulation');
    final res = DesResult.fromSimulation(sim);

    test('scénarios, réplications et intervalles de confiance', () {
      expect(res.engine, 'des-3.1');
      expect(res.replications, 3);
      expect(res.scenarios.map((s) => s.name), ['Référence', 'Pannes + variabilité']);
      final ref = res.scenarios.first, pan = res.scenarios[1];
      expect(ref.kpi('pieces').mean, 280);
      expect(ref.kpi('pieces').hasInterval, isFalse); // aucune variabilité : IC nul
      final p = pan.kpi('pieces');
      expect(p.mean, closeTo(206.67, 1e-9));
      expect(p.lo, closeTo(168.72, 1e-9));
      expect(p.hi, closeTo(244.62, 1e-9));
      expect(p.n, 3);
      expect(p.hasInterval, isTrue);
      expect(p.halfWidth, closeTo(37.95, 1e-9));
      expect(pan.bottleneck, '4');
      expect(pan.kpi('per_hour').mean, closeTo(25.83, 1e-9));
    });

    test('stations, production horaire, comparaison', () {
      final pan = res.scenarios[1];
      expect(pan.stations, isNotEmpty);
      final s1 = pan.stations.first;
      expect(s1.id, '1');
      expect(s1.utilization, 74.7);
      expect(s1.downMin, 76.5);
      expect(s1.states['down'], 15.9);
      expect(pan.hourly, [30, 40, 20, 30, 20, 20, 10, 20]);
      expect(pan.cumulative.first, (0.0, 0.0));
      expect(res.comparison.first.key, 'pieces');
      expect(res.comparison.first.values, hasLength(2));
      expect(pan.overrides['settings'], isA<Map>());
    });

    test('Ci depuis un nombre seul ou un objet vide', () {
      expect(Ci.fromJson(12).mean, 12);
      expect(Ci.fromJson(null).mean, isNull);
      expect(Ci.fromJson({'n': 0, 'mean': null}).hasInterval, isFalse);
    });

    test('corps de scénario', () {
      final ref = desScenarioBody(name: 'Réf', reference: true);
      expect(ref['overrides'], isEmpty);
      final b = desScenarioBody(name: 'S', efficiencyPct: 90, cvPct: 15, mtbfMin: 240, mttrMin: 15, absent: ['S1-1']);
      final st = (b['overrides'] as Map)['settings'] as Map;
      expect(st['efficiency'], 0.9);
      expect((st['dist'] as Map)['cv'], 0.15);
      expect(st['mtbf_min'], 240);
      expect(b['absent'], ['S1-1']);
    });
  });

  group('optimiseur', () {
    final res = OptResult.fromSimulation(apiFixture('opt_simulation'));

    test('objectifs, base, front de Pareto, nuage', () {
      expect(res.objectives.map((o) => o.key), ['pieces', 'cost_minute', 'wip_avg', 'walk_m']);
      expect(res.objectives.first.sense, 'max');
      expect(res.base!.metric('pieces'), 280);
      expect(res.base!.metric('people'), 13);
      expect(res.pareto, hasLength(20));
      expect(res.cloud, hasLength(45));
      expect(res.evals, 45);
      expect(res.stoppedBy, 'budget de temps');
      expect(res.feasibleFound, isTrue);
      final s = res.pareto.first;
      expect(s.id, 1);
      expect(s.changes, isNotEmpty);
      expect(s.kpi('pieces').mean, isNotNull);
    });

    test('compromis : point le plus proche de l\'idéal, sur le front', () {
      final c = res.compromise()!;
      expect(res.pareto.map((s) => s.id), contains(c.id));
    });
  });
}
