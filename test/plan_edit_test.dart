import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';

Map<String, dynamic> _plan() {
  final p = newWorkshopPlan(id: 'p1', width: 20, length: 10);
  final els = p['elements'] as List;
  els.addAll([
    {'id': 'w1', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 20, 'y2': 0, 'thickness': 0.2},
    {'id': 'w2', 'kind': 'wall', 'x1': 10, 'y1': 0, 'x2': 10, 'y2': 8, 'thickness': 0.2},
    newMachine('m1', 'piqueuse_plate', 3, 3, label: 'M01'),
    newMachine('m2', 'piqueuse_plate', 16, 3, label: 'M02'),
    newMachine('m3', 'surjeteuse_4_fils', 6, 6, label: 'M07'),
  ]);
  return p;
}

int _seq = 0;
String _id() => 'n${_seq++}';

void main() {
  test('réglages : grid (web) ou grid_m (Flutter), aimantation', () {
    expect(PlanSettings.of({'settings': {'grid_m': 0.5}}).grid, 0.5);
    final st = PlanSettings.of({'settings': {'grid': 0.25, 'snap': false}});
    expect(st.grid, 0.25);
    expect(st.snapV(1.13), 1.13);
    expect(const PlanSettings(grid: 0.5).snapV(1.13), 1.0);
  });

  test('toucher : machine avant mur, cote, encadrement', () {
    final p = _plan();
    final els = planElements(p);
    expect(hitTest(els, 3.1, 3.1)?['id'], 'm1');
    expect(hitTest(els, 10.05, 5)?['id'], 'w2');
    expect(hitTest(els, 15, 9), isNull);
    els.add(newDim('d1', 'dist', [(1, 9), (5, 9)]));
    expect(hitTest(els, 3, 9.05)?['id'], 'd1');
    expect(dimText(els.last), '4,00 m');
    expect(idsInRect(els, (0, 1), (9, 8)), containsAll(['m1', 'm3']));
    expect(idsInRect(els, (0, 1), (9, 8)), isNot(contains('m2')));
    // calque masqué : plus touchable
    final layers = LayerState(hidden: {'machine'});
    expect(hitTest(els, 3.1, 3.1, visible: layers.visible), isNull);
  });

  test('aimantation de la mesure : coins de machine puis face de mur', () {
    final els = planElements(_plan());
    final s = snapMeasure(els, (2.45, 2.75), 0.3)!;
    expect(s.label, 'point');
    expect(s.p, (2.4, 2.7));
    final w = snapMeasure(els, (10.3, 5), 0.5)!;
    expect(w.label, 'mur');
    expect(w.p.$1, closeTo(10.1, 1e-9));
    expect(snapToWallEnds(els, (19.9, 0.1), const PlanSettings()), (20.0, 0.0));
  });

  test('cotes : chaîne et surface', () {
    expect(dimText(newDim('a', 'area', [(0, 0), (2, 3)])), '2,00 × 3,00 m = 6,0 m²');
    final c = newDim('c', 'chain', [(0, 0), (3, 0), (3, 4)]);
    expect(dimText(c), '7,00 m');
    expect(dimLabelAt(c), (3.0, 0.5));
  });

  test('chemin à pied : contourne le mur central', () {
    final p = _plan();
    final r = walkRoute(p, 'm1', 'm2')!;
    final direct = (16 - 3).toDouble();
    expect(r.length, greaterThan(direct));
    // passe sous l'extrémité du mur (y > 8)
    expect(r.pts.any((q) => q.$2 > 7.9), isTrue);
    expect(walkRoute(p, 'm1', 'nope'), isNull);
  });

  test('dupliquer, copier/coller, pivoter, aligner, répartir, supprimer', () {
    final els = planElements(_plan());
    final d = duplicateIds(els, ['m1'], _id);
    expect(d.single['label'], 'M08');
    expect(d.single['x'], closeTo(3 + 1.4, 1e-9));
    final pasted = pasteElements(els, [deepCopyEl(els.firstWhere((e) => e['id'] == 'm3'))], _id, offset: (1, 1));
    expect(pasted.single['label'], 'M09');
    expect(pasted.single['y'], 7.0);
    rotateIds(els, ['m1', 'w1'], 90);
    rotateIds(els, ['m1'], -105);
    expect(els.firstWhere((e) => e['id'] == 'm1')['rot'], 345);
    expect(els.firstWhere((e) => e['id'] == 'w1').containsKey('rot'), isFalse);
    expect(alignIds(els, ['m1', 'm3'], 'y'), isTrue);
    expect(els.firstWhere((e) => e['id'] == 'm3')['y'], 4.5);
    expect(distributeIds(els, ['m1', 'm2', 'm3'], 'x'), isTrue);
    expect(els.firstWhere((e) => e['id'] == 'm3')['x'], 9.5);
    removeIds(els, ['m1', 'm2']);
    expect(els.where((e) => e['kind'] == 'machine').length, 3);
  });

  test('poignées : redimensionner, pivoter (pas 15°), extrémité de mur, point de convoyeur', () {
    const st = PlanSettings(grid: 0.1);
    final m = newMachine('m', 'piqueuse_plate', 5, 5);
    final hs = handlesFor(m);
    expect(hs.map((h) => h.kind), [HandleKind.resize, HandleKind.rotate]);
    final orig = deepCopyEl(m);
    applyHandle(m, orig, hs[0], (5.8, 5.5), st);
    expect(m['w'], 1.6);
    expect(m['d'], 1.0);
    applyHandle(m, orig, hs[1], (6, 5), st);
    expect(m['rot'], 90);
    final w = {'id': 'w', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 4, 'y2': 0, 'thickness': 0.2};
    applyHandle(w, deepCopyEl(w), handlesFor(w)[1], (4, 3), st);
    expect(w['y2'], 3.0);
    final r = newRail('r', [(0, 0), (4, 0), (4, 2)]);
    expect(railLength(r), closeTo(4 + 2 + 4.4721, 1e-3));
    applyHandle(r, deepCopyEl(r), handlesFor(r)[2], (4, 3), st);
    expect(ptsOf(r)[2], (4.0, 3.0));
    moveEl(r, 1, 1);
    expect(ptsOf(r).first, (1.0, 1.0));
    expect(elementBounds(r), (1.0, 1.0, 5.0, 4.0));
  });

  test('porte dans l\'axe du mur le plus proche', () {
    final els = planElements(_plan());
    final a = nearestWallAngle(els, 10.3, 4)!;
    expect(a.angle, 90);
    expect(a.x, 10.0);
    expect(nearestWallAngle(els, 15, 5), isNull);
  });

  test('historique : 1 geste = 1 étape, annuler/rétablir', () {
    final p = _plan();
    final h = PlanHistory();
    h.push(PlanHistory.snapshot(p));
    removeIds((p['elements'] as List).cast<Map<String, dynamic>>(), ['m1']);
    expect(planMachines(p).length, 2);
    expect(h.undo(p), isTrue);
    expect(planMachines(p).length, 3);
    expect(h.canRedo, isTrue);
    expect(h.redo(p), isTrue);
    expect(planMachines(p).length, 2);
    expect(h.redo(p), isFalse);
    h.push(PlanHistory.snapshot(p));
    expect(h.canRedo, isFalse);
  });

  test('contrôles : chevauchement, allée étroite, issue manquante', () {
    final p = _plan();
    final els = p['elements'] as List;
    els.add(newMachine('mx', 'piqueuse_plate', 3.5, 3.1, label: 'M03'));
    els.add({'id': 'a', 'kind': 'aisle', 'x': 0, 'y': 9, 'w': 10, 'h': 0.6, 'main': true});
    final issues = checkPlan(p);
    expect(issues.any((i) => i.level == 'err' && i.ids.contains('mx')), isTrue);
    expect(issues.any((i) => i.msg.contains('Allée principale')), isTrue);
    expect(issues.any((i) => i.msg.contains('issue')), isTrue);
  });

  test('import DXF : LINE et LWPOLYLINE fermée, unité mm, y inversé', () {
    const dxf = '0\nSECTION\n2\nHEADER\n9\n\$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n'
        '0\nLINE\n8\nMURS\n10\n0\n20\n0\n11\n10000\n21\n0\n'
        '0\nLWPOLYLINE\n90\n4\n70\n1\n10\n0\n20\n0\n10\n2000\n20\n0\n10\n2000\n20\n5000\n10\n0\n20\n5000\n'
        '0\nENDSEC\n0\nEOF\n';
    final r = dxfToWalls(dxf, _id);
    expect(r.unit, 'mm');
    expect(r.walls.length, 5);
    expect(r.width, 11.0);
    expect(r.length, 6.0);
    final line = r.walls.first;
    expect([line['x1'], line['y1'], line['x2'], line['y2']], [0.5, 5.5, 10.5, 5.5]);
    expect(() => dxfToWalls('0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n', _id), throwsFormatException);
  });

  test('contrat API : calques et fond local non envoyés, cotes et convoyeurs envoyés', () {
    final p = _plan()
      ..['ui_layers'] = LayerState(hidden: {'dim'}).toJson()
      ..['background_local'] = {'data': 'xx', 'm_per_px': 0.01};
    (p['elements'] as List).add(newRail('r', [(1, 1), (5, 1), (5, 3)]));
    final body = planApiBody(p);
    expect(body.containsKey('ui_layers'), isFalse);
    expect(body.containsKey('background_local'), isFalse);
    expect((body['elements'] as List).any((e) => e['kind'] == 'rail'), isTrue);
    expect(LayerState.of(p).hidden, {'dim'});
  });
}
