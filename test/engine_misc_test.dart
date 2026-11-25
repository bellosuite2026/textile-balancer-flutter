import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';

Problem chemise({double cycle = 1.5, bool full = true}) => Problem(
      name: 'Chemise homme',
      targetCycleTime: cycle,
      operations: parseSamCsv(File('test/fixtures/csv/sam_chemise_homme.csv').readAsStringSync()),
      workstations: full ? parseWorkstationsCsv(File('test/fixtures/csv/workstations_chemise.csv').readAsStringSync()) : [],
      workers: full ? parseWorkersCsv(File('test/fixtures/csv/workers_chemise.csv').readAsStringSync()) : [],
    );

void main() {
  group('Arrondis identiques à Python', () {
    test('égalités exactes : au pair', () {
      expect(pyRound(0.125, 2), 0.12);
      expect(pyRound(0.375, 2), 0.38);
      expect(pyRound(2.5, 0), 2.0);
      expect(pyRound(3.5, 0), 4.0);
      expect(pyFixed(0.125, 2), '0.12');
      expect(pyFixed(1.005, 2), '1.00'); // 1.005 vaut 1.00499999… en binaire
      expect(pyFixed(2.675, 2), '2.67');
      expect(pyFixed(-1.25, 1), '-1.2');
    });
    test('cas courants', () {
      expect(pyRound(68.75000000001, 1), 68.8);
      expect(pyRound(1.0499999, 3), 1.05);
      expect(pyFixed(16.5, 2), '16.50');
      expect(pyFixed(3.2, 2), '3.20');
    });
  });

  group('Lecture CSV : parité avec engine/parsers.py', () {
    for (final f in Directory('test/fixtures/csv').listSync().whereType<File>().where((f) => f.path.endsWith('.csv'))) {
      final name = f.uri.pathSegments.last;
      test(name, () {
        final exp = jsonDecode(File(f.path.replaceAll('.csv', '.expected.json')).readAsStringSync()) as List;
        final text = f.readAsStringSync();
        final got = name.startsWith('sam_')
            ? parseSamCsv(text).map((o) => o.toJson()).toList()
            : name.startsWith('workers_')
                ? parseWorkersCsv(text).map((o) => o.toJson()).toList()
                : parseWorkstationsCsv(text).map((o) => o.toJson()).toList();
        expect(jsonEncode(got), jsonEncode(exp));
      });
    }
  });

  group('Chemise du manuel', () {
    test('21 opérations, SAM 16,50 min, N_min 11 à la cadence 1,5', () {
      final p = chemise();
      expect(p.operations.length, 21);
      expect(pyRound(p.totalSam, 2), 16.5);
      expect(theoreticalMinStations(p.totalSam, 1.5), 11);
      expect(p.workstations.length, 14);
      expect(p.workers.length, 20); // le manuel annonce 19 ; le fichier d'exemple en contient 20
    });
    test('RPW opérations seules : stations ≥ N_min, cadence respectée, précédences respectées', () {
      final p = chemise(full: false);
      final r = solveRpw(p);
      expect(r.compliant, isTrue);
      expect(r.stationsUsed, greaterThanOrEqualTo(11));
      for (final s in r.stationDetails) {
        expect(s.totalTime, lessThanOrEqualTo(1.5 + 1e-6));
      }
      expect(precedenceViolations(p, r.stationDetails), isEmpty);
      final placed = {for (final s in r.stationDetails) ...s.operations};
      expect(placed.length, 21);
    });
    test('objectif → cadence : 2 400 pièces en 5 jours de 8 h à 85 % = 0,85 min', () {
      expect(cycleFromObjective(quantity: 2400, days: 5, hoursPerDay: 8), closeTo(0.85, 1e-12));
    });
  });

  group('Simulation simple', () {
    test('ligne équilibrée déterministe : débit = 60 / goulot', () {
      final st = [const SimStation(1, 1.0, 1), const SimStation(2, 1.5, 1), const SimStation(3, 0.8, 1)];
      final r = simulateLine(st, const SimConfig(durationMinutes: 480, bufferCapacity: 5));
      expect(r.bottleneckStation, 2);
      // remplissage initial : ~ (1 + 1,5 + 0,8) min avant la 1re pièce
      expect(r.completed, inInclusiveRange(316, 320));
      expect(r.throughputPerHour, closeTo(40, 0.6));
      expect(r.stations[1].utilization(480), greaterThan(0.99));
    });
    test('postes parallèles et efficience', () {
      final st = [const SimStation(1, 0.5, 1), const SimStation(2, 0.5, 2)]; // 0,5 min/pc par opérateur
      final r = simulateLine(st, const SimConfig(durationMinutes: 600, efficiency: 0.5));
      expect(r.throughputPerHour, closeTo(60, 1)); // 1 min/pc à 50 %
    });
    test('à partir d\'un résultat RPW', () {
      final r = solveRpw(chemise(full: false));
      final sim = simulateLine(stationsFromResult(r));
      expect(sim.throughputPerHour, closeTo(r.outputPerHour, r.outputPerHour * 0.05));
    });
  });

  group('Production (tableau de bord)', () {
    test('objectif à date, alerte 80 %, efficience, goulot observé', () {
      final r = solveRpw(chemise(full: false));
      final plan = buildPlan(r, chemise(full: false));
      final now = DateTime(2026, 11, 24, 10, 0);
      final session = {
        'id': 's1',
        'status': 'open',
        'session_date': '2026-11-24',
        'shift_start': '08:00',
        'shift_hours': 8,
        'target_per_hour': 40,
        'plan': plan,
      };
      final stations = [for (final s in plan['stations'] as List) (s as Map)['station'] as int];
      final entries = <Map<String, dynamic>>[
        for (final n in stations) {'client_id': 'a$n', 'station': n, 'slot_hour': 8, 'pieces': n == stations.last ? 50 : 70},
        {'client_id': 'stop', 'station': stations.first, 'slot_hour': 9, 'downtime_reason': 'panne', 'downtime_minutes': 20},
      ];
      final d = productionDashboard(session, entries, now: now);
      expect(d['elapsed_minutes'], 120.0);
      expect(d['expected_to_date'], 80.0);
      expect(d['output'], 50);
      expect(d['pct_target'], 62.5);
      expect(d['bottleneck_observed'], stations.last);
      expect(d['bottleneck_planned'], isNotNull);
      final kinds = (d['alerts'] as List).map((a) => (a as Map)['kind']).toSet();
      expect(kinds, containsAll(['under_target', 'long_stop']));
      expect(d['downtime_total'], 20.0);
      expect((d['wip'] as List).last['pieces'], 20);
      expect(d['efficiency'], isNotNull);
      expect(defaultTargetPerHour(plan), pyRound(60 / r.actualCycleTime, 1));
    });
  });

  test('collage depuis Excel (tabulations, virgule décimale, sans en-têtes)', () {
    final ops = parsePastedOperations('OP010\tPréparation\t0,45\t\ttable_travail\tlecture_plan\tMontage\n'
        'OP020\tTri\t0,6\tOP010\ttable_travail\ttri_pieces,marquage\tMontage\n');
    expect(ops.length, 2);
    expect(ops[1].duration, 0.6);
    expect(ops[1].predecessors, ['OP010']);
    expect(ops[1].requiredSkills, ['tri_pieces', 'marquage']);
  });
}
