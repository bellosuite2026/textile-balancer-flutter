import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';
import 'package:textile_balancer_flutter/engine/scene3d.dart';
import 'package:textile_balancer_flutter/features/twin/scene3d_view.dart';
import 'package:vector_math/vector_math.dart' as vm;

Map<String, dynamic> _plan() {
  final p = newWorkshopPlan(id: 'p3d', width: 14, length: 8);
  final els = p['elements'] as List;
  els.addAll([
    {'id': 'w1', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 14, 'y2': 0, 'thickness': 0.2},
    {'id': 'w2', 'kind': 'wall', 'x1': 0, 'y1': 0, 'x2': 0, 'y2': 8, 'thickness': 0.2},
    {'id': 'z1', 'kind': 'zone', 'x': 1, 'y': 1, 'w': 12, 'h': 5, 'zone': 'montage', 'name': 'Montage'},
    {'id': 'a1', 'kind': 'aisle', 'x': 0, 'y': 6.5, 'w': 14, 'h': 1.2, 'main': true},
    {'id': 'p1', 'kind': 'pillar', 'x': 7, 'y': 7, 'w': 0.4, 'd': 0.4},
    newRail('r1', [(1, 2), (12, 2), (12, 5), (1, 5)]),
    for (var i = 0; i < 6; i++) newMachine('m$i', i.isEven ? 'piqueuse_plate' : 'surjeteuse_4_fils', 2.0 + i * 1.8, 3, label: 'M0$i'),
  ]);
  return p;
}

Twin3DInput _input({Map<String, dynamic>? plan}) => Twin3DInput(
      order: const [1, 2, 3],
      positions: const {
        '1': {'x': 2.0, 'y': 3.0},
        '2': {'x': 5.6, 'y': 3.0},
        '3': {'x': 9.2, 'y': 3.0},
      },
      bundles: const [
        BundleView(1, 10, 'queue', 2),
        BundleView(2, 10, 'queue', 2),
        BundleView(3, 10, 'work', 1, worker: 'W1', progress: 0.3),
        BundleView(4, 10, 'transit', 1, toStation: 2, progress: 0.5),
      ],
      workersByStation: const {1: ['W1'], 2: ['W2', 'W3'], 3: ['W4']},
      bottleneck: 2,
      plan: plan,
      assignment: plan == null ? const {} : const {'1': ['m0'], '2': ['m2'], '3': ['m4']},
    );

