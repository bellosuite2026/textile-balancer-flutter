/// Process Flow (local, hors ligne) : graphe des précédences de la gamme, disposé par niveaux
/// (plus long chemin). Nœuds = opérations (code, libellé, SAM, machine), flèches = précédences,
/// zoom / déplacement, couleur par station quand il est ouvert depuis un résultat, station goulot
/// mise en évidence, chemin critique, export PNG.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/file_io.dart';
import '../../engine/flow.dart';
import '../../engine/models.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

const _nodeW = 176.0, _nodeH = 78.0, _colW = 232.0, _rowH = 100.0, _pad = 28.0;

/// Couleurs des stations (cycle).
const stationPalette = [
  Color(0xFF3B82F6),
  Color(0xFF22A06B),
  Color(0xFFEA580C),
  Color(0xFF8B5CF6),
  Color(0xFF0EA5E9),
  Color(0xFFD946EF),
  Color(0xFF84CC16),
  Color(0xFFF59E0B),
  Color(0xFF14B8A6),
  Color(0xFF6366F1),
];
Color stationColor(int station) => stationPalette[(station - 1).abs() % stationPalette.length];

Offset flowNodeOrigin(FlowNode n) => Offset(_pad + n.level * _colW, _pad + n.row * _rowH);
Size flowCanvasSize(FlowGraph g) =>
    Size(_pad * 2 + math.max(0, g.levels - 1) * _colW + _nodeW, _pad * 2 + math.max(0, g.maxRows - 1) * _rowH + _nodeH);

/// Écran ouvert depuis l'Analyse ou un résultat : retrouve le calcul localement.
class ProcessFlowScreen extends StatelessWidget {
  const ProcessFlowScreen({super.key, required this.runId});
  final String runId;

  @override
  Widget build(BuildContext context) {
    final r = context.read<AppState>().repo.run(runId);
    if (r == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Process Flow')),
        body: const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable.'),
      );
    }
    return ProcessFlowView(problem: r.problem, result: r.balance);
  }
}

class ProcessFlowView extends StatefulWidget {
  const ProcessFlowView({super.key, required this.problem, this.result});
  final Problem problem;
  final BalanceResult? result;

  @override
  State<ProcessFlowView> createState() => _ProcessFlowViewState();
}

class _ProcessFlowViewState extends State<ProcessFlowView> {
  late final FlowGraph _g = FlowGraph.build(widget.problem.operations);
  final _tc = TransformationController();
  final _boundary = GlobalKey();
  bool _byStation = true;
  bool _critical = true;
  String? _sel;
  Size? _viewport;
  bool _fitted = false;

