// Plan d'atelier : géométrie, association stations ↔ machines, format API, calibration.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';

String _f(String n) => File('test/fixtures/csv/$n').readAsStringSync();

/// Plan de test : une machine par station du calcul chemise, en ligne tous les 1,5 m.
Map<String, dynamic> planFor(Map<String, dynamic> twin) {
  final p = newWorkshopPlan(id: 'p1', name: 'Test', width: 40, length: 10);
  var i = 0;
  for (final st in (twin['stations'] as List).cast<Map>()) {
    final types = stationPlanMachineTypes(st);
    for (final t in types.isEmpty ? ['table_travail'] : types) {
      final spec = machineCatalog.values.where((m) => m.machineType == t).firstOrNull ??
          machineCatalog.values.where((m) => m.isWorkstation && machineFamily(m.machineType) == machineFamily(t)).firstOrNull;
      (p['elements'] as List).add(newMachine('m${i + 1}', spec?.type ?? 'table_travail', 1 + i * 1.5, 3));
      i++;
    }
  }
  return p;
}

void main() {
  final prob = Problem(
    name: 'Chemise',
    targetCycleTime: 1.5,
    operations: parseSamCsv(_f('sam_chemise_homme.csv')),
    workstations: parseWorkstationsCsv(_f('workstations_chemise.csv')),
    workers: parseWorkersCsv(_f('workers_chemise.csv')),
  );
  final twin = twinPlan(solveRpw(prob), prob);

  test('catalogue : bibliothèque du serveur (38 machines, zones)', () {
    expect(machineCatalog.length, 38);
    expect(machineCatalog['piqueuse_plate']!.w, 1.2);
    expect(machineCatalog['chariot']!.isWorkstation, isFalse);
    expect(workshopZones['montage'], 'Montage');
    expect(normType('Piqueuse plate'), 'piqueuse_plate');
    expect(normType('Surjeteuse 5 fils'), 'surjeteuse_5_fils');
  });

  test('géométrie : coins après rotation, sélection, déplacement', () {
    final m = newMachine('m1', 'piqueuse_plate', 5, 5);
    final c0 = machineCorners(m);
    expect(c0.first.$1, closeTo(4.4, 1e-9));
    m['rot'] = 90;
    final c1 = machineCorners(m);
    expect(c1.first.$1, closeTo(5.3, 1e-9)); // -w/2,-d/2 tourné de 90°
    expect(elementContains(m, 5, 5), isTrue);
    expect(elementContains(m, 8, 8), isFalse);
    moveElement(m, 1, -1);
    expect(m['x'], 6.0);
    expect(m['y'], 4.0);
    final w = {'id': 'w1', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 10, 'y2': 0, 'thickness': 0.2};
    moveElement(w, 0, 2);
    expect(w['y1'], 2.0);
    expect(snap(1.26, 0.5), 1.5);
  });

  test('calibration : 2 points + distance réelle', () {
    expect(calibrationScale((0, 0), (300, 400), 10), closeTo(0.02, 1e-12));
    expect(() => calibrationScale((1, 1), (1, 1), 5), throwsArgumentError);
  });

  test('association : chaque station sur une machine de son type, distances en équerre', () {
    final p = planFor(twin);
    final lay = planLayout(twin['stations'] as List, p);
    final asg = lay['assignment'] as Map;
    expect(asg.length, (twin['stations'] as List).length);
    expect(lay['virtual'], isEmpty);
    expect((lay['notes'] as List).join(), contains('famille voisine')); // presse_vapeur → machine de repassage
    final ids = stationOrder(twin);
    final d = (lay['distances'] as Map)['${ids[0]}-${ids[1]}'] as double;
    expect(d, greaterThan(0));
    // le jumeau simule sur l'implantation du plan
    final res = simulateLineDay(twin, lay, const LineDayConfig(variability: 0));
    expect(res['pieces'], greaterThan(250));
    expect(res['transport_m'], greaterThan(0));
  });

  test('liaison manuelle machine ↔ station (ws_id) prioritaire, stations sans machine = virtuelles', () {
    final p = newWorkshopPlan(id: 'p2');
    (p['elements'] as List).add({...newMachine('mx', 'piqueuse_plate', 10, 10), 'ws_id': '${stationOrder(twin).last}'});
    final lay = planLayout(twin['stations'] as List, p);
    expect((lay['assignment'] as Map)['${stationOrder(twin).last}'], ['mx']);
    expect((lay['virtual'] as List).length, (twin['stations'] as List).length - 1);
    expect(((lay['positions'] as Map)['${stationOrder(twin).last}'] as Map)['x'], 10.0);
  });

  test('corps API (WorkshopPlanIn) : champs locaux retirés, identifiants uniques', () {
    final p = planFor(twin)..['background_local'] = {'data': 'xx', 'm_per_px': 0.01};
    final body = planApiBody(p);
    expect(body.keys.toSet(), {'name', 'version', 'width_m', 'length_m', 'elements', 'settings'});
    final ids = [for (final e in body['elements'] as List) (e as Map)['id']];
    expect(ids.toSet().length, ids.length);
    expect(inventoryWorkstations(p).length, planMachines(p).length);
  });
}