void main() {
  test('maillages : pavé = 12 triangles orientés vers l\'extérieur, cylindre, sphère', () {
    final m = Mesh3()..box(0, 0, 0, 1, 1, 1, 30, 0xFF0000FF);
    expect(m.length, 10); // posé au sol : pas de face de dessous
    for (final t in m.tris) {
      final n = (t.b - t.a).cross(t.c - t.a);
      final mid = (t.a + t.b + t.c) / 3;
      expect(n.dot(mid - vm.Vector3(0, 0.5, 0)), greaterThan(0));
    }
    expect((Mesh3()..cylinder(0, 0, 0, 0.2, 1, 0xFF000000, seg: 8)).length, 8 * 3);
    expect((Mesh3()..sphere(0, 1, 0, 0.2, 0xFF000000)).length, 32);
  });

  test('projection : faces arrière éliminées, tri du loin vers le proche, toucher', () {
    final m = Mesh3()..box(0, 0, 0, 2, 2, 2, 0, 0xFF3366CC, tag: 'cube');
    final cam = OrbitCamera(target: vm.Vector3(0, 1, 0), distance: 10, yaw: 0.4, pitch: 0.5);
    final pr = projectScene([m], cam, 400, 300);
    // au plus 3 faces visibles d'un cube = 6 triangles
    expect(pr.triangles, lessThanOrEqualTo(6));
    expect(pr.triangles, greaterThanOrEqualTo(4));
    expect(pr.positions.length, pr.triangles * 6);
    expect(pickTag(pr, 200, 150), 'cube');
    expect(pickTag(pr, 2, 2), isNull);
    final c = projectPoint(vm.Vector3(0, 1, 0), cam, 400, 300)!;
    expect(c.$1, closeTo(200, 0.5));
    expect(c.$2, closeTo(150, 0.5));
  });

  test('caméra : bornes d\'inclinaison et de zoom, cadrage', () {
    final cam = OrbitCamera(target: vm.Vector3.zero());
    cam.orbit(0, 10);
    expect(cam.pitch, lessThan(1.571));
    cam.orbit(0, -10);
    expect(cam.pitch, greaterThan(0.07));
    cam.zoom(1e-6);
    expect(cam.distance, 2);
    cam.frame(0, 0, 30, 20);
    expect(cam.target.x, 15);
    expect(cam.target.z, 10);
    expect(cam.distance, greaterThan(20));
  });

  test('plan en 3D : simple plus léger que détaillé ; goulot en rouge ; calques masqués', () {
    final p = _plan();
    final det = buildPlanScene(p, detailed: true);
    final simple = buildPlanScene(p, detailed: false);
    expect(det.length, greaterThan(simple.length));
    final hot = buildPlanScene(p, hotMachines: {'m2'});
    expect(hot.tris.any((t) => t.color == bottleneckColor && t.tag == 'm:m2'), isTrue);
    final noMachines = buildPlanScene(p, hiddenKinds: {'machine'});
    expect(noMachines.tris.any((t) => '${t.tag}'.startsWith('m:')), isFalse);
  });

  test('jumeau 3D : opératrices, encours, paquet en transit ; ~40 postes sous 10 000 triangles', () {
    final inp = _input();
    final st = buildTwinStatic(inp);
    final dyn = buildTwinDynamic(inp, t: 1);
    expect(st.tris.any((t) => t.color == bottleneckColor), isTrue);
    expect(dyn.tris.where((t) => t.color == bundleColor).length, greaterThanOrEqualTo(24)); // 2 paquets × 12
    // charge d'une ligne de 40 postes, style détaillé
    final big = Twin3DInput(
      order: [for (var i = 1; i <= 40; i++) i],
      positions: {for (var i = 1; i <= 40; i++) '$i': {'x': (i % 10) * 1.8, 'y': (i ~/ 10) * 3.0}},
      bundles: [for (var i = 1; i <= 40; i++) BundleView(i, 10, 'queue', i)],
      workersByStation: {for (var i = 1; i <= 40; i++) i: ['W$i']},
      bottleneck: 7,
    );
    final n = buildTwinStatic(big).length + buildTwinDynamic(big).length;
    expect(n, lessThan(10000));
    final sw = Stopwatch()..start();
    final cam = OrbitCamera(target: vm.Vector3(9, 0, 5), distance: 30);
    for (var k = 0; k < 10; k++) {
      projectScene([buildTwinStatic(big), buildTwinDynamic(big, t: k.toDouble())], cam, 1200, 700);
    }
    // indicatif (VM de test, sans JIT chaud) : on vérifie seulement l'ordre de grandeur
    expect(sw.elapsedMilliseconds / 10, lessThan(400));
  });

  testWidgets('Twin3DView se dessine, réagit au zoom et au recentrage', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(key: key, child: SizedBox(width: 1000, height: 600, child: Twin3DView(input: _input(plan: _plan()), time: 3, height: 600))),
      ),
    ));
    expect(find.byKey(const Key('scene3d-canvas')), findsOneWidget);
    await tester.tap(find.byKey(const Key('3d-zoom-in')));
    await tester.pump();
    await tester.drag(find.byKey(const Key('scene3d-canvas')), const Offset(80, 20));
    await tester.pump();
    await tester.tap(find.byKey(const Key('3d-reset')));
    await tester.pump();
    final out = Platform.environment['SCENE3D_PNG'];
    if (out != null) {
      await tester.runAsync(() async {
        final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await ro.toImage();
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        File(out).writeAsBytesSync(data!.buffer.asUint8List());
      });
    }
    expect(tester.takeException(), isNull);
  });
}
