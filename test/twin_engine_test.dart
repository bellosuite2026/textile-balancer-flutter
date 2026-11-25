// Jumeau numérique : moteur de journée par paquets (portage de engine/simulation.py) et mapping.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';

String _f(String n) => File('test/fixtures/csv/$n').readAsStringSync();

Problem chemise([double cadence = 1.5]) => Problem(
      name: 'Chemise homme',
      targetCycleTime: cadence,
      operations: parseSamCsv(_f('sam_chemise_homme.csv')),
      workstations: parseWorkstationsCsv(_f('workstations_chemise.csv')),
      workers: parseWorkersCsv(_f('workers_chemise.csv')),
    );

void main() {
  final p = chemise();
  final r = solveRpw(p);
  final plan = twinPlan(r, p);

  test('plan du jumeau : stations, compétences et ouvrières', () {
    expect((plan['stations'] as List).length, r.stationsUsed);
    final st = (plan['stations'] as List).first as Map;
    expect(st['operations'], isNotEmpty);
    expect((st['operations'] as List).first, containsPair('skills', isA<List>()));
    expect(plan['workers'], isA<Map>());
  });

  test('implantations par défaut : ligne et U', () {
    final ids = stationOrder(plan);
    final line = defaultLayout(ids, 'line');
    final u = defaultLayout(ids, 'u');
    expect(line['kind'], 'line');
    expect(((line['positions'] as Map)['${ids[1]}'] as Map)['x'], closeTo(1.6, 1e-9));
    expect(u['kind'], 'u');
    expect(((u['positions'] as Map)['${ids.last}'] as Map)['y'], closeTo(1.4, 1e-9));
  });

  test('journée simulée : production cohérente avec la cadence et goulot', () {
    final lay = defaultLayout(stationOrder(plan));
    final res = simulateLineDay(plan, lay, const LineDayConfig(variability: 0));
    final perHour = res['per_hour'] as double;
    // cadence 1,5 min → 40 pièces/h en régime ; + vidange de l'encours de départ (1 paquet par poste)
    expect(perHour, greaterThan(25));
    expect(perHour, lessThanOrEqualTo(60 / r.actualCycleTime * 1.15));
    // parité avec engine/simulation.py (SimPy) sans variabilité : 350 pièces, 43,8 pcs/h, goulot 5
    expect(res['pieces'], 350);
    expect(perHour, 43.8);
    expect(res['bottleneck'], 5);
    expect(res['wip_avg'] as double, closeTo(196.8, 1.0));
    expect(res['lead_time_min'] as double, closeTo(238.9, 1.5));
    expect(stationOrder(plan), contains(res['bottleneck']));
    expect((res['hourly'] as List).length, 8);
    expect((res['trace'] as Map)['events'], isNotEmpty);
    // ignore: avoid_print
    print('chemise 1.5 : ${res['pieces']} pcs/j, ${res['per_hour']} pcs/h, goulot ${res['bottleneck']}, '
        'encours moy ${res['wip_avg']}, traversée ${res['lead_time_min']} min, cycle réel ${r.actualCycleTime}');
  });

  test('déterministe à graine égale ; panne et absence dégradent la production', () {
    final lay = defaultLayout(stationOrder(plan));
    final out = runTwinScenarios(plan, lay, [
      twinScenario(name: 'Référence'),
      twinScenario(name: 'Panne', breakdowns: [
        {'station': stationOrder(plan)[2], 'start_min': 60, 'duration_min': 90},
      ]),
      twinScenario(name: 'Absence', absent: [
        for (final s in (plan['stations'] as List).take(1)) ...((s as Map)['worker_ids'] as List).map((e) => '$e'),
      ]),
    ]);
    final sc = (out['scenarios'] as List).cast<Map>();
    final again = simulateLineDay(plan, lay, LineDayConfig.fromScenario(twinScenario()));
    expect(again['pieces'], (sc[0]['result'] as Map)['pieces']);
    expect((sc[1]['result'] as Map)['pieces'], lessThan((sc[0]['result'] as Map)['pieces'] as int));
    expect(((sc[1]['result'] as Map)['notes'] as List).last, contains('Panne station'));
    final cmp = (out['comparison'] as List).cast<Map>();
    expect(cmp.first['key'], 'pieces');
    expect((cmp.first['values'] as List).length, 3);
    expect(cmp.map((e) => e['label']), contains('Goulot (station)'));
  });

  test('scénario : effectif imposé et réaffectation selon compétences', () {
    final sid = stationOrder(plan).first;
    final (p2, notes) = applyScenario(plan, {
      'operators': {'$sid': 3},
    });
    final st = (p2['stations'] as List).cast<Map>().firstWhere((s) => s['station'] == sid);
    expect(st['operators'], 3);
    expect(notes.single, contains('effectif porté à 3'));
  });

  test('animation : reconstitution de l\'état des paquets depuis la trace', () {
    final res = simulateLineDay(plan, defaultLayout(stationOrder(plan)), const LineDayConfig(shiftMinutes: 60));
    final tr = TwinTrace(res);
    expect(tr.isEmpty, isFalse);
    final views = tr.at(30);
    expect(views, isNotEmpty);
    expect(views.map((v) => v.state).toSet().difference({'queue', 'work', 'transit'}), isEmpty);
    expect(tr.finishedAt(60), greaterThanOrEqualTo(0));
  });

  test('résultat de l\'API (format results.scenarios[].result) lisible par l\'animation', () {
    final api = {
      'stations': [
        {'station': 1},
        {'station': 2},
      ],
      'config': {'bundle_size': 10},
      'trace': {
        'events': [
          [0.0, 1, 1, 0],
          [0.0, 1, 1, 1, 'W1'],
          [5.0, 1, 1, 2, 'W1'],
          [5.2, 1, 2, 0],
        ],
        'bundles': {'1': 10},
        'truncated': false,
      },
      'snapshots': [
        [0.0, [10, 0], 0],
      ],
    };
    final tr = TwinTrace(api);
    expect(tr.at(2).single.state, 'work');
    expect(tr.at(2).single.worker, 'W1');
    expect(tr.at(5.1).single.state, 'transit');
    expect(tr.at(5.1).single.toStation, 2);
    expect(tr.at(6).single.state, 'queue');
  });
}
