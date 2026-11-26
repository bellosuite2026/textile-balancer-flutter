/// Vue 3D (rendu logiciel sur Canvas, voir `engine/scene3d.dart`) : caméra orbitale (glisser), déplacement
/// (clic droit / deux doigts / Maj+glisser), zoom (molette / pincement / boutons), vue de dessus, recentrage,
/// navigation clavier (flèches, + / −). Fonctionne à l'identique sur Web, Windows, Linux et Android.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../engine/scene3d.dart';
import '../../ui/theme.dart';

class Label3D {
  const Label3D(this.at, this.text, {this.color = Brand.navy, this.background = Colors.white});
  final vm.Vector3 at;
  final String text;
  final Color color;
  final Color background;
}

class Scene3DView extends StatefulWidget {
  const Scene3DView({
    super.key,
    required this.meshes,
    required this.bounds,
    this.labels = const [],
    this.onPick,
    this.height,
    this.overlay,
  });

  /// Maillages à dessiner (le parent garde en cache la partie statique).
  final List<Mesh3> meshes;

  /// Emprise au sol (x0, z0, x1, z1) en mètres, pour cadrer la caméra.
  final (double, double, double, double) bounds;
  final List<Label3D> labels;
  final ValueChanged<String>? onPick;
  final double? height;
  final Widget? overlay;

  @override
  State<Scene3DView> createState() => Scene3DViewState();
}

class Scene3DViewState extends State<Scene3DView> {
  late OrbitCamera cam;
  final _focus = FocusNode(debugLabel: 'scene3d');
  bool _panMode = false;
  double _lastScale = 1;
  Projected? _last;
  (double, double, double, double)? _framed;

  @override
  void initState() {
    super.initState();
    cam = OrbitCamera(target: vm.Vector3.zero());
    reset();
  }

  @override
  void didUpdateWidget(covariant Scene3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bounds != _framed) reset(keepAngles: true);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void reset({bool keepAngles = false}) {
    final (x0, z0, x1, z1) = widget.bounds;
    if (!keepAngles) {
      cam.yaw = -0.55;
      cam.pitch = 0.72;
    }
    cam.frame(x0, z0, x1, z1);
    _framed = widget.bounds;
  }

  void topView() => setState(() {
        cam.yaw = 0;
        cam.pitch = math.pi / 2 - 0.03;
      });

  double get _mPerPx => cam.distance / 700;

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final step = 0.6 * cam.distance / 20;
    void go(double dx, double dz) {
      final right = vm.Vector3(math.cos(cam.yaw), 0, -math.sin(cam.yaw));
      final fwd = vm.Vector3(-math.sin(cam.yaw), 0, -math.cos(cam.yaw));
      setState(() => cam.target += right * dx + fwd * dz);
    }

    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      go(0, step);
    } else if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyS) {
      go(0, -step);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      go(-step, 0);
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      go(step, 0);
    } else if (k == LogicalKeyboardKey.keyQ) {
      setState(() => cam.orbit(-0.08, 0));
    } else if (k == LogicalKeyboardKey.keyE) {
      setState(() => cam.orbit(0.08, 0));
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd) {
      setState(() => cam.zoom(0.85));
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      setState(() => cam.zoom(1.18));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final body = LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height ?? c.maxHeight);
      return Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: (e) {
            _focus.requestFocus();
            _panMode = (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0 || HardwareKeyboard.instance.isShiftPressed;
          },
          onPointerMove: (e) {
            // clic droit / milieu : le reconnaisseur d'échelle ne suit que le bouton principal
            if ((e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
              setState(() => cam.pan(e.delta.dx, e.delta.dy, _mPerPx));
            }
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) setState(() => cam.zoom(e.scrollDelta.dy > 0 ? 1.12 : 0.89));
          },
          child: GestureDetector(
            onScaleStart: (_) => _lastScale = 1,
            onScaleUpdate: (d) => setState(() {
              if (d.pointerCount >= 2) {
                cam.pan(d.focalPointDelta.dx, d.focalPointDelta.dy, _mPerPx);
                if (d.scale > 0) cam.zoom(_lastScale / d.scale);
                _lastScale = d.scale;
              } else if (_panMode) {
                cam.pan(d.focalPointDelta.dx, d.focalPointDelta.dy, _mPerPx);
              } else {
                cam.orbit(-d.focalPointDelta.dx * 0.008, d.focalPointDelta.dy * 0.006);
              }
            }),
            onTapUp: widget.onPick == null
                ? null
                : (d) {
                    final pr = _last;
                    if (pr == null) return;
                    final tag = pickTag(pr, d.localPosition.dx, d.localPosition.dy);
                    if (tag != null) widget.onPick!(tag);
                  },
            child: ClipRect(
              child: CustomPaint(
                key: const Key('scene3d-canvas'),
                size: size,
                painter: _Scene3DPainter(widget.meshes, cam.copy(), widget.labels, (p) => _last = p),
              ),
            ),
          ),
        ),
      );
    });
    return Stack(children: [
      Positioned.fill(child: body),
      Positioned(
        right: 6,
        top: 6,
        child: Material(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(key: const Key('3d-zoom-in'), tooltip: 'Zoom +', visualDensity: VisualDensity.compact, onPressed: () => setState(() => cam.zoom(0.8)), icon: const Icon(Icons.add)),
            IconButton(tooltip: 'Zoom −', visualDensity: VisualDensity.compact, onPressed: () => setState(() => cam.zoom(1.25)), icon: const Icon(Icons.remove)),
            IconButton(tooltip: 'Vue de dessus', visualDensity: VisualDensity.compact, onPressed: topView, icon: const Icon(Icons.vertical_align_bottom)),
            IconButton(
                key: const Key('3d-reset'),
                tooltip: 'Recentrer',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(reset),
                icon: const Icon(Icons.center_focus_strong)),
          ]),
        ),
      ),
      if (widget.overlay != null) Positioned(left: 6, top: 6, child: widget.overlay!),
      const Positioned(
        left: 8,
        bottom: 6,
        child: IgnorePointer(
          child: Text('Glisser : tourner · clic droit / 2 doigts / Maj : déplacer · molette / pincer : zoom · flèches, Q/E, +/−',
              style: TextStyle(fontSize: 10, color: Brand.muted)),
        ),
      ),
    ]);
  }
}

