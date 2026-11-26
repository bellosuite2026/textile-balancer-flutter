/// Plan d'atelier : liste des plans et éditeur, parité avec l'éditeur web `/atelier/plan` :
/// outils Sélection (multi, encadrement, poignées taille/rotation), Main, Gomme, Mesure (distance, chaîne,
/// surface, chemin à pied) et cotes, murs aimantés, poteaux, portes dans l'axe du mur, allées, zones,
/// machines (bibliothèque, glisser-déposer), convoyeurs suspendus ; annuler/rétablir, copier/coller,
/// dupliquer, pivoter, aligner/répartir, calques (visibilité, verrouillage), aimantation à la grille,
/// contrôles ; import PNG/JPG/PDF (calibré 2 points) et DXF ; vue 3D ; raccourcis clavier sur ordinateur.
///
/// Enregistré sur l'appareil ; en ligne (mode cloud), synchronisé avec `/workshop-plans`
/// (le fond d'image reste local : le serveur range les fonds dans Supabase Storage).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../core/format.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../engine/scene3d.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../twin/scene3d_view.dart';
import 'plan_painting.dart';

double _n(Object? v, [double d = 0]) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? d);

// =============================================================================== liste
class WorkshopPlansScreen extends StatelessWidget {
  const WorkshopPlansScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final s = context.read<AppState>();
    final name = await promptText(context, 'Nouveau plan', label: 'Nom du plan', initial: "Plan de l'atelier");
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final plan = newWorkshopPlan(id: 'plan-${uuid4()}', name: name.trim());
    final err = await s.savePlan(plan);
    if (!context.mounted) return;
    if (err != null) showSnack(context, 'Plan enregistré sur l\'appareil (serveur : $err)');
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlanEditorScreen(planId: '${plan['id']}')));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final plans = s.workshopPlans;
    return Scaffold(
      appBar: AppBar(title: const Text("Plan d'atelier")),
      body: PageScaffold(
        title: "Plans d'atelier",
        subtitle: 'Disposition des postes et des machines ; le jumeau numérique place la ligne sur le plan.',
        actions: [
          if (s.cloudAvailable)
            OutlinedButton.icon(
              onPressed: () async {
                final n = await s.pullPlans();
                if (context.mounted) showSnack(context, n == 0 ? 'Plans à jour.' : '$n plan(s) récupéré(s) du serveur.');
              },
              icon: const Icon(Icons.sync),
              label: const Text('Synchroniser'),
            ),
          FilledButton.icon(key: const Key('plan-new'), onPressed: () => _create(context), icon: const Icon(Icons.add), label: const Text('Nouveau plan')),
        ],
        children: [
          if (plans.isEmpty)
            const EmptyState(icon: Icons.map_outlined, text: "Aucun plan d'atelier sur cet appareil.")
          else
            Card(
              child: Column(children: [
                for (final p in plans)
                  ListTile(
                    leading: const Icon(Icons.map_outlined, color: Brand.navy),
                    title: Text('${p['name']}'),
                    subtitle: Text('${fmtNum(_n(p['width_m']), 1)} × ${fmtNum(_n(p['length_m']), 1)} m · '
                        '${planMachines(p).length} machine(s) · '
                        '${p['cloud_id'] == null ? 'sur l\'appareil' : (p['dirty'] == true ? 'à synchroniser' : 'synchronisé')}'),
                    trailing: IconButton(
                      tooltip: 'Supprimer',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (await confirm(context, 'Supprimer le plan ?', '« ${p['name']} » sera supprimé.', ok: 'Supprimer')) {
                          await s.deletePlan(p);
                        }
                      },
                    ),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlanEditorScreen(planId: '${p['id']}'))),
                  ),
              ]),
            ),
        ],
      ),
    );
  }
}

// =============================================================================== éditeur
enum PlanTool { select, pan, erase, measure, wall, pillar, door, aisle, zone, machine, rail, calibrate, background }

/// Outils, libellés, icônes, raccourci clavier et aide (parité avec l'éditeur web).
const toolInfo = <PlanTool, (String, IconData, String?, String)>{
  PlanTool.select: ('Sélection', Icons.near_me_outlined, 'V',
      'Touchez un élément pour le choisir · Maj/Ctrl+clic ou « sélection multiple » pour en ajouter · glissez dans le vide pour encadrer · glissez la sélection pour la déplacer · poignées : taille ■ et rotation ●.'),
  PlanTool.pan: ('Main', Icons.pan_tool_outlined, 'H', 'Glissez pour vous déplacer (ou deux doigts, clic droit) ; molette ou pincement pour zoomer.'),
  PlanTool.erase: ('Gomme', Icons.auto_fix_normal_outlined, 'E', 'Touchez un élément pour le supprimer, ou glissez sur plusieurs. Ctrl+Z pour annuler.'),
  PlanTool.measure: ('Mesure', Icons.straighten, 'M', 'Touchez deux points (aimantés sur les coins et centres des machines, les murs…). Alt : sans aimantation.'),
  PlanTool.wall: ('Mur', Icons.horizontal_rule, null, "Glissez d'un point à l'autre (aimanté aux extrémités voisines ; Maj : horizontal / vertical)."),
  PlanTool.pillar: ('Poteau', Icons.crop_square, null, 'Touchez pour poser un poteau.'),
  PlanTool.door: ('Porte / issue', Icons.door_front_door_outlined, null, "Touchez près d'un mur : la porte se met dans l'axe du mur."),
  PlanTool.aisle: ('Allée', Icons.signpost_outlined, null, 'Glissez pour tracer une allée de circulation (rectangle).'),
  PlanTool.zone: ('Zone', Icons.dashboard_outlined, null, 'Glissez pour tracer une zone (coupe, montage…).'),
  PlanTool.machine: ('Machine', Icons.precision_manufacturing_outlined, null,
      'Choisissez une machine dans la bibliothèque puis touchez le plan pour la poser (ou glissez-la depuis la liste).'),
  PlanTool.rail: ('Convoyeur', Icons.linear_scale, null,
      'Convoyeur suspendu : touchez les angles de la boucle un par un ; touchez le 1er point, double-touchez ou Entrée pour la fermer.'),
  PlanTool.calibrate: ('Calibrer', Icons.square_foot, null, 'Touchez deux points du fond de plan dont vous connaissez la distance réelle.'),
  PlanTool.background: ('Déplacer le fond', Icons.wallpaper_outlined, null, 'Glissez pour caler le fond de plan sur la salle.'),
};

const _measureModes = <String, (String, String)>{
  'dist': ('Distance', 'Touchez deux points.'),
  'chain': ('Chaîne', 'Touchez les points un par un ; double-touchez, Entrée ou « Terminer » pour finir.'),
  'area': ('Surface', 'Touchez deux coins opposés du rectangle (ou glissez).'),
  'walk': ('Chemin à pied', 'Touchez une machine puis une autre : plus court chemin à pied autour des murs, poteaux et machines.'),
};

enum _Drag { none, pan, move, handle, erase, draw, marquee, bg, measure, tap, pinch }

class PlanEditorScreen extends StatefulWidget {
  const PlanEditorScreen({super.key, required this.planId});
  final String planId;

  @override
  State<PlanEditorScreen> createState() => PlanEditorScreenState();
}

class PlanEditorScreenState extends State<PlanEditorScreen> {
  Map<String, dynamic>? _plan;
  PlanTool _tool = PlanTool.select;
  String _machineType = 'piqueuse_plate';
  String _zoneType = 'montage';
  List<String> _sel = [];
  bool _multi = false;
  bool _dirty = false;
  bool _saving = false;
  bool _view3d = false;
  bool _detailed3d = true;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  final history = PlanHistory();
  List<Map<String, dynamic>> _clipboard = [];
  int _pasteCount = 0;
  late LayerState _layers;
  final _focus = FocusNode(debugLabel: 'plan-canvas');
  Size _size = Size.zero;

  // geste en cours
  _Drag _mode = _Drag.none;
  Offset _downPx = Offset.zero;
  P _downM = (0, 0);
  P _curM = (0, 0);
  bool _moved = false;
  String? _before;
  bool _changed = false;
  PlanHandle? _handle;
  Map<String, dynamic>? _handleOrig;
  Map<String, Map<String, dynamic>> _origs = {};
  Map? _bgOrig;
  final _pointers = <int, Offset>{};
  double _pinchDist = 0;
  Offset _pinchMid = Offset.zero;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPx = Offset.zero;
  String? _hover;
  (P, P)? _marquee;

  // mesure
  String _mMode = 'dist';
  final _mPts = <P>[];
  Map<String, dynamic>? _mDone;
  ({P p, bool snapped})? _mCursor;
  String? _walkA;
  bool _keepDim = false;
  String? _msg;

  // convoyeur, fond, calibrage
  final _railPts = <P>[];
  ui.Image? _bg;
  final _calib = <P>[];
  final _calibCtl = TextEditingController();