  Map<String, int> get _stations => widget.result?.operationAssignments ?? const {};
  int? get _goulot => widget.result?.bottleneck?.station;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _fit() {
    final v = _viewport;
    if (v == null) return;
    final c = flowCanvasSize(_g);
    final s = math.min(1.2, math.min(v.width / c.width, v.height / c.height)).clamp(0.2, 1.2).toDouble();
    final dx = (v.width - c.width * s) / 2, dy = (v.height - c.height * s) / 2;
    _tc.value = Matrix4.identity()
      ..translateByDouble(math.max(0, dx), math.max(0, dy), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  void _zoom(double f) {
    final v = _viewport ?? const Size(400, 400);
    final c = Offset(v.width / 2, v.height / 2);
    _tc.value = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1)
      ..multiply(_tc.value);
  }

  void _tap(Offset p) {
    for (final n in _g.nodes) {
      if ((flowNodeOrigin(n) & const Size(_nodeW, _nodeH)).contains(p)) {
        setState(() => _sel = _sel == n.id ? null : n.id);
        return;
      }
    }
    setState(() => _sel = null);
  }

  Future<void> _export() async {
    try {
      final b = _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (b == null) return;
      final img = await b.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final name = widget.problem.name.isEmpty ? 'gamme' : widget.problem.name.replaceAll(RegExp(r'[^\w\-]+'), '_');
      final msg = await saveBytes('process_flow_$name.png', data.buffer.asUint8List(), mime: 'image/png');
      if (mounted && msg != null) showSnack(context, msg);
    } catch (e) {
      if (mounted) showSnack(context, 'Export PNG impossible : $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _g;
    final hasResult = widget.result != null && _stations.isNotEmpty;
    final sel = _sel == null ? null : g.node(_sel!);
    final size = flowCanvasSize(g);
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.desktop;
    final details = sel == null ? null : _details(sel);
    return Scaffold(
      appBar: AppBar(
        title: Text('Process Flow${widget.problem.name.isEmpty ? '' : ' — ${widget.problem.name}'}', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(key: const Key('flow-export'), tooltip: 'Exporter en PNG', onPressed: _export, icon: const Icon(Icons.image_outlined)),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusBadge('${g.nodes.length} opérations', color: Brand.navy, icon: Icons.account_tree_outlined),
                StatusBadge('${g.edges.length} précédences', color: Brand.muted),
                StatusBadge('${g.levels} niveaux', color: Brand.muted),
                StatusBadge('Chemin critique ${fmtMin(g.criticalMinutes, 2)}', color: Brand.orange, icon: Icons.route),
                if (hasResult && _goulot != null) StatusBadge('Goulot : station $_goulot', color: Brand.danger, icon: Icons.warning_amber),
                FilterChip(
                  key: const Key('flow-critical'),
                  label: const Text('Chemin critique'),
                  selected: _critical,
                  onSelected: (v) => setState(() => _critical = v),
                ),
                if (hasResult)
                  FilterChip(
                    key: const Key('flow-by-station'),
                    label: const Text('Couleurs par station'),
                    selected: _byStation,
                    onSelected: (v) => setState(() => _byStation = v),
                  ),
              ],
            ),
          ),
          if (g.cycle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Notice('Précédences circulaires : ${g.cycle.join(', ')}. Corrigez la gamme.', kind: 'error'),
            ),
          if (g.unknownPredecessors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Notice(
                'Précédences vers des opérations absentes ignorées : ${g.unknownPredecessors.take(6).map((e) => '${e.$1} ← ${e.$2}').join(', ')}.',
                kind: 'warn',
              ),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: g.nodes.isEmpty
                      ? const EmptyState(icon: Icons.account_tree_outlined, text: 'Aucune opération dans la gamme.')
                      : LayoutBuilder(
                          builder: (context, c) {
                            _viewport = Size(c.maxWidth, c.maxHeight);
                            if (!_fitted) {
                              _fitted = true;
                              WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
                            }
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: const Color(0xFFF8FAFC),
                                    child: InteractiveViewer(
                                      key: const Key('flow-viewer'),
                                      transformationController: _tc,
                                      constrained: false,
                                      minScale: 0.15,
                                      maxScale: 3,
                                      boundaryMargin: const EdgeInsets.all(400),
                                      child: GestureDetector(
                                        onTapUp: (d) => _tap(d.localPosition),
                                        child: RepaintBoundary(
                                          key: _boundary,
                                          child: CustomPaint(
                                            key: const Key('flow-canvas'),
                                            size: size,
                                            painter: FlowPainter(
                                              graph: g,
                                              stations: hasResult && _byStation ? _stations : const {},
                                              goulot: hasResult ? _goulot : null,
                                              critical: _critical,
                                              selected: _sel,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Card(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          key: const Key('flow-zoom-in'),
                                          tooltip: 'Zoom +',
                                          onPressed: () => _zoom(1.25),
                                          icon: const Icon(Icons.add),
                                        ),
                                        IconButton(
                                          key: const Key('flow-zoom-out'),
                                          tooltip: 'Zoom −',
                                          onPressed: () => _zoom(0.8),
                                          icon: const Icon(Icons.remove),
                                        ),
                                        IconButton(
                                          key: const Key('flow-fit'),
                                          tooltip: 'Ajuster',
                                          onPressed: _fit,
                                          icon: const Icon(Icons.fit_screen_outlined),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (hasResult && _byStation) Positioned(left: 8, bottom: 8, child: _legend()),
                              ],
                            );
                          },
                        ),
                ),
                if (wide && details != null)
                  SizedBox(
                    width: 320,
                    child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: details),
                  ),
              ],
            ),
          ),
          if (!wide && details != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.32),
              child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: details),
            ),
        ],
      ),
    );
  }

  Widget _legend() {
    final st = (_stations.values.toSet().toList()..sort());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in st.take(20))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: stationColor(s),
                        borderRadius: BorderRadius.circular(3),
                        border: s == _goulot ? Border.all(color: Brand.danger, width: 2) : null,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Text('S$s', style: TextStyle(fontSize: 11, fontWeight: s == _goulot ? FontWeight.w800 : FontWeight.w500)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(FlowNode n) {
    final o = n.op;
    final st = _stations[o.id];
    final sd = st == null ? null : widget.result?.stationDetails.where((s) => s.station == st).firstOrNull;
    return SectionCard(
      key: const Key('flow-details'),
      title: '${o.id} — ${o.name.isEmpty ? 'Opération' : o.name}',
      trailing: IconButton(onPressed: () => setState(() => _sel = null), icon: const Icon(Icons.close)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SAM : ${fmtMin(o.duration, 3)}'),
          if (o.machineType.isNotEmpty) Text('Machine : ${o.machineType}'),
          if (o.section.isNotEmpty) Text('Section : ${o.section}'),
          Text('Niveau : ${n.level + 1}'),
          Text('Précédents : ${_g.predecessorsOf(o.id).join(', ').ifEmpty('aucun (début)')}'),
          Text('Suivants : ${_g.successorsOf(o.id).join(', ').ifEmpty('aucun (fin)')}'),
          if (_g.critical.contains(o.id))
            const Text(
              'Sur le chemin critique',
              style: TextStyle(color: Brand.orange, fontWeight: FontWeight.w600),
            ),
          if (st != null)
            Text(
              'Station $st${sd == null ? '' : ' · charge ${fmtMin(sd.totalTime, 2)} (${fmtNum(sd.loadPct, 0)} %)'}'
              '${st == _goulot ? ' · goulot' : ''}',
              style: TextStyle(color: st == _goulot ? Brand.danger : Brand.navy, fontWeight: FontWeight.w600),
            ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String v) => isEmpty ? v : this;
}

class FlowPainter extends CustomPainter {
  FlowPainter({required this.graph, required this.stations, this.goulot, required this.critical, this.selected});
  final FlowGraph graph;
  final Map<String, int> stations;
  final int? goulot;
  final bool critical;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final crit = critical ? graph.criticalEdges : const <(String, String)>{};
    final critNodes = critical ? graph.critical.toSet() : const <String>{};
    final pos = {for (final n in graph.nodes) n.id: flowNodeOrigin(n)};
    final related = selected == null ? const <String>{} : {...graph.predecessorsOf(selected!), ...graph.successorsOf(selected!)};
    // arcs
    for (final e in graph.edges) {
      final a = pos[e.$1]!, b = pos[e.$2]!;
      final onCrit = crit.contains(e);
      final hl = selected != null && (e.$1 == selected || e.$2 == selected);
      final p0 = a + const Offset(_nodeW, _nodeH / 2), p1 = b + const Offset(0, _nodeH / 2);
      final dx = math.max(30.0, (p1.dx - p0.dx) / 2);
      final path = Path()
        ..moveTo(p0.dx, p0.dy)
        ..cubicTo(p0.dx + dx, p0.dy, p1.dx - dx, p1.dy, p1.dx - 6, p1.dy);
      final color = hl ? Brand.navy : (onCrit ? Brand.orange : const Color(0xFF9AA5B4));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = onCrit || hl ? 2.6 : 1.3
          ..color = color,
      );
      final head = Path()
        ..moveTo(p1.dx, p1.dy)
        ..lineTo(p1.dx - 9, p1.dy - 5)
        ..lineTo(p1.dx - 9, p1.dy + 5)
        ..close();
      canvas.drawPath(head, Paint()..color = color);
    }
    // nœuds
    for (final n in graph.nodes) {
      final o = pos[n.id]!;
      final r = RRect.fromRectAndRadius(o & const Size(_nodeW, _nodeH), const Radius.circular(10));
      final st = stations[n.id];
      final base = st == null ? Brand.navy : stationColor(st);
      final isGoulot = st != null && st == goulot;
      final dim = selected != null && selected != n.id && !related.contains(n.id);
      canvas.drawRRect(r.shift(const Offset(0, 2)), Paint()..color = const Color(0x14000000));
      canvas.drawRRect(r, Paint()..color = Color.lerp(Colors.white, base, st == null ? 0.04 : 0.14)!.withValues(alpha: dim ? 0.55 : 1));
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(o.dx, o.dy, 6, _nodeH),
          topLeft: const Radius.circular(10),
          bottomLeft: const Radius.circular(10),
        ),
        Paint()..color = base,
      );
      canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = n.id == selected ? 3 : (isGoulot ? 2.6 : (critNodes.contains(n.id) ? 2 : 1))
          ..color = n.id == selected
              ? Brand.navy
              : isGoulot
              ? Brand.danger
              : critNodes.contains(n.id)
              ? Brand.orange
              : const Color(0xFFD0D7E2),
      );
      _text(canvas, n.id, o + const Offset(14, 7), 12.5, FontWeight.w800, Brand.navy, _nodeW - 70);
      _text(canvas, fmtMin(n.op.duration, 3), o + const Offset(_nodeW - 66, 8), 11, FontWeight.w600, Brand.muted, 58, right: true);
      _text(
        canvas,
        n.op.name.isEmpty ? '—' : n.op.name,
        o + const Offset(14, 26),
        11.5,
        FontWeight.w500,
        const Color(0xFF1F2937),
        _nodeW - 22,
        lines: 2,
      );
      final foot = [if (n.op.machineType.isNotEmpty) n.op.machineType, if (st != null) 'S$st${isGoulot ? ' · goulot' : ''}'].join(' · ');
      if (foot.isNotEmpty) {
        _text(
          canvas,
          foot,
          o + const Offset(14, _nodeH - 19),
          10.5,
          isGoulot ? FontWeight.w700 : FontWeight.w500,
          isGoulot ? Brand.danger : (st == null ? Brand.muted : base),
          _nodeW - 22,
        );
      }
    }
  }

  void _text(Canvas c, String s, Offset at, double size, FontWeight w, Color color, double maxW, {int lines = 1, bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: size, fontWeight: w, color: color, height: 1.15),
      ),
      textDirection: TextDirection.ltr,
      maxLines: lines,
      ellipsis: '…',
      textAlign: right ? TextAlign.right : TextAlign.left,
    )..layout(maxWidth: maxW);
    tp.paint(c, right ? at + Offset(maxW - tp.width, 0) : at);
  }

  @override
  bool shouldRepaint(FlowPainter old) =>
      old.graph != graph || old.stations != stations || old.goulot != goulot || old.critical != critical || old.selected != selected;
}