class _Scene3DPainter extends CustomPainter {
  _Scene3DPainter(this.meshes, this.cam, this.labels, this.onProjected);
  final List<Mesh3> meshes;
  final OrbitCamera cam;
  final List<Label3D> labels;
  final void Function(Projected) onProjected;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), const [Color(0xFFDDE6F0), Color(0xFFF7F8FA)]));
    if (size.isEmpty) return;
    final pr = projectScene(meshes, cam, size.width, size.height);
    onProjected(pr);
    if (pr.triangles > 0) {
      final v = ui.Vertices.raw(VertexMode.triangles, pr.positions, colors: pr.colors);
      canvas.drawVertices(v, BlendMode.dst, Paint());
    }
    for (final l in labels) {
      final p = projectPoint(l.at, cam, size.width, size.height);
      if (p == null || p.$1 < -40 || p.$2 < -20 || p.$1 > size.width + 40 || p.$2 > size.height + 20) continue;
      final tp = TextPainter(
        text: TextSpan(text: l.text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: l.color)),
        textDirection: TextDirection.ltr,
      )..layout();
      final r = Rect.fromCenter(center: Offset(p.$1, p.$2), width: tp.width + 8, height: tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()..color = l.background.withValues(alpha: 0.85));
      tp.paint(canvas, r.topLeft + const Offset(4, 1));
    }
  }

  @override
  bool shouldRepaint(covariant _Scene3DPainter old) => true;
}

/// Jumeau 3D : décor (plan ou postes) en cache, opératrices et paquets recalculés à chaque image.
class Twin3DView extends StatefulWidget {
  const Twin3DView({super.key, required this.input, required this.time, this.detailed = true, this.onPickStation, this.height});
  final Twin3DInput input;
  final double time; // minutes simulées (anime les bras)
  final bool detailed;
  final ValueChanged<int>? onPickStation;
  final double? height;

  @override
  State<Twin3DView> createState() => _Twin3DViewState();
}

class _Twin3DViewState extends State<Twin3DView> {
  Mesh3? _static;
  Object? _key;

  @override
  Widget build(BuildContext context) {
    final inp = widget.input;
    final key = (identityHashCode(inp.plan), inp.order.join(','), inp.positions.toString(), inp.bottleneck, widget.detailed,
        inp.assignment.toString());
    if (_static == null || key != _key) {
      _static = buildTwinStatic(inp, detailed: widget.detailed);
      _key = key;
    }
    final dyn = buildTwinDynamic(inp, detailed: widget.detailed, t: widget.time);
    final labels = <Label3D>[
      for (final sid in inp.order)
        Label3D(vm.Vector3(inp.pos(sid).$1, 1.75, inp.pos(sid).$2), 'S$sid',
            color: sid == inp.bottleneck ? Colors.white : Brand.navy,
            background: sid == inp.bottleneck ? Brand.danger : Colors.white),
    ];
    return Scene3DView(
      meshes: [_static!, dyn],
      bounds: inp.bounds(),
      labels: labels,
      height: widget.height,
      onPick: widget.onPickStation == null
          ? null
          : (tag) {
              if (tag.startsWith('s:')) {
                final s = int.tryParse(tag.substring(2));
                if (s != null) widget.onPickStation!(s);
              } else if (tag.startsWith('m:')) {
                final mid = tag.substring(2);
                for (final e in inp.assignment.entries) {
                  if (e.value.contains(mid)) widget.onPickStation!(int.tryParse(e.key) ?? -1);
                }
              }
            },
    );
  }
}