  // calcul lié (stations)
  String? _runId;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final p = s.repo.plan(widget.planId);
    if (p != null) _plan = _deepCopy(p);
    _layers = _plan == null ? LayerState() : LayerState.of(_plan!);
    final runs = _runs(s);
    _runId = (_plan?['settings'] as Map?)?['run_id'] as String?;
    if (_runId != null && !runs.any((r) => r.id == _runId)) _runId = null;
    _runId ??= runs.isEmpty ? null : runs.first.id;
    _decodeBackground();
  }

  @override
  void dispose() {
    _focus.dispose();
    _calibCtl.dispose();
    super.dispose();
  }

  /// Plan en cours d'édition et repère écran (tests).
  @visibleForTesting
  Map<String, dynamic>? get plan => _plan;
  @visibleForTesting
  Offset debugToPx(double x, double y) => _view(_size).toPx(x, y);

  Map<String, dynamic> _deepCopy(Map m) => (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

  List<RunRecord> _runs(AppState s) => s.runs.where((r) => r.isDone && (r.balance?.stationDetails.isNotEmpty ?? false)).toList();

  Future<void> _decodeBackground() async {
    final bg = _plan?['background_local'] as Map?;
    if (bg == null || bg['data'] == null) return;
    try {
      final codec = await ui.instantiateImageCodec(base64Decode('${bg['data']}'));
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _bg = frame.image);
    } catch (_) {
      // image illisible : ignorée
    }
  }

  List<Map<String, dynamic>> get _els {
    final l = _plan!['elements'] as List;
    if (l is! List<Map<String, dynamic>>) {
      _plan!['elements'] = [for (final e in l) (e as Map).cast<String, dynamic>()];
    }
    return _plan!['elements'] as List<Map<String, dynamic>>;
  }

  Map<String, dynamic>? _el(String? id) => id == null ? null : _els.where((e) => e['id'] == id).firstOrNull;
  Map<String, dynamic>? get _single => _sel.length == 1 ? _el(_sel.first) : null;
  List<Map<String, dynamic>> get _selEls => [for (final e in _els) if (_sel.contains(e['id'])) e];

  PlanSettings get _st => PlanSettings.of(_plan!);
  Map<String, dynamic> get _settings => (_plan!['settings'] ??= <String, dynamic>{}) as Map<String, dynamic>;

  String _newId() => uuid4().substring(0, 12);

  /// Une modification = une étape d'historique.
  void edit(void Function() f) {
    final before = PlanHistory.snapshot(_plan!);
    f();
    if (PlanHistory.snapshot(_plan!) != before) {
      history.push(before);
      _dirty = true;
    }
    setState(() {});
  }

  void undo() {
    if (history.undo(_plan!)) {
      _sel = _sel.where((id) => _el(id) != null).toList();
      _dirty = true;
      setState(() {});
    }
  }

  void redo() {
    if (history.redo(_plan!)) {
      _sel = _sel.where((id) => _el(id) != null).toList();
      _dirty = true;
      setState(() {});
    }
  }

  void setTool(PlanTool t) => setState(() {
        _tool = t;
        _calib.clear();
        _railPts.clear();
        _resetMeasure();
        _hover = null;
        if (t != PlanTool.select) _marquee = null;
      });

  void _resetMeasure() {
    _mPts.clear();
    _mDone = null;
    _mCursor = null;
    _walkA = null;
  }

  // ------------------------------------------------------------------ vue
  PlanView _view(Size size) {
    final base = PlanView.fit(size, planBounds(_plan!), margin: 20);
    final c = Offset(size.width, size.height) / 2;
    return PlanView(c + (base.origin - c) * _zoom + _pan, base.scale * _zoom);
  }

  void _zoomAt(Offset focal, double factor) {
    final v = _view(_size);
    final m = v.toM(focal);
    _zoom = (_zoom * factor).clamp(0.2, 30.0);
    final nv = _view(_size);
    _pan += focal - nv.toPx(m.$1, m.$2);
  }

  double get _tolM => 10 / _view(_size).scale; // 10 px en mètres

  bool get _shift => HardwareKeyboard.instance.isShiftPressed;
  bool get _alt => HardwareKeyboard.instance.isAltPressed;
  bool get _ctrl => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

  ({P p, bool snapped}) _measureSnap(P p) {
    if (!_alt) {
      final s = snapMeasure(_els.where(_layers.visible).toList(), p, math.max(0.2, 14 / _view(_size).scale));
      if (s != null) return (p: s.p, snapped: true);
    }
    return (p: _alt ? (r2(p.$1), r2(p.$2)) : _st.snapP(p), snapped: false);
  }

  Map<String, dynamic>? _hit(P m) => hitTest(_els, m.$1, m.$2, tol: math.max(0.15, _tolM), visible: _layers.visible);

  // ------------------------------------------------------------------ pointeur
  void _onDown(PointerDownEvent e) {
    _focus.requestFocus();
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      // second doigt : on annule le geste en cours et on passe en zoom / déplacement
      if (_before != null && _changed) PlanHistory.restore(_plan!, _before!);
      final ps = _pointers.values.toList();
      _pinchDist = (ps[0] - ps[1]).distance;
      _pinchMid = (ps[0] + ps[1]) / 2;
      setState(() {
        _mode = _Drag.pinch;
        _marquee = null;
        _before = null;
        _changed = false;
      });
      return;
    }
    if (_pointers.length > 2) return;
    final v = _view(_size);
    final m = v.toM(e.localPosition);
    _downPx = e.localPosition;
    _downM = m;
    _curM = m;
    _moved = false;
    _changed = false;
    _before = null;
    final secondary = (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0;
    if (secondary || _tool == PlanTool.pan) {
      _mode = _Drag.pan;
      return;
    }
    switch (_tool) {
      case PlanTool.select:
        // poignée de l'élément sélectionné ?
        final one = _single;
        if (one != null && _layers.editable(one)) {
          for (final h in handlesFor(one)) {
            if ((v.toPx(h.p.$1, h.p.$2) - e.localPosition).distance <= 12) {
              _mode = _Drag.handle;
              _handle = h;
              _handleOrig = deepCopyEl(one);
              _before = PlanHistory.snapshot(_plan!);
              return;
            }
          }
        }
        final hit = _hit(m);
        final additive = _shift || _ctrl || _multi;
        if (hit != null && _layers.editable(hit)) {
          final id = '${hit['id']}';
          if (additive) {
            setState(() => _sel.contains(id) ? _sel.remove(id) : _sel.add(id));
            _mode = _Drag.none;
            return;
          }
          if (!_sel.contains(id)) setState(() => _sel = [id]);
          _mode = _Drag.move;
          _origs = {for (final x in _selEls) '${x['id']}': deepCopyEl(x)};
          _before = PlanHistory.snapshot(_plan!);
        } else {
          if (!additive) setState(() => _sel = []);
          _mode = _Drag.marquee;
        }
      case PlanTool.erase:
        _mode = _Drag.erase;
        _before = PlanHistory.snapshot(_plan!);
        _eraseAt(m);
      case PlanTool.measure:
        _mode = _Drag.measure;
        if ((_mMode == 'dist' || _mMode == 'area') && _mPts.isEmpty) _measureTap(m);
      case PlanTool.wall:
      case PlanTool.aisle:
      case PlanTool.zone:
        _mode = _Drag.draw;
        _downM = _tool == PlanTool.wall ? snapToWallEnds(_els, m, _st) : _st.snapP(m);
        _curM = _downM;
      case PlanTool.background:
        final bg = _plan!['background_local'] as Map?;
        if (bg != null) {
          _mode = _Drag.bg;
          _bgOrig = Map.of(bg);
          _before = PlanHistory.snapshot(_plan!);
        } else {
          _mode = _Drag.none;
        }
      default:
        _mode = _Drag.tap;
    }
    setState(() {});
  }

  void _onHover(PointerHoverEvent e) {
    final m = _view(_size).toM(e.localPosition);
    if (_tool == PlanTool.erase) {
      final h = _hit(m);
      final id = h == null || !_layers.editable(h) ? null : '${h['id']}';
      if (id != _hover) setState(() => _hover = id);
    } else if (_tool == PlanTool.measure) {
      if (_mMode == 'walk') {
        final h = _hit(m);
        final id = h?['kind'] == 'machine' ? '${h!['id']}' : null;
        if (id != _hover) setState(() => _hover = id);
      } else {
        setState(() => _mCursor = _measureSnap(m));
      }
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_mode == _Drag.pinch) {
      if (_pointers.length < 2) return;
      final ps = _pointers.values.toList();
      final d = (ps[0] - ps[1]).distance, mid = (ps[0] + ps[1]) / 2;
      setState(() {
        _pan += mid - _pinchMid;
        if (_pinchDist > 0 && d > 0) _zoomAt(mid, d / _pinchDist);
        _pinchDist = d;
        _pinchMid = mid;
      });
      return;
    }
    if ((e.localPosition - _downPx).distance > 4) _moved = true;
    final m = _view(_size).toM(e.localPosition);
    _curM = m;
    final st = _st;
    switch (_mode) {
      case _Drag.pan:
        setState(() => _pan += e.delta);
      case _Drag.move:
        if (!_moved) return;
        final dx = st.snapV(m.$1 - _downM.$1), dy = st.snapV(m.$2 - _downM.$2);
        for (final x in _selEls) {
          final o = _origs['${x['id']}'];
          if (o == null) continue;
          final moved = deepCopyEl(o);
          moveEl(moved, dx, dy);
          x
            ..clear()
            ..addAll(moved);
        }
        _changed = dx != 0 || dy != 0;
        setState(() {});
      case _Drag.handle:
        final one = _single;
        if (one == null || _handle == null) return;
        final h = _handle!;
        final p = (h.kind == HandleKind.end1 || h.kind == HandleKind.end2) ? snapToWallEnds(_els, m, st, except: '${one['id']}') : st.snapP(m);
        applyHandle(one, _handleOrig!, h, h.kind == HandleKind.rotate ? m : p, st, freeRotate: _alt);
        _changed = true;
        setState(() {});
      case _Drag.erase:
        _eraseAt(m);
      case _Drag.marquee:
        if (_moved) setState(() => _marquee = (_downM, m));
      case _Drag.draw:
        setState(() {});
      case _Drag.bg:
        final bg = _plan!['background_local'] as Map;
        bg['x'] = r2(_n(_bgOrig!['x']) + m.$1 - _downM.$1);
        bg['y'] = r2(_n(_bgOrig!['y']) + m.$2 - _downM.$2);
        _changed = true;
        setState(() {});
      case _Drag.measure:
        if (_mMode != 'walk') setState(() => _mCursor = _measureSnap(m));
      default:
        break;
    }
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_mode == _Drag.pinch) {
      if (_pointers.isEmpty) _mode = _Drag.none;
      return;
    }
    final mode = _mode;
    _mode = _Drag.none;
    final m = _curM;
    if (_before != null && _changed) {
      history.push(_before!);
      _dirty = true;
    }
    _before = null;
    _changed = false;
    final now = DateTime.now();
    final dbl = !_moved && now.difference(_lastTap).inMilliseconds < 350 && (e.localPosition - _lastTapPx).distance < 12;
    if (!_moved) {
      _lastTap = now;
      _lastTapPx = e.localPosition;
    }
    switch (mode) {
      case _Drag.marquee:
        final mq = _marquee;
        if (mq != null) {
          final inside = idsInRect(_els, mq.$1, mq.$2, visible: _layers.editable);
          _sel = (_shift || _ctrl || _multi) ? {..._sel, ...inside}.toList() : inside;
        }
        _marquee = null;
      case _Drag.draw:
        _finishDraw();
      case _Drag.measure:
        if (_mMode == 'walk' || _mMode == 'chain') {
          if (dbl && _mMode == 'chain') {
            finishChain();
          } else if (!_moved) {
            _measureTap(m);
          }
        } else if (_moved && _mPts.length == 1) {
          _measureTap(m);
        } else if (!_moved && _mPts.length == 1 && _dist(m, _mPts.first) > _tolM) {
          _measureTap(m);
        }
      case _Drag.tap:
        if (!_moved) _tap(m, dbl);
      default:
        break;
    }
    setState(() {});
  }

  double _dist(P a, P b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

  void _eraseAt(P m) {
    final h = _hit(m);
    if (h == null || !_layers.editable(h)) return;
    _els.remove(h);
    _sel.remove(h['id']);
    _changed = true;
    setState(() {});
  }

  void _finishDraw() {
    final a = _downM;
    final st = _st;
    if (_tool == PlanTool.wall) {
      var b = snapToWallEnds(_els, _curM, st);
      if (_shift) b = (b.$1 - a.$1).abs() >= (b.$2 - a.$2).abs() ? (b.$1, a.$2) : (a.$1, b.$2);
      if (_dist(a, b) < 0.2) return;
      edit(() {
        final w = {'id': _newId(), 'kind': 'wall', 'x1': a.$1, 'y1': a.$2, 'x2': b.$1, 'y2': b.$2, 'thickness': 0.2};
        _els.add(w);
        _sel = ['${w['id']}'];
      });
      return;
    }
    final b = st.snapP(_curM);
    final x0 = math.min(a.$1, b.$1), y0 = math.min(a.$2, b.$2), w = (a.$1 - b.$1).abs(), h = (a.$2 - b.$2).abs();
    if (w < 0.2 || h < 0.2) return;
    edit(() {
      final el = _tool == PlanTool.aisle
          ? {'id': _newId(), 'kind': 'aisle', 'x': x0, 'y': y0, 'w': r2(w), 'h': r2(h), 'main': math.min(w, h) >= st.mainAisleMin}
          : {'id': _newId(), 'kind': 'zone', 'x': x0, 'y': y0, 'w': r2(w), 'h': r2(h), 'zone': _zoneType, 'name': workshopZones[_zoneType]};
      _els.add(el);
      _sel = ['${el['id']}'];
    });
  }

  void _tap(P m, bool dbl) {
    final st = _st;
    switch (_tool) {
      case PlanTool.machine:
        placeMachine(m);
      case PlanTool.pillar:
        final (x, y) = st.snapP(m);
        edit(() {
          final el = {'id': _newId(), 'kind': 'pillar', 'x': x, 'y': y, 'w': 0.4, 'd': 0.4};
          _els.add(el);
          _sel = ['${el['id']}'];
        });
      case PlanTool.door:
        final w = nearestWallAngle(_els, m.$1, m.$2);
        final (x, y) = w == null ? st.snapP(m) : (w.x, w.y);
        edit(() {
          final el = {'id': _newId(), 'kind': 'door', 'x': x, 'y': y, 'width': 1.2, 'rot': ((w?.angle ?? 0).round() % 360 + 360) % 360, 'exit': false};
          _els.add(el);
          _sel = ['${el['id']}'];
        });
      case PlanTool.rail:
        final p = st.snapP(m);
        if (dbl || (_railPts.length >= 3 && _dist(p, _railPts.first) <= math.max(0.3, _tolM))) {
          finishRail();
        } else {
          setState(() => _railPts.add(p));
        }
      case PlanTool.calibrate:
        if (_calib.length < 2) setState(() => _calib.add(m));
      default:
        break;
    }
  }

  void placeMachine(P m, [String? type]) {
    final (x, y) = _st.snapP(m);
    edit(() {
      final el = newMachine(_newId(), type ?? _machineType, x, y, label: nextLabel(_els));
      _els.add(el);
      _sel = ['${el['id']}'];
    });
  }

  void finishRail() {
    if (_railPts.length < 3) {
      setState(_railPts.clear);
      return;
    }
    final pts = List.of(_railPts);
    _railPts.clear();
    edit(() {
      final r = newRail(_newId(), pts);
      _els.add(r);
      _sel = ['${r['id']}'];
      _msg = 'Boucle de convoyeur ajoutée (${frNum(railLength(r), 1)} m).';
    });
  }

  // ------------------------------------------------------------------ mesure
  void _measureTap(P raw) {
    if (_mMode == 'walk') {
      final hit = _hit(raw);
      if (hit == null || hit['kind'] != 'machine') {
        setState(() => _msg = 'Chemin à pied : touchez une machine.');
        return;
      }
      final id = '${hit['id']}';
      if (_walkA == null || _walkA == id) {
        setState(() {
          _walkA = id;
          _mDone = null;
          _msg = null;
        });
        return;
      }
      final r = walkRoute(_plan!, _walkA!, id);
      if (r == null) {
        setState(() {
          _msg = 'Aucun passage à pied entre ces deux machines (murs, poteaux ou machines bloquent le chemin).';
          _walkA = null;
        });
        return;
      }
      final a = _el(_walkA)!;
      _finishMeasure('walk', r.pts, note: '${a['label']} → ${hit['label']}');
      final direct = _dist(r.pts.first, r.pts.last);
      setState(() => _msg = 'Chemin à pied ${a['label']} → ${hit['label']} : ${frNum(r.length, 1)} m (à vol d\'oiseau ${frNum(direct, 1)} m).');
      return;
    }
    final p = _measureSnap(raw).p;
    setState(() {
      _mDone = null;
      if (_mMode == 'chain') {
        _mPts.add(p);
      } else if (_mPts.isEmpty) {
        _mPts.add(p);
      } else {
        _finishMeasure(_mMode, [_mPts.first, p]);
      }
    });
  }

  void finishChain() {
    if (_mMode == 'chain' && _mPts.length >= 2) _finishMeasure('chain', List.of(_mPts));
  }

  void _finishMeasure(String mode, List<P> pts, {String? note}) {
    final d = newDim(_newId(), mode, pts, note: note);
    _mPts.clear();
    _walkA = null;
    if (_keepDim) {
      edit(() => _els.add(d));
      _mDone = null;
      _msg = 'Cote ajoutée au plan : ${dimText(d)}.';
    } else {
      _mDone = d;
    }
    setState(() {});
  }

  void keepCurrentDim() {
    final d = _mDone;
    if (d == null) return;
    edit(() {
      _els.add(d..['id'] = _newId());
      _mDone = null;
      _msg = 'Cote ajoutée au plan : ${dimText(d)}.';
    });
  }

  // ------------------------------------------------------------------ actions sur la sélection
  void deleteSelection() {
    if (_sel.isEmpty) return;
    edit(() {
      removeIds(_els, _sel);
      _sel = [];
    });
  }

  void duplicateSelection() {
    if (_sel.isEmpty) return;
    edit(() => _sel = [for (final e in duplicateIds(_els, _sel, _newId)) '${e['id']}']);
  }

  void copySelection({bool cut = false}) {
    if (_sel.isEmpty) return;
    _clipboard = [for (final e in _selEls) deepCopyEl(e)];
    _pasteCount = 0;
    if (cut) {
      deleteSelection();
    } else {
      setState(() => _msg = '${_clipboard.length} élément(s) copié(s).');
    }
  }

  void paste() {
    if (_clipboard.isEmpty) return;
    _pasteCount++;
    edit(() => _sel = [for (final e in pasteElements(_els, _clipboard, _newId, offset: (0.5 * _pasteCount, 0.5 * _pasteCount))) '${e['id']}']);
  }

  void rotateSelection(double deg) {
    if (_sel.isEmpty) return;
    edit(() => rotateIds(_els, _sel, deg));
  }

  void nudge(double dx, double dy) {
    if (_sel.isEmpty) return;
    edit(() {
      for (final e in _selEls) {
        moveEl(e, dx, dy);
      }
    });
  }

  // ------------------------------------------------------------------ clavier
  KeyEventResult _onKey(FocusNode node, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    final mod = _ctrl;
    bool isK(LogicalKeyboardKey x) => k == x;
    if (mod && isK(LogicalKeyboardKey.keyZ)) {
      _shift ? redo() : undo();
    } else if (mod && isK(LogicalKeyboardKey.keyY)) {
      redo();
    } else if (mod && isK(LogicalKeyboardKey.keyA)) {
      setState(() {
        _tool = PlanTool.select;
        _sel = [for (final e in _els) if (_layers.editable(e)) '${e['id']}'];
      });
    } else if (mod && isK(LogicalKeyboardKey.keyC)) {
      copySelection();
    } else if (mod && isK(LogicalKeyboardKey.keyX)) {
      copySelection(cut: true);
    } else if (mod && isK(LogicalKeyboardKey.keyV)) {
      paste();
    } else if (mod && isK(LogicalKeyboardKey.keyD)) {
      duplicateSelection();
    } else if (isK(LogicalKeyboardKey.enter) || isK(LogicalKeyboardKey.numpadEnter)) {
      if (_tool == PlanTool.measure) finishChain();
      if (_tool == PlanTool.rail) finishRail();
    } else if (isK(LogicalKeyboardKey.escape)) {
      setState(() {
        if (_tool == PlanTool.measure && (_mPts.isNotEmpty || _mDone != null || _walkA != null)) {
          _resetMeasure();
        } else if (_tool == PlanTool.rail && _railPts.isNotEmpty) {
          _railPts.clear();
        } else if (_sel.isNotEmpty) {
          _sel = [];
        } else {
          _tool = PlanTool.select;
        }
      });
    } else if ((isK(LogicalKeyboardKey.delete) || isK(LogicalKeyboardKey.backspace)) && _sel.isNotEmpty) {
      deleteSelection();
    } else if (!mod && !_alt && isK(LogicalKeyboardKey.keyV)) {
      setTool(PlanTool.select);
    } else if (!mod && !_alt && isK(LogicalKeyboardKey.keyH)) {
      setTool(PlanTool.pan);
    } else if (!mod && !_alt && isK(LogicalKeyboardKey.keyE)) {
      setTool(PlanTool.erase);
    } else if (!mod && !_alt && isK(LogicalKeyboardKey.keyM)) {
      setTool(PlanTool.measure);
    } else if (!mod && isK(LogicalKeyboardKey.keyR) && _sel.isNotEmpty) {
      rotateSelection(_shift ? -15 : 90);
    } else if (_sel.isNotEmpty &&
        (isK(LogicalKeyboardKey.arrowLeft) || isK(LogicalKeyboardKey.arrowRight) || isK(LogicalKeyboardKey.arrowUp) || isK(LogicalKeyboardKey.arrowDown))) {
      final s = _shift ? 0.5 : _st.grid;
      nudge(isK(LogicalKeyboardKey.arrowLeft) ? -s : (isK(LogicalKeyboardKey.arrowRight) ? s : 0),
          isK(LogicalKeyboardKey.arrowUp) ? -s : (isK(LogicalKeyboardKey.arrowDown) ? s : 0));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------------ fond de plan / import
  Future<void> _import() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'pdf', 'dxf'], withData: true);
    final f = res?.files.single;
    final bytes = f?.bytes;
    if (f == null || bytes == null) return;
    final name = f.name.toLowerCase();
    try {
      if (name.endsWith('.dxf')) {
        await importDxf(utf8.decode(bytes, allowMalformed: true));
      } else if (name.endsWith('.pdf')) {
        final png = await _rasterPdf(bytes);
        if (png == null) throw const FormatException('PDF vide ou illisible.');
        await setBackground(png, source: '${f.name} (page 1)');
      } else {
        if (bytes.length > 8 * 1024 * 1024) throw const FormatException('Image trop lourde (8 Mo maximum).');
        await setBackground(bytes, source: f.name);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Import impossible : ${e is FormatException ? e.message : e}', error: true);
    }
  }

  /// 1re page d'un PDF en PNG (pdf.js sur le Web, pdfium sur Windows/Linux, PdfRenderer sur Android).
  Future<Uint8List?> _rasterPdf(Uint8List bytes) async {
    await for (final page in Printing.raster(bytes, pages: const [0], dpi: 150)) {
      return page.toPng();
    }
    return null;
  }

  Future<void> importDxf(String text) async {
    final unit = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text('Unité du DXF'), children: [
        for (final (v, l) in [('auto', 'Lire dans le fichier (\$INSUNITS)'), ('mm', 'Millimètres'), ('cm', 'Centimètres'), ('m', 'Mètres')])
          SimpleDialogOption(onPressed: () => Navigator.pop(c, v), child: Text(l)),
      ]),
    );
    if (unit == null || !mounted) return;
    final r = dxfToWalls(text, _newId, unit: unit);
    edit(() {
      final onlyFrame = _els.length <= 4;
      if (onlyFrame) _els.removeWhere((e) => e['kind'] == 'wall');
      _els.addAll(r.walls);
      _plan!['width_m'] = math.max(_n(_plan!['width_m'], 30), r.width).clamp(2, 400);
      _plan!['length_m'] = math.max(_n(_plan!['length_m'], 20), r.length).clamp(2, 400);
      _msg = '${r.walls.length} murs importés du DXF (unité : ${r.unit}). Vérifiez les cotes avec la Mesure.';
    });
  }

  Future<void> setBackground(Uint8List bytes, {String source = ''}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    // échelle initiale : l'image couvre la largeur de la salle ; à calibrer ensuite
    final mpp = _n(_plan!['width_m'], 30) / img.width;
    edit(() {
      _bg = img;
      _plan!['background_local'] = {'data': base64Encode(bytes), 'm_per_px': mpp, 'x': 0.0, 'y': 0.0, 'opacity': 0.55, 'source': source};
    });
    setTool(PlanTool.calibrate);
    if (mounted) showSnack(context, 'Fond importé. Calibrez : touchez 2 points dont vous connaissez la distance réelle.');
  }

  void applyCalibration() {
    final real = parseNum(_calibCtl.text);
    final bg = _plan!['background_local'] as Map?;
    if (_calib.length != 2 || real == null || real <= 0 || bg == null) return;
    final d = _dist(_calib[0], _calib[1]);
    if (d < 0.01) return;
    final k = real / d;
    final (px, py) = _calib[0];
    edit(() {
      bg['m_per_px'] = _n(bg['m_per_px']) * k;
      bg['x'] = r2(px + (_n(bg['x']) - px) * k);
      bg['y'] = r2(py + (_n(bg['y']) - py) * k);
      _msg = 'Échelle calibrée (×${k.toStringAsFixed(3)}).';
    });
    _calibCtl.clear();
    setTool(PlanTool.select);
  }

  void fitRoomToBackground() {
    final bg = _plan!['background_local'] as Map?;
    if (bg == null || _bg == null) return;
    edit(() {
      _plan!['width_m'] = r2((_n(bg['x']) + _bg!.width * _n(bg['m_per_px'])).clamp(2, 400).toDouble());
      _plan!['length_m'] = r2((_n(bg['y']) + _bg!.height * _n(bg['m_per_px'])).clamp(2, 400).toDouble());
    });
  }

  // ------------------------------------------------------------------ enregistrement
  Future<void> _save() async {
    final s = context.read<AppState>();
    setState(() => _saving = true);
    _settings['run_id'] = _runId;
    _plan!['ui_layers'] = _layers.toJson();
    final err = await s.savePlan(_plan!);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    showSnack(context, err == null ? (s.cloudAvailable ? 'Plan enregistré et synchronisé.' : 'Plan enregistré sur l\'appareil.') : 'Enregistré sur l\'appareil (serveur : $err)');
  }

  Future<void> _resize() async {
    final w = await promptText(context, 'Largeur de la salle (m)', initial: fmtNum(_n(_plan!['width_m']), 1));
    if (!mounted || w == null) return;
    final l = await promptText(context, 'Longueur de la salle (m)', initial: fmtNum(_n(_plan!['length_m']), 1));
    final wv = parseNum(w), lv = parseNum(l ?? '');
    if (wv == null || lv == null) return;
    edit(() {
      _plan!['width_m'] = wv.clamp(2, 400);
      _plan!['length_m'] = lv.clamp(2, 400);
    });
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (_plan == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, text: 'Plan introuvable.'));
    }
    final w = MediaQuery.sizeOf(context).width;
    final wide = w >= Breakpoints.desktop;
    final runs = _runs(s);
    final run = runs.where((r) => r.id == _runId).firstOrNull;
    final plan = run == null ? null : twinPlan(run.balance!, run.problem);
    final stations = plan == null ? const <int>[] : stationOrder(plan);
    final machineStation = <String, String>{};
    if (plan != null) {
      final lay = planLayout(plan['stations'] as List, _plan!);
      (lay['assignment'] as Map).forEach((sid, ids) {
        for (final id in ids as List) {
          machineStation['$id'] = 'S$sid';
        }
      });
    }
    final issues = checkPlan(_plan!);
    final canvas = _view3d ? _canvas3d() : _canvas(machineStation, {for (final i in issues) if (i.level == 'err') ...i.ids});
    final panel = _panel(stations, runs, issues);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirm(context, 'Modifications non enregistrées', 'Quitter sans enregistrer le plan ?', ok: 'Quitter');
        if (leave && context.mounted) {
          setState(() => _dirty = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_plan!['name']}', overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'Dimensions de la salle', onPressed: _resize, icon: const Icon(Icons.aspect_ratio)),
            IconButton(
                key: const Key('plan-import'),
                tooltip: 'Importer un plan (PNG, JPG, PDF, DXF)',
                onPressed: _import,
                icon: const Icon(Icons.upload_file_outlined)),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: const Key('plan-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_dirty ? 'Enregistrer*' : 'Enregistrer'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            _toolbar(),
            if (!_view3d) _hintBar(),
            const Divider(height: 1),
            Expanded(
              child: wide
                  ? Row(children: [
                      Expanded(child: canvas),
                      const VerticalDivider(width: 1),
                      SizedBox(width: 340, child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: panel)),
                    ])
                  : Column(children: [
                      Expanded(flex: 3, child: canvas),
                      const Divider(height: 1),
                      Expanded(flex: 2, child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: panel)),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          SegmentedButton<bool>(
            key: const Key('plan-dim'),
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('2D')), ButtonSegment(value: true, label: Text('3D'))],
            selected: {_view3d},
            onSelectionChanged: (v) => setState(() => _view3d = v.first),
          ),
          const SizedBox(width: 8),
          if (!_view3d)
            for (final e in toolInfo.entries)
              if (e.key != PlanTool.calibrate && e.key != PlanTool.background || _plan!['background_local'] != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: '${e.value.$1}${e.value.$3 == null ? '' : ' (${e.value.$3})'} — ${e.value.$4}',
                    waitDuration: const Duration(milliseconds: 600),
                    child: ChoiceChip(
                      key: Key('tool-${e.key.name}'),
                      avatar: Icon(e.value.$2, size: 16, color: e.key == PlanTool.erase ? Brand.danger : null),
                      label: Text(e.value.$1),
                      selected: _tool == e.key,
                      onSelected: (_) => setTool(e.key),
                    ),
                  ),
                ),
          const SizedBox(width: 4),
          IconButton(key: const Key('plan-undo'), tooltip: 'Annuler (Ctrl+Z)', onPressed: history.canUndo ? undo : null, icon: const Icon(Icons.undo)),
          IconButton(key: const Key('plan-redo'), tooltip: 'Rétablir (Ctrl+Y)', onPressed: history.canRedo ? redo : null, icon: const Icon(Icons.redo)),
          if (!_view3d) ...[
            IconButton(tooltip: 'Zoom +', onPressed: () => setState(() => _zoomAt(_size.center(Offset.zero), 1.25)), icon: const Icon(Icons.zoom_in)),
            IconButton(tooltip: 'Zoom −', onPressed: () => setState(() => _zoomAt(_size.center(Offset.zero), 0.8)), icon: const Icon(Icons.zoom_out)),
            IconButton(
              tooltip: 'Ajuster',
              onPressed: () => setState(() {
                _zoom = 1;
                _pan = Offset.zero;
              }),
              icon: const Icon(Icons.fit_screen_outlined),
            ),
          ],
        ]),
      );

  Widget _hintBar() {
    final hint = _tool == PlanTool.measure ? _measureModes[_mMode]!.$2 : toolInfo[_tool]!.$4;
    return Container(
      width: double.infinity,
      color: Brand.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hint, style: const TextStyle(fontSize: 12, color: Brand.muted)),
        if (_tool == PlanTool.measure) _measureBar(),
        if (_tool == PlanTool.calibrate) _calibBar(),
        if (_tool == PlanTool.rail && _railPts.isNotEmpty)
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${_railPts.length} point(s)', style: const TextStyle(fontSize: 12)),
            TextButton(onPressed: finishRail, child: const Text('Fermer la boucle (Entrée)')),
            TextButton(onPressed: () => setState(_railPts.clear), child: const Text('Effacer (Échap)')),
          ]),
        if (_tool == PlanTool.select && _sel.isNotEmpty)
          Text('${_sel.length} sélectionné(s) · Suppr effacer · Ctrl+C/V copier-coller · Ctrl+D dupliquer · R pivoter · flèches déplacer · Échap',
              style: const TextStyle(fontSize: 12, color: Brand.navy)),
        if (_msg != null)
          Row(children: [
            Expanded(child: Text(_msg!, style: const TextStyle(fontSize: 12, color: Brand.navy, fontWeight: FontWeight.w600))),
            IconButton(visualDensity: VisualDensity.compact, iconSize: 16, onPressed: () => setState(() => _msg = null), icon: const Icon(Icons.close)),
          ]),
      ]),
    );
  }

  Widget _measureBar() {
    final live = _liveDim();
    return Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final e in _measureModes.entries)
        ChoiceChip(
          key: Key('measure-${e.key}'),
          visualDensity: VisualDensity.compact,
          label: Text(e.value.$1),
          selected: _mMode == e.key,
          onSelected: (_) => setState(() {
            _mMode = e.key;
            _resetMeasure();
          }),
        ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(key: const Key('measure-keep'), value: _keepDim, onChanged: (v) => setState(() => _keepDim = v ?? false)),
        const Text('Garder la cote sur le plan', style: TextStyle(fontSize: 12)),
      ]),
      if (_mMode == 'chain' && _mPts.length >= 2) ...[
        Text('${frNum(polyLen(_mPts))} m', style: const TextStyle(fontWeight: FontWeight.w700)),
        FilledButton.tonal(onPressed: finishChain, child: const Text('Terminer')),
      ],
      if (_mMode == 'walk' && _walkA != null) Text('Départ : ${_el(_walkA)?['label'] ?? ''} — touchez la machine d\'arrivée.', style: const TextStyle(fontSize: 12)),
      if (live != null) Text('${dimText(live)}${_mCursor?.snapped ?? false ? ' · aimanté' : ''}', style: const TextStyle(fontSize: 12, color: Brand.muted)),
      if (_mDone != null) ...[
        Text(dimText(_mDone!), key: const Key('measure-result'), style: const TextStyle(fontWeight: FontWeight.w700)),
        OutlinedButton(key: const Key('measure-keep-this'), onPressed: keepCurrentDim, child: const Text('Garder cette cote')),
      ],
      if (_mPts.isNotEmpty || _mDone != null || _walkA != null)
        TextButton(onPressed: () => setState(_resetMeasure), child: const Text('Effacer (Échap)')),
    ]);
  }

  Map<String, dynamic>? _liveDim() {
    final c = _mCursor;
    if (_tool != PlanTool.measure || _mMode == 'walk' || c == null || _mPts.isEmpty) return null;
    if (_mMode == 'chain') return newDim('live', 'chain', [..._mPts, c.p]);
    return newDim('live', _mMode, [_mPts.first, c.p]);
  }

  Widget _calibBar() => Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(_calib.length < 2 ? 'Calibrage : touchez le point ${_calib.length + 1} sur 2.' : 'Distance réelle entre les 2 points :',
            style: const TextStyle(fontSize: 12)),
        if (_calib.length == 2) ...[
          SizedBox(
            width: 110,
            child: TextField(
              key: const Key('calib-dist'),
              controller: _calibCtl,
              autofocus: true,
              decoration: const InputDecoration(isDense: true, suffixText: 'm'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onSubmitted: (_) => applyCalibration(),
            ),
          ),
          FilledButton(key: const Key('calib-apply'), onPressed: applyCalibration, child: const Text('Appliquer')),
        ],
        TextButton(onPressed: () => setTool(PlanTool.select), child: const Text('Annuler')),
      ]);

  Widget _canvas(Map<String, String> machineStation, Set<String> issueIds) => LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        _size = size;
        final v = _view(size);
        return DragTarget<String>(
          onAcceptWithDetails: (d) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            setTool(PlanTool.machine);
            _machineType = d.data;
            placeMachine(v.toM(box.globalToLocal(d.offset + const Offset(20, 14))), d.data);
          },
          builder: (context, _, _) => Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: MouseRegion(
              cursor: switch (_tool) {
                PlanTool.pan => SystemMouseCursors.grab,
                PlanTool.select => SystemMouseCursors.basic,
                PlanTool.erase => SystemMouseCursors.click,
                _ => SystemMouseCursors.precise,
              },
              onExit: (_) => setState(() {
                _hover = null;
                if (_tool == PlanTool.measure && _mode == _Drag.none) _mCursor = null;
              }),
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
                onPointerCancel: _onUp,
                onPointerHover: _onHover,
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) setState(() => _zoomAt(e.localPosition, e.scrollDelta.dy > 0 ? 0.9 : 1.1));
                },
                onPointerPanZoomUpdate: (e) => setState(() {
                  _pan += e.panDelta;
                  if (e.scale != 1) _zoomAt(e.localPosition, e.scale.clamp(0.9, 1.1));
                }),
                child: ClipRect(
                  child: CustomPaint(
                    key: const Key('plan-canvas'),
                    size: size,
                    painter: _EditorPainter(
                      plan: _plan!,
                      view: v,
                      selected: _sel.toSet(),
                      issueIds: issueIds,
                      layers: _layers,
                      machineStation: machineStation,
                      background: _bg,
                      draft: _mode == _Drag.draw ? (_tool, _downM, _curM, _shift) : null,
                      handles: _single != null && _tool == PlanTool.select && _layers.editable(_single!) ? handlesFor(_single!) : const [],
                      marquee: _marquee,
                      hover: _hover == null ? null : _el(_hover),
                      hoverDanger: _tool == PlanTool.erase,
                      measurePts: _tool == PlanTool.measure ? List.of(_mPts) : const [],
                      measureCursor: _tool == PlanTool.measure && _mMode != 'walk' ? _mCursor : null,
                      liveDim: _liveDim(),
                      doneDim: _mDone,
                      walkA: _walkA == null ? null : _el(_walkA),
                      railPts: _tool == PlanTool.rail ? List.of(_railPts) : const [],
                      calib: List.of(_calib),
                      gridStep: _st.grid,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      });

  Widget _canvas3d() {
    final mesh = buildPlanScene(_plan!, detailed: _detailed3d, withOperators: true, hiddenKinds: _layers.hidden);
    return Scene3DView(
      key: const Key('plan-3d'),
      meshes: [mesh],
      bounds: (0, 0, _n(_plan!['width_m'], 30), _n(_plan!['length_m'], 20)),
      labels: [
        for (final m in planMachines(_plan!))
          if (_layers.visible(m) && '${m['label'] ?? ''}'.isNotEmpty) Label3D(vm.Vector3(_n(m['x']), 1.3, _n(m['y'])), '${m['label']}'),
      ],
      onPick: (tag) {
        if (tag.startsWith('m:')) setState(() => _sel = [tag.substring(2)]);
      },
      overlay: Material(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('Simple')), ButtonSegment(value: true, label: Text('Détaillé'))],
            selected: {_detailed3d},
            onSelectionChanged: (v) => setState(() => _detailed3d = v.first),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ panneau latéral
  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
      );

  Widget _panel(List<int> stations, List<RunRecord> runs, List<PlanIssue> issues) {
    final one = _single;
    final st = _st;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_tool == PlanTool.machine) ..._library(),
      if (_tool == PlanTool.zone) ...[
        DropdownButtonFormField<String>(
          initialValue: _zoneType,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Type de zone (glissez pour tracer)'),
          items: [for (final e in workshopZones.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _zoneType = v ?? _zoneType),
        ),
        const SizedBox(height: 12),
      ],
      if (_tool == PlanTool.select)
        Row(children: [
          Checkbox(key: const Key('plan-multi'), value: _multi, onChanged: (v) => setState(() => _multi = v ?? false)),
          const Expanded(child: Text('Sélection multiple (tablette : chaque toucher ajoute ou retire)', style: TextStyle(fontSize: 12))),
        ]),
      if (one != null)
        ..._selection(one, stations)
      else if (_sel.length > 1)
        ..._multiProps()
      else if (_tool == PlanTool.select)
        const Text('Touchez un élément pour modifier ses propriétés, ou encadrez-en plusieurs. Raccourcis : Suppr, Ctrl+C / Ctrl+V, Ctrl+D, R, flèches, Échap, Ctrl+Z / Ctrl+Y.',
            style: TextStyle(color: Brand.muted, fontSize: 12)),
      // ---- calques
      _title('Calques'),
      for (final e in planLayers.entries)
        Row(children: [
          Checkbox(
            key: Key('layer-${e.key}'),
            value: _layers.visible({'kind': e.key}),
            onChanged: (v) => setState(() {
              v == true ? _layers.hidden.remove(e.key) : _layers.hidden.add(e.key);
              _sel = _sel.where((id) => _layers.editable(_el(id) ?? const {})).toList();
            }),
          ),
          Expanded(child: Text('${e.value} (${_els.where((x) => x['kind'] == e.key).length})', style: const TextStyle(fontSize: 13))),
          IconButton(
            key: Key('lock-${e.key}'),
            tooltip: _layers.locked.contains(e.key) ? 'Déverrouiller' : 'Verrouiller',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: () => setState(() {
              _layers.locked.contains(e.key) ? _layers.locked.remove(e.key) : _layers.locked.add(e.key);
              _sel = _sel.where((id) => _layers.editable(_el(id) ?? const {})).toList();
            }),
            icon: Icon(_layers.locked.contains(e.key) ? Icons.lock : Icons.lock_open, color: _layers.locked.contains(e.key) ? Brand.orange : Brand.low),
          ),
        ]),
      // ---- aimantation
      _title('Aimantation'),
      Row(children: [
        Switch(key: const Key('plan-snap'), value: st.snap, onChanged: (v) => edit(() => _settings['snap'] = v)),
        const Expanded(child: Text('Aimanter à la grille', overflow: TextOverflow.ellipsis)),
        DropdownButton<double>(
          value: [0.05, 0.1, 0.25, 0.5, 1.0].contains(st.grid) ? st.grid : 0.1,
          items: const [
            DropdownMenuItem(value: 0.05, child: Text('5 cm')),
            DropdownMenuItem(value: 0.1, child: Text('10 cm')),
            DropdownMenuItem(value: 0.25, child: Text('25 cm')),
            DropdownMenuItem(value: 0.5, child: Text('50 cm')),
            DropdownMenuItem(value: 1.0, child: Text('1 m')),
          ],
          onChanged: (v) => edit(() {
            _settings['grid'] = v ?? 0.1;
            _settings['grid_m'] = v ?? 0.1;
          }),
        ),
      ]),
      // ---- contrôles
      _title('Contrôles (${issues.length})'),
      if (issues.isEmpty)
        const Text('Rien à signaler.', style: TextStyle(fontSize: 12))
      else
        for (final i in issues.take(12))
          InkWell(
            onTap: i.ids.isEmpty
                ? null
                : () => setState(() {
                      _tool = PlanTool.select;
                      _sel = [...i.ids];
                    }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(i.level == 'err' ? Icons.error_outline : (i.level == 'warn' ? Icons.warning_amber : Icons.info_outline),
                    size: 16, color: i.level == 'err' ? Brand.danger : (i.level == 'warn' ? Brand.warn : Brand.mid)),
                const SizedBox(width: 6),
                Expanded(child: Text(i.msg, style: const TextStyle(fontSize: 12))),
              ]),
            ),
          ),
      const Text('Repères indicatifs, pas une norme : faites valider issues et circulations.', style: TextStyle(fontSize: 11, color: Brand.muted)),
      // ---- calcul lié
      _title('Calcul lié'),
      if (runs.isEmpty)
        const Text('Aucun calcul terminé : les stations s\'afficheront ici.', style: TextStyle(color: Brand.muted))
      else
        DropdownButton<String>(
          value: _runId,
          isExpanded: true,
          items: [
            for (final r in runs)
              DropdownMenuItem(value: r.id, child: Text('${r.problem.name} · ${r.balance!.stationsUsed} st. · ${fmtDate(r.createdAt)}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() {
            _runId = v;
            _dirty = true;
          }),
        ),
      Text('${planMachines(_plan!).length} machine(s) · ${inventoryWorkstations(_plan!).where((w) => w['available'] == true).length} poste(s) en service'
          '${stations.isEmpty ? '' : ' · ${stations.length} station(s) à placer'}', style: const TextStyle(color: Brand.muted, fontSize: 12)),
      // ---- fond
      if ((_plan!['background_local']) != null) ...[
        _title('Fond de plan'),
        Row(children: [
          const Text('Opacité', style: TextStyle(fontSize: 12)),
          Expanded(
            child: Slider(
              value: _n((_plan!['background_local'] as Map)['opacity'], 0.55).clamp(0.05, 1.0),
              min: 0.05,
              onChanged: (v) => setState(() {
                (_plan!['background_local'] as Map)['opacity'] = v;
                _dirty = true;
              }),
            ),
          ),
        ]),
        Wrap(spacing: 4, children: [
          TextButton.icon(onPressed: () => setTool(PlanTool.calibrate), icon: const Icon(Icons.square_foot, size: 18), label: const Text('Calibrer')),
          TextButton.icon(onPressed: () => setTool(PlanTool.background), icon: const Icon(Icons.open_with, size: 18), label: const Text('Déplacer')),
          TextButton.icon(onPressed: fitRoomToBackground, icon: const Icon(Icons.crop_free, size: 18), label: const Text('Salle = fond')),
          TextButton.icon(
            onPressed: () => edit(() {
              _plan!.remove('background_local');
              _bg = null;
              if (_tool == PlanTool.calibrate || _tool == PlanTool.background) _tool = PlanTool.select;
            }),
            icon: const Icon(Icons.hide_image_outlined, size: 18),
            label: const Text('Retirer'),
          ),
        ]),
      ],
    ]);
  }

  List<Widget> _library() {
    final cats = <String, List<MachineSpec>>{};
    for (final m in machineCatalog.values) {
      cats.putIfAbsent(m.category, () => []).add(m);
    }
    return [
      const Text('Bibliothèque de machines', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
      const Text('Touchez pour choisir puis touchez le plan, ou glissez une machine sur le plan.', style: TextStyle(fontSize: 12, color: Brand.muted)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        key: const Key('machine-type'),
        initialValue: _machineType,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Type de machine'),
        items: [
          for (final m in machineCatalog.values)
            DropdownMenuItem(value: m.type, child: Text('${m.label} (${fmtNum(m.w, 2)}×${fmtNum(m.d, 2)} m)', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => setState(() => _machineType = v ?? _machineType),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 220,
        child: ListView(children: [
          for (final c in cats.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(c.key.toUpperCase(), style: const TextStyle(fontSize: 10, color: Brand.muted, fontWeight: FontWeight.w700)),
            ),
            for (final m in c.value)
              Draggable<String>(
                data: m.type,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Brand.navy, borderRadius: BorderRadius.circular(6)),
                    child: Text(m.label, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  selected: _machineType == m.type,
                  leading: Icon(Icons.drag_indicator, size: 16, color: machineColor(m.category)),
                  title: Text(m.label, style: const TextStyle(fontSize: 12)),
                  trailing: Text('${fmtNum(m.w, 2)}×${fmtNum(m.d, 2)}', style: const TextStyle(fontSize: 11, color: Brand.muted)),
                  onTap: () => setState(() => _machineType = m.type),
                ),
              ),
          ],
        ]),
      ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _multiProps() {
    final els = _selEls;
    const names = {'machine': 'machine', 'wall': 'mur', 'pillar': 'poteau', 'door': 'porte', 'aisle': 'allée', 'zone': 'zone', 'dim': 'cote', 'rail': 'convoyeur'};
    final counts = <String, int>{};
    for (final e in els) {
      counts['${e['kind']}'] = (counts['${e['kind']}'] ?? 0) + 1;
    }
    final nm = counts['machine'] ?? 0;
    return [
      Row(children: [
        Expanded(child: Text('${els.length} éléments', style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy))),
        TextButton(onPressed: () => setState(() => _sel = []), child: const Text('désélectionner')),
      ]),
      Text(counts.entries.map((e) => '${e.value} ${names[e.key] ?? e.key}${e.value > 1 ? 's' : ''}').join(' · '), style: const TextStyle(fontSize: 12)),
      const Text('Glissez un des éléments pour déplacer le groupe, ou utilisez les flèches.', style: TextStyle(fontSize: 12, color: Brand.muted)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        OutlinedButton.icon(key: const Key('multi-dup'), onPressed: duplicateSelection, icon: const Icon(Icons.copy_all, size: 16), label: const Text('Dupliquer')),
        OutlinedButton.icon(onPressed: () => copySelection(), icon: const Icon(Icons.content_copy, size: 16), label: const Text('Copier')),
        if (nm > 0) OutlinedButton(onPressed: () => rotateSelection(90), child: const Text('⟳ 90°')),
        if (nm > 1) ...[
          OutlinedButton(key: const Key('align-row'), onPressed: () => edit(() => alignIds(_els, _sel, 'y')), child: const Text('Aligner en ligne')),
          OutlinedButton(key: const Key('align-col'), onPressed: () => edit(() => alignIds(_els, _sel, 'x')), child: const Text('Aligner en colonne')),
        ],
        if (nm > 2) ...[
          OutlinedButton(onPressed: () => edit(() => distributeIds(_els, _sel, 'x')), child: const Text('Répartir ↔')),
          OutlinedButton(onPressed: () => edit(() => distributeIds(_els, _sel, 'y')), child: const Text('Répartir ↕')),
        ],
        FilledButton.tonal(
          key: const Key('multi-delete'),
          style: FilledButton.styleFrom(foregroundColor: Brand.danger),
          onPressed: deleteSelection,
          child: Text('Supprimer (${els.length})'),
        ),
      ]),
    ];
  }

  Widget _numField(String key, String label, Map<String, dynamic> e, String field, {double min = 0.05}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextFormField(
          key: ValueKey('$key-${e['id']}-${e[field]}'),
          initialValue: fmtNum(_n(e[field]), 2),
          decoration: InputDecoration(labelText: label, isDense: true),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onFieldSubmitted: (v) {
            final x = parseNum(v);
            if (x != null && x >= min) edit(() => e[field] = r2(x));
          },
        ),
      );

  List<Widget> _selection(Map<String, dynamic> e, List<int> stations) {
    final kind = e['kind'];
    final title = switch (kind) {
      'machine' => machineCatalog['${e['type']}']?.label ?? 'Machine',
      'wall' => 'Mur',
      'aisle' => 'Allée',
      'zone' => 'Zone',
      'pillar' => 'Poteau',
      'door' => 'Porte / issue',
      'dim' => 'Cote',
      'rail' => 'Convoyeur suspendu',
      _ => '$kind',
    };
    return [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy))),
        IconButton(key: const Key('el-dup'), tooltip: 'Dupliquer (Ctrl+D)', onPressed: duplicateSelection, icon: const Icon(Icons.copy_all_outlined)),
        IconButton(
          key: const Key('el-delete'),
          tooltip: 'Supprimer (Suppr)',
          onPressed: deleteSelection,
          icon: const Icon(Icons.delete_outline, color: Brand.danger),
        ),
      ]),
      if (kind == 'machine' || kind == 'door')
        Wrap(spacing: 6, runSpacing: 6, children: [
          OutlinedButton.icon(key: const Key('el-rotate'), onPressed: () => rotateSelection(90), icon: const Icon(Icons.rotate_right), label: const Text('90°')),
          OutlinedButton(onPressed: () => rotateSelection(15), child: const Text('+15°')),
          OutlinedButton(onPressed: () => rotateSelection(-15), child: const Text('−15°')),
        ]),
      const SizedBox(height: 8),
      if (kind == 'machine') ...[
        TextFormField(
          key: ValueKey('label-${e['id']}'),
          initialValue: '${e['label'] ?? ''}',
          decoration: const InputDecoration(labelText: 'Repère (n° de machine / poste)'),
          onFieldSubmitted: (v) => edit(() => e['label'] = v.trim()),
          onChanged: (v) {
            e['label'] = v;
            _dirty = true;
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('status-${e['id']}'),
          initialValue: const ['service', 'panne', 'reserve'].contains(e['status']) ? '${e['status']}' : 'service',
          decoration: const InputDecoration(labelText: 'État'),
          items: const [
            DropdownMenuItem(value: 'service', child: Text('En service')),
            DropdownMenuItem(value: 'panne', child: Text('En panne')),
            DropdownMenuItem(value: 'reserve', child: Text('Réserve')),
          ],
          onChanged: (v) => edit(() => e['status'] = v ?? 'service'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('op-${e['id']}'),
          initialValue: const ['front', 'back', 'left', 'right'].contains(e['operator']) ? '${e['operator']}' : 'front',
          decoration: const InputDecoration(labelText: 'Côté opératrice'),
          items: const [
            DropdownMenuItem(value: 'front', child: Text('Devant')),
            DropdownMenuItem(value: 'back', child: Text('Derrière')),
            DropdownMenuItem(value: 'left', child: Text('À gauche')),
            DropdownMenuItem(value: 'right', child: Text('À droite')),
          ],
          onChanged: (v) => edit(() => e['operator'] = v ?? 'front'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const Key('el-station'),
          initialValue: stations.map((x) => '$x').contains('${e['ws_id'] ?? ''}') ? '${e['ws_id']}' : '',
          decoration: const InputDecoration(labelText: 'Station liée (calcul lié)'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Automatique')),
            for (final s in stations) DropdownMenuItem(value: '$s', child: Text('Station $s')),
          ],
          onChanged: (v) => edit(() {
            if (v == null || v.isEmpty) {
              e.remove('ws_id');
            } else {
              e['ws_id'] = v;
            }
          }),
        ),
        const SizedBox(height: 8),
        _numField('mw', 'Largeur (m)', e, 'w', min: 0.2),
        _numField('md', 'Profondeur (m)', e, 'd', min: 0.2),
        Text('Rotation ${fmtNum(_n(e['rot']), 0)}° · x ${fmtNum(_n(e['x']), 2)}, y ${fmtNum(_n(e['y']), 2)}', style: const TextStyle(color: Brand.muted, fontSize: 12)),
      ],
      if (kind == 'wall') ...[
        _numField('wt', 'Épaisseur (m)', e, 'thickness'),
        Text('Longueur ${frNum(_dist((_n(e['x1']), _n(e['y1'])), (_n(e['x2']), _n(e['y2']))))} m', style: const TextStyle(color: Brand.muted, fontSize: 12)),
      ],
      if (kind == 'pillar') ...[_numField('pw', 'Largeur (m)', e, 'w'), _numField('pd', 'Profondeur (m)', e, 'd')],
      if (kind == 'door') ...[
        _numField('dw', 'Largeur (m)', e, 'width', min: 0.6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Issue de secours'),
          value: e['exit'] == true,
          onChanged: (v) => edit(() => e['exit'] = v),
        ),
      ],
      if (kind == 'aisle') ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allée principale'),
          value: e['main'] == true,
          onChanged: (v) => edit(() => e['main'] = v),
        ),
        _numField('aw', 'Largeur (m)', e, 'w', min: 0.2),
        _numField('ah', 'Longueur (m)', e, 'h', min: 0.2),
      ],
      if (kind == 'zone') ...[
        DropdownButtonFormField<String>(
          key: ValueKey('zone-${e['id']}'),
          initialValue: workshopZones.containsKey(e['zone']) ? '${e['zone']}' : 'montage',
          decoration: const InputDecoration(labelText: 'Type de zone'),
          items: [for (final z in workshopZones.entries) DropdownMenuItem(value: z.key, child: Text(z.value))],
          onChanged: (v) => edit(() {
            e['zone'] = v;
            e['name'] = workshopZones[v];
          }),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('zname-${e['id']}'),
          initialValue: '${e['name'] ?? ''}',
          decoration: const InputDecoration(labelText: 'Nom affiché'),
          onFieldSubmitted: (v) => edit(() => e['name'] = v.trim()),
        ),
      ],
      if (kind == 'rail') ...[
        TextFormField(
          key: ValueKey('rlabel-${e['id']}'),
          initialValue: '${e['label'] ?? ''}',
          decoration: const InputDecoration(labelText: 'Libellé'),
          onFieldSubmitted: (v) => edit(() => e['label'] = v.trim()),
        ),
        const SizedBox(height: 8),
        _numField('rh', 'Hauteur (m)', e, 'height', min: 1),
        Text('Longueur de boucle ${frNum(railLength(e), 1)} m · ${ptsOf(e).length} angles', style: const TextStyle(color: Brand.muted, fontSize: 12)),
      ],
      if (kind == 'dim') Text(dimText(e) + (e['note'] == null ? '' : ' · ${e['note']}'), style: const TextStyle(fontWeight: FontWeight.w600)),
    ];
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.plan,
    required this.view,
    this.selected = const {},
    this.issueIds = const {},
    required this.layers,
    this.machineStation = const {},
    this.background,
    this.draft,
    this.handles = const [],
    this.marquee,
    this.hover,
    this.hoverDanger = false,
    this.measurePts = const [],
    this.measureCursor,
    this.liveDim,
    this.doneDim,
    this.walkA,
    this.railPts = const [],
    this.calib = const [],
    this.gridStep,
  });
  final Map<String, dynamic> plan;
  final PlanView view;
  final Set<String> selected;
  final Set<String> issueIds;
  final LayerState layers;
  final Map<String, String> machineStation;
  final ui.Image? background;
  final (PlanTool, P, P, bool)? draft;
  final List<PlanHandle> handles;
  final (P, P)? marquee;
  final Map? hover;
  final bool hoverDanger;
  final List<P> measurePts;
  final ({P p, bool snapped})? measureCursor;
  final Map<String, dynamic>? liveDim;
  final Map<String, dynamic>? doneDim;
  final Map? walkA;
  final List<P> railPts;
  final List<P> calib;
  final double? gridStep;

  Offset _px(P p) => view.toPx(p.$1, p.$2);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF1F5F9));
    paintPlan(canvas, plan, view,
        selectedIds: selected, issueIds: issueIds, visible: layers.visible, machineStation: machineStation, background: background, gridStep: gridStep);
    // sélection multiple : contour pointillé de chaque élément
    final selPaint = Paint()
      ..color = const Color(0xFF2F6EA5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (selected.length > 1) {
      for (final e in planElements(plan)) {
        if (!selected.contains(e['id'])) continue;
        final path = Path()..addPolygon([for (final p in elPoly(e)) _px(p)], true);
        canvas.drawPath(path, Paint()..color = const Color(0x142F6EA5));
        canvas.drawPath(path, selPaint);
      }
    }
    final h = hover;
    if (h != null) {
      final path = Path()..addPolygon([for (final p in elPoly(h)) _px(p)], true);
      final c = hoverDanger ? Brand.danger : Brand.ok;
      canvas.drawPath(path, Paint()..color = c.withValues(alpha: 0.15));
      canvas.drawPath(path, Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5);
    }
    final wa = walkA;
    if (wa != null) {
      canvas.drawPath(Path()..addPolygon([for (final p in elPoly(wa)) _px(p)], true), Paint()
        ..color = Brand.ok
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
    }
    // poignées
    for (final hd in handles) {
      final c = _px(hd.p);
      if (hd.kind == HandleKind.rotate) {
        canvas.drawCircle(c, 7, Paint()..color = Colors.white);
        canvas.drawCircle(c, 7, selPaint..strokeWidth = 2);
      } else {
        canvas.drawRect(Rect.fromCenter(center: c, width: 11, height: 11), Paint()..color = const Color(0xFF2F6EA5));
        canvas.drawRect(Rect.fromCenter(center: c, width: 11, height: 11), Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke);
      }
    }
    final mq = marquee;
    if (mq != null) {
      final r = Rect.fromPoints(_px(mq.$1), _px(mq.$2));
      canvas.drawRect(r, Paint()..color = const Color(0x142F6EA5));
      canvas.drawRect(r, selPaint..strokeWidth = 1.5);
    }
    // mesure
    if (liveDim != null) paintDim(canvas, liveDim!, view, temp: true);
    if (doneDim != null) paintDim(canvas, doneDim!, view, temp: true);
    for (final p in measurePts) {
      canvas.drawCircle(_px(p), 5, Paint()..color = Brand.danger);
    }
    final mc = measureCursor;
    if (mc != null) {
      final c = _px(mc.p);
      canvas.drawCircle(c, mc.snapped ? 7 : 4, Paint()..color = mc.snapped ? Colors.white : Brand.danger);
      canvas.drawCircle(c, mc.snapped ? 7 : 4, Paint()
        ..color = Brand.danger
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
    // convoyeur en cours
    if (railPts.isNotEmpty) {
      final rp = Paint()
        ..color = const Color(0xFF7B4FA0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawPath(Path()..addPolygon([for (final p in railPts) _px(p)], false), rp);
      for (var i = 0; i < railPts.length; i++) {
        canvas.drawCircle(_px(railPts[i]), i == 0 ? 8 : 5, Paint()..color = i == 0 ? Colors.white : const Color(0xFF7B4FA0));
        if (i == 0) canvas.drawCircle(_px(railPts[i]), 8, rp..strokeWidth = 2);
      }
    }
    // tracé en cours (mur / allée / zone)
    final d = draft;
    if (d != null) {
      final (tool, a, b, shift) = d;
      var bb = b;
      if (tool == PlanTool.wall && shift) bb = (b.$1 - a.$1).abs() >= (b.$2 - a.$2).abs() ? (b.$1, a.$2) : (a.$1, b.$2);
      final pa = _px(a), pb = _px(bb);
      final p = Paint()
        ..color = Brand.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      final len = math.sqrt(math.pow(bb.$1 - a.$1, 2) + math.pow(bb.$2 - a.$2, 2));
      if (tool == PlanTool.wall) {
        canvas.drawLine(pa, pb, p..strokeWidth = 4);
        _label(canvas, '${frNum(len)} m', Offset.lerp(pa, pb, 0.5)! - const Offset(0, 12));
      } else {
        canvas.drawRect(Rect.fromPoints(pa, pb), Paint()..color = Brand.orange.withValues(alpha: 0.15));
        canvas.drawRect(Rect.fromPoints(pa, pb), p);
        _label(canvas, '${frNum((bb.$1 - a.$1).abs())} × ${frNum((bb.$2 - a.$2).abs())} m', Offset((pa.dx + pb.dx) / 2, math.min(pa.dy, pb.dy) - 10));
      }
    }
    for (final c in calib) {
      canvas.drawCircle(_px(c), 6, Paint()..color = Brand.danger);
    }
    if (calib.length == 2) {
      canvas.drawLine(_px(calib[0]), _px(calib[1]), Paint()
        ..color = Brand.danger
        ..strokeWidth = 1.5);
    }
    // échelle
    final m = view.scale >= 20 ? 1.0 : 5.0;
    final y = size.height - 14;
    canvas.drawLine(Offset(12, y), Offset(12 + m * view.scale, y), Paint()
      ..color = Brand.navy
      ..strokeWidth = 2);
    final tp = TextPainter(text: TextSpan(text: '${m.toInt()} m', style: const TextStyle(fontSize: 10, color: Brand.navy)), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(14, y - 14));
  }

  void _label(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: const TextStyle(fontSize: 11, color: Brand.navy, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromCenter(center: at, width: tp.width + 6, height: tp.height + 2);
    canvas.drawRect(r, Paint()..color = Colors.white.withValues(alpha: 0.85));
    tp.paint(canvas, r.topLeft + const Offset(3, 1));
  }

  @override
  bool shouldRepaint(covariant _EditorPainter old) => true;
}
