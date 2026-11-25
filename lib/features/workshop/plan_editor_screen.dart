/// Plan d'atelier : liste des plans et éditeur (grille, murs, allées, zones, poteaux, portes,
/// bibliothèque de machines, glisser-déposer, rotation, liaison machine ↔ station d'un calcul,
/// fond de plan importé et calibré par 2 points + distance réelle).
///
/// Enregistré sur l'appareil ; en ligne (mode cloud), synchronisé avec `/workshop-plans`
/// (le fond d'image reste local : le serveur range les fonds dans Supabase Storage).
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
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
enum PlanTool { select, machine, wall, aisle, zone, pillar, door, calibrate }

const _toolLabels = {
  PlanTool.select: ('Sélection', Icons.near_me_outlined),
  PlanTool.machine: ('Machine', Icons.precision_manufacturing_outlined),
  PlanTool.wall: ('Mur', Icons.horizontal_rule),
  PlanTool.aisle: ('Allée', Icons.signpost_outlined),
  PlanTool.zone: ('Zone', Icons.crop_square),
  PlanTool.pillar: ('Poteau', Icons.square),
  PlanTool.door: ('Porte', Icons.door_front_door_outlined),
};

class PlanEditorScreen extends StatefulWidget {
  const PlanEditorScreen({super.key, required this.planId});
  final String planId;

  @override
  State<PlanEditorScreen> createState() => _PlanEditorScreenState();
}

class _PlanEditorScreenState extends State<PlanEditorScreen> {
  Map<String, dynamic>? _plan;
  PlanTool _tool = PlanTool.select;
  String _machineType = 'piqueuse_plate';
  String _zoneType = 'montage';
  String? _selected;
  bool _dirty = false;
  bool _saving = false;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  // geste en cours
  (double, double)? _start;
  (double, double)? _current;
  (double, double)? _last;
  bool _panning = false;
  // fond
  ui.Image? _bg;
  final _calib = <(double, double)>[];
  // calcul lié (stations)
  String? _runId;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final p = s.repo.plan(widget.planId);
    if (p != null) _plan = _deepCopy(p);
    final runs = _runs(s);
    _runId = (_plan?['settings'] as Map?)?['run_id'] as String?;
    if (_runId != null && !runs.any((r) => r.id == _runId)) _runId = null;
    _runId ??= runs.isEmpty ? null : runs.first.id;
    _decodeBackground();
  }

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

  List<Map<String, dynamic>> get _els => (_plan!['elements'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic>? get _sel {
    for (final e in _els) {
      if (e['id'] == _selected) return e;
    }
    return null;
  }

  double get _grid => _n((_plan!['settings'] as Map?)?['grid_m'], 0.5);

  void _changed() => setState(() => _dirty = true);

  String _newId(String kind) {
    var i = _els.length + 1;
    final ids = {for (final e in _els) e['id']};
    while (ids.contains('$kind$i')) {
      i++;
    }
    return '$kind$i';
  }

  PlanView _view(Size size) {
    final base = PlanView.fit(size, planBounds(_plan!), margin: 20);
    final c = Offset(size.width, size.height) / 2;
    return PlanView(c + (base.origin - c) * _zoom + _pan, base.scale * _zoom);
  }

  // ------------------------------------------------------------------ gestes
  void _onTap(Size size, Offset p) {
    final v = _view(size);
    final (x, y) = v.toM(p);
    final g = _grid;
    switch (_tool) {
      case PlanTool.select:
        String? hit;
        for (final e in _els.reversed) {
          if (elementContains(e, x, y)) {
            hit = '${e['id']}';
            break;
          }
        }
        setState(() => _selected = hit);
      case PlanTool.machine:
        final m = newMachine(_newId('m'), _machineType, snap(x, g), snap(y, g));
        _els.add(m);
        _selected = '${m['id']}';
        _changed();
      case PlanTool.pillar:
        _els.add({'id': _newId('p'), 'kind': 'pillar', 'x': snap(x, g), 'y': snap(y, g), 'w': 0.4, 'd': 0.4});
        _changed();
      case PlanTool.door:
        _els.add({'id': _newId('d'), 'kind': 'door', 'x': snap(x, g), 'y': snap(y, g), 'width': 1.2, 'rot': 0, 'exit': false});
        _changed();
      case PlanTool.calibrate:
        _calib.add((x, y));
        if (_calib.length == 2) _finishCalibration();
        setState(() {});
      default:
        break;
    }
  }

  void _onPanStart(Size size, Offset p) {
    final v = _view(size);
    final (x, y) = v.toM(p);
    _start = (x, y);
    _current = (x, y);
    _last = (x, y);
    _panning = false;
    if (_tool == PlanTool.select) {
      final sel = _sel;
      if (sel == null || !elementContains(sel, x, y)) {
        String? hit;
        for (final e in _els.reversed) {
          if (elementContains(e, x, y)) {
            hit = '${e['id']}';
            break;
          }
        }
        if (hit == null) {
          _panning = true; // glisser le fond = déplacer la vue
        }
        setState(() => _selected = hit);
      }
    }
  }

  void _onPanUpdate(Size size, DragUpdateDetails d) {
    if (_panning) {
      setState(() => _pan += d.delta);
      return;
    }
    final v = _view(size);
    final (x, y) = v.toM(d.localPosition);
    if (_tool == PlanTool.select && _sel != null && _last != null) {
      moveElement(_sel!, x - _last!.$1, y - _last!.$2);
      _last = (x, y);
      _changed();
      return;
    }
    setState(() => _current = (x, y));
  }

  void _onPanEnd() {
    final g = _grid;
    final a = _start, b = _current;
    if (_tool == PlanTool.select && _sel != null && !_panning) {
      final e = _sel!;
      if (e['kind'] != 'wall') {
        e['x'] = pyRound(snap(_n(e['x']), g / 2), 2);
        e['y'] = pyRound(snap(_n(e['y']), g / 2), 2);
      }
    } else if (a != null && b != null && (a.$1 - b.$1).abs() + (a.$2 - b.$2).abs() > 0.2) {
      final x0 = snap(a.$1 < b.$1 ? a.$1 : b.$1, g), y0 = snap(a.$2 < b.$2 ? a.$2 : b.$2, g);
      final x1 = snap(a.$1 > b.$1 ? a.$1 : b.$1, g), y1 = snap(a.$2 > b.$2 ? a.$2 : b.$2, g);
      switch (_tool) {
        case PlanTool.wall:
          // mur droit : horizontal ou vertical selon le geste dominant
          final horiz = (b.$1 - a.$1).abs() >= (b.$2 - a.$2).abs();
          _els.add({
            'id': _newId('w'),
            'kind': 'wall',
            'x1': snap(a.$1, g),
            'y1': snap(a.$2, g),
            'x2': snap(horiz ? b.$1 : a.$1, g),
            'y2': snap(horiz ? a.$2 : b.$2, g),
            'thickness': 0.2,
          });
        case PlanTool.aisle:
          _els.add({'id': _newId('a'), 'kind': 'aisle', 'x': x0, 'y': y0, 'w': (x1 - x0).clamp(0.5, 400), 'h': (y1 - y0).clamp(0.5, 400), 'main': false});
        case PlanTool.zone:
          _els.add({
            'id': _newId('z'),
            'kind': 'zone',
            'x': x0,
            'y': y0,
            'w': (x1 - x0).clamp(0.5, 400),
            'h': (y1 - y0).clamp(0.5, 400),
            'zone': _zoneType,
            'name': workshopZones[_zoneType],
          });
        default:
          break;
      }
      _dirty = true;
    }
    setState(() {
      _start = null;
      _current = null;
      _last = null;
      _panning = false;
    });
  }

  // ------------------------------------------------------------------ fond de plan
  Future<void> _importBackground() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final bytes = res?.files.single.bytes;
    if (bytes == null) return;
    if (bytes.length > 3 * 1024 * 1024) {
      if (mounted) showSnack(context, 'Image trop lourde (3 Mo maximum).', error: true);
      return;
    }
    await _setBackground(bytes);
  }

  Future<void> _setBackground(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    // échelle initiale : l'image couvre la largeur de la salle ; à calibrer ensuite
    final mpp = _n(_plan!['width_m'], 30) / img.width;
    setState(() {
      _bg = img;
      _plan!['background_local'] = {'data': base64Encode(bytes), 'm_per_px': mpp, 'x': 0.0, 'y': 0.0};
      _tool = PlanTool.calibrate;
      _calib.clear();
      _dirty = true;
    });
    if (mounted) showSnack(context, 'Calibration : touchez 2 points du plan dont vous connaissez la distance réelle.');
  }

  Future<void> _finishCalibration() async {
    final a = _calib[0], b = _calib[1];
    final bg = _plan!['background_local'] as Map?;
    final txt = await promptText(context, 'Distance réelle', label: 'Distance entre les 2 points (m)');
    final real = parseNum(txt ?? '');
    setState(() {
      _calib.clear();
      _tool = PlanTool.select;
    });
    if (real == null || real <= 0 || bg == null) return;
    // mètres mesurés à l'échelle actuelle → nouvelle échelle du fond
    final measured = calibrationScale(a, b, 1); // = 1 / distance mesurée (m)
    final factor = real * measured;
    setState(() {
      bg['m_per_px'] = _n(bg['m_per_px']) * factor;
      if (_bg != null) {
        _plan!['width_m'] = pyRound((_bg!.width * _n(bg['m_per_px'])).clamp(2, 400), 1);
        _plan!['length_m'] = pyRound((_bg!.height * _n(bg['m_per_px'])).clamp(2, 400), 1);
      }
      _dirty = true;
    });
    if (mounted) showSnack(context, 'Plan calibré : ${fmtNum(_n(_plan!['width_m']), 1)} × ${fmtNum(_n(_plan!['length_m']), 1)} m.');
  }

  // ------------------------------------------------------------------ enregistrement
  Future<void> _save() async {
    final s = context.read<AppState>();
    setState(() => _saving = true);
    (_plan!['settings'] as Map)['run_id'] = _runId;
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
    _plan!['width_m'] = wv.clamp(2, 400);
    _plan!['length_m'] = lv.clamp(2, 400);
    _changed();
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
    final canvas = _canvas(machineStation);
    final panel = _panel(stations, runs);
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
            IconButton(tooltip: 'Importer un fond de plan (image)', onPressed: _importBackground, icon: const Icon(Icons.image_outlined)),
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
          for (final e in _toolLabels.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                key: Key('tool-${e.key.name}'),
                avatar: Icon(e.value.$2, size: 16),
                label: Text(e.value.$1),
                selected: _tool == e.key,
                onSelected: (_) => setState(() {
                  _tool = e.key;
                  _calib.clear();
                }),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Zoom +', onPressed: () => setState(() => _zoom = (_zoom * 1.25).clamp(0.3, 8)), icon: const Icon(Icons.zoom_in)),
          IconButton(tooltip: 'Zoom −', onPressed: () => setState(() => _zoom = (_zoom / 1.25).clamp(0.3, 8)), icon: const Icon(Icons.zoom_out)),
          IconButton(
            tooltip: 'Recentrer',
            onPressed: () => setState(() {
              _zoom = 1;
              _pan = Offset.zero;
            }),
            icon: const Icon(Icons.center_focus_strong),
          ),
        ]),
      );

  Widget _canvas(Map<String, String> machineStation) => LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) setState(() => _zoom = (_zoom * (e.scrollDelta.dy > 0 ? 0.9 : 1.1)).clamp(0.3, 8));
          },
          child: GestureDetector(
            onTapUp: (d) => _onTap(size, d.localPosition),
            onPanStart: (d) => _onPanStart(size, d.localPosition),
            onPanUpdate: (d) => _onPanUpdate(size, d),
            onPanEnd: (_) => _onPanEnd(),
            child: ClipRect(
              child: CustomPaint(
                key: const Key('plan-canvas'),
                size: size,
                painter: _EditorPainter(
                  plan: _plan!,
                  view: _view(size),
                  selected: _selected,
                  machineStation: machineStation,
                  background: _bg,
                  draft: _start != null && _current != null && _tool != PlanTool.select ? (_tool, _start!, _current!) : null,
                  calib: List.of(_calib),
                ),
              ),
            ),
          ),
        );
      });

  Widget _panel(List<int> stations, List<RunRecord> runs) {
    final sel = _sel;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_tool == PlanTool.machine) ...[
        const Text('Bibliothèque de machines', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const Key('machine-type'),
          initialValue: _machineType,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Type de machine (touchez le plan pour poser)'),
          items: [
            for (final m in machineCatalog.values)
              DropdownMenuItem(value: m.type, child: Text('${m.label} (${fmtNum(m.w, 2)}×${fmtNum(m.d, 2)} m)', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _machineType = v ?? _machineType),
        ),
        const SizedBox(height: 12),
      ],
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
      if (_tool == PlanTool.wall || _tool == PlanTool.aisle)
        Notice(_tool == PlanTool.wall ? 'Glissez pour tracer un mur (droit).' : 'Glissez pour tracer une allée.'),
      if (_tool == PlanTool.calibrate)
        Notice('Calibration du fond : touchez 2 points (${_calib.length}/2) puis indiquez leur distance réelle.', kind: 'warn'),
      if (sel != null) ..._selection(sel, stations) else if (_tool == PlanTool.select)
        const Text('Touchez un élément pour le sélectionner ; glissez-le pour le déplacer. Glisser le fond déplace la vue.',
            style: TextStyle(color: Brand.muted)),
      const SizedBox(height: 16),
      const Text('Calcul lié', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
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
      if ((_plan!['background_local']) != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 4, children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _tool = PlanTool.calibrate;
                _calib.clear();
              }),
              icon: const Icon(Icons.straighten, size: 18),
              label: const Text('Calibrer le fond'),
            ),
            TextButton.icon(
              onPressed: () => setState(() {
                _plan!.remove('background_local');
                _bg = null;
                _dirty = true;
              }),
              icon: const Icon(Icons.hide_image_outlined, size: 18),
              label: const Text('Retirer le fond'),
            ),
          ]),
        ),
    ]);
  }

  List<Widget> _selection(Map<String, dynamic> e, List<int> stations) {
    final kind = e['kind'];
    final title = switch (kind) {
      'machine' => machineCatalog['${e['type']}']?.label ?? 'Machine',
      'wall' => 'Mur',
      'aisle' => 'Allée',
      'zone' => 'Zone',
      'pillar' => 'Poteau',
      'door' => 'Porte',
      _ => '$kind',
    };
    return [
      Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy))),
        IconButton(
          key: const Key('el-delete'),
          tooltip: 'Supprimer',
          onPressed: () {
            _els.removeWhere((x) => x['id'] == e['id']);
            _selected = null;
            _changed();
          },
          icon: const Icon(Icons.delete_outline, color: Brand.danger),
        ),
      ]),
      if (kind == 'machine') ...[
        Wrap(spacing: 6, runSpacing: 6, children: [
          OutlinedButton.icon(
            key: const Key('el-rotate'),
            onPressed: () {
              e['rot'] = ((_n(e['rot']) + 90) % 360).round();
              _changed();
            },
            icon: const Icon(Icons.rotate_right),
            label: const Text('90°'),
          ),
          OutlinedButton(
            onPressed: () {
              e['rot'] = ((_n(e['rot']) + 15) % 360).round();
              _changed();
            },
            child: const Text('+15°'),
          ),
        ]),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('label-${e['id']}'),
          initialValue: '${e['label'] ?? ''}',
          decoration: const InputDecoration(labelText: 'Repère (n° de machine / poste)'),
          onChanged: (v) {
            e['label'] = v;
            _dirty = true;
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: '${e['status'] ?? 'service'}',
          decoration: const InputDecoration(labelText: 'État'),
          items: const [
            DropdownMenuItem(value: 'service', child: Text('En service')),
            DropdownMenuItem(value: 'panne', child: Text('En panne')),
            DropdownMenuItem(value: 'reserve', child: Text('Réserve')),
          ],
          onChanged: (v) {
            e['status'] = v ?? 'service';
            _changed();
          },
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
          onChanged: (v) {
            if (v == null || v.isEmpty) {
              e.remove('ws_id');
            } else {
              e['ws_id'] = v;
            }
            _changed();
          },
        ),
        Text('Rotation ${fmtNum(_n(e['rot']), 0)}° · ${fmtNum(_n(e['w']), 2)} × ${fmtNum(_n(e['d']), 2)} m · x ${fmtNum(_n(e['x']), 2)}, y ${fmtNum(_n(e['y']), 2)}',
            style: const TextStyle(color: Brand.muted, fontSize: 12)),
      ],
      if (kind == 'aisle')
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allée principale'),
          value: e['main'] == true,
          onChanged: (v) {
            e['main'] = v;
            _changed();
          },
        ),
      if (kind == 'zone')
        DropdownButtonFormField<String>(
          initialValue: workshopZones.containsKey(e['zone']) ? '${e['zone']}' : 'montage',
          decoration: const InputDecoration(labelText: 'Type de zone'),
          items: [for (final z in workshopZones.entries) DropdownMenuItem(value: z.key, child: Text(z.value))],
          onChanged: (v) {
            e['zone'] = v;
            e['name'] = workshopZones[v];
            _changed();
          },
        ),
    ];
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.plan,
    required this.view,
    this.selected,
    this.machineStation = const {},
    this.background,
    this.draft,
    this.calib = const [],
  });
  final Map<String, dynamic> plan;
  final PlanView view;
  final String? selected;
  final Map<String, String> machineStation;
  final ui.Image? background;
  final (PlanTool, (double, double), (double, double))? draft;
  final List<(double, double)> calib;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF1F5F9));
    paintPlan(canvas, plan, view, selectedId: selected, machineStation: machineStation, background: background);
    final d = draft;
    if (d != null) {
      final (tool, a, b) = d;
      final pa = view.toPx(a.$1, a.$2), pb = view.toPx(b.$1, b.$2);
      final p = Paint()
        ..color = Brand.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      if (tool == PlanTool.wall) {
        final horiz = (b.$1 - a.$1).abs() >= (b.$2 - a.$2).abs();
        canvas.drawLine(pa, horiz ? Offset(pb.dx, pa.dy) : Offset(pa.dx, pb.dy), p..strokeWidth = 4);
      } else {
        canvas.drawRect(Rect.fromPoints(pa, pb), p);
      }
    }
    for (final c in calib) {
      canvas.drawCircle(view.toPx(c.$1, c.$2), 6, Paint()..color = Brand.danger);
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

  @override
  bool shouldRepaint(covariant _EditorPainter old) => true;
}
