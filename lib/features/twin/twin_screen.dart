/// Jumeau numérique 2D d'un calcul : ligne animée (postes, paquets, encours, goulot, ouvrières),
/// dispositions ligne / U / libre / plan d'atelier, lecture / pause / vitesse, indicateurs,
/// 3 scénarios « et si » comparés, réel vs simulé quand une session de production existe.
///
/// Hors ligne : moteur Dart (`engine/twin.dart`). En ligne (mode cloud, calcul synchronisé) :
/// `POST /v1/orgs/{org}/runs/{id}/simulate` puis lecture du résultat — même format.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'twin_painter.dart';

class TwinScreen extends StatefulWidget {
  const TwinScreen({super.key, required this.runId});
  final String runId;

  @override
  State<TwinScreen> createState() => _TwinScreenState();
}

class _TwinScreenState extends State<TwinScreen> with SingleTickerProviderStateMixin {
  RunRecord? _run;
  Map<String, dynamic>? _plan;
  String _kind = 'line';
  Map<String, dynamic> _free = {};
  String? _planDocId;
  Map<String, dynamic> _assignment = {};
  late List<Map<String, dynamic>> _scenarios;
  Map<String, dynamic>? _results;
  String _source = 'local';
  int _shown = 0;
  bool _busy = false;
  String? _progress;
  bool _useApi = true;

  // animation
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  bool _playing = false;
  double _t = 0;
  double _speed = 10; // minutes simulées par seconde
  TwinTrace? _trace;
  int? _dragging;

  // réel vs simulé
  String? _sessionId;
  Map<String, dynamic>? _sync;
  String? _syncSource;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    final s = context.read<AppState>();
    _run = s.repo.run(widget.runId);
    final b = _run?.balance;
    _scenarios = [twinScenario(name: 'Référence')];
    if (_run == null || b == null || b.stationDetails.isEmpty) return;
    _plan = twinPlan(b, _run!.problem);
    final saved = s.repo.runLayout(_run!.id);
    if (saved != null) {
      _kind = (saved['local_plan_id'] != null && s.repo.plan('${saved['local_plan_id']}') != null)
          ? 'plan'
          : ('${saved['kind'] ?? 'line'}');
      if (_kind == 'plan') {
        _planDocId = '${saved['local_plan_id']}';
        _assignment = ((saved['assignment'] as Map?) ?? const {}).cast<String, dynamic>();
      }
      _free = ((saved['positions'] as Map?) ?? const {}).cast<String, dynamic>();
    } else if (s.workshopPlans.isNotEmpty) {
      // un plan d'atelier existe : le jumeau l'utilise par défaut
      _kind = 'plan';
      _planDocId = '${s.workshopPlans.first['id']}';
    }
    _simulateLocal();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ implantation
  Map<String, dynamic>? get _planDoc => _planDocId == null ? null : context.read<AppState>().repo.plan(_planDocId!);

  Map<String, dynamic> get _layout {
    final plan = _plan!;
    if (_kind == 'plan') {
      final doc = _planDoc;
      if (doc != null) return planLayout(plan['stations'] as List, doc, _assignment);
    }
    if (_kind == 'free') {
      return layoutFor(plan, {'kind': 'free', 'positions': _free.isEmpty ? defaultLayout(stationOrder(plan))['positions'] : _free});
    }
    return layoutFor(plan, {'kind': _kind});
  }

  Future<void> _setKind(String k) async {
    final s = context.read<AppState>();
    if (k == 'plan' && s.workshopPlans.isEmpty) {
      showSnack(context, "Aucun plan d'atelier : créez-en un dans « Plan d'atelier ».", error: true);
      return;
    }
    setState(() {
      if (k == 'free' && _free.isEmpty) _free = Map.of(_layout['positions'] as Map<String, dynamic>);
      _kind = k;
      if (k == 'plan') _planDocId ??= '${s.workshopPlans.first['id']}';
    });
    await _saveLayout();
    _simulateLocal();
  }

  Future<void> _saveLayout() async {
    final lay = _layout;
    final doc = {
      'kind': _kind == 'plan' ? 'free' : _kind,
      'positions': lay['positions'],
      if (_kind == 'plan') 'local_plan_id': _planDocId,
      if (_kind == 'plan') 'assignment': lay['assignment'],
    };
    final err = await context.read<AppState>().saveRunLayout(_run!, doc);
    if (err != null && mounted) showSnack(context, 'Implantation enregistrée sur l\'appareil (serveur : $err)');
  }

  // ------------------------------------------------------------------ simulation
  void _simulateLocal() {
    if (_plan == null) return;
    final res = runTwinScenarios(_plan!, _layout, _scenarios);
    _setResults(res, 'local');
  }

  void _setResults(Map<String, dynamic> res, String source) {
    setState(() {
      _results = res;
      _source = source;
      _shown = _shown.clamp(0, (res['scenarios'] as List).length - 1);
      _trace = TwinTrace(_current!);
      _t = 0;
      _playing = false;
      _ticker.stop();
    });
  }

  Map<String, dynamic>? get _current {
    final sc = (_results?['scenarios'] as List?) ?? const [];
    if (sc.isEmpty) return null;
    return ((sc[_shown.clamp(0, sc.length - 1)] as Map)['result'] as Map).cast<String, dynamic>();
  }

  bool get _apiAvailable {
    final s = context.read<AppState>();
    return s.cloudAvailable && _run?.cloudId != null;
  }

  Future<void> _simulate() async {
    if (_apiAvailable && _useApi) {
      final s = context.read<AppState>();
      setState(() {
        _busy = true;
        _progress = 'Envoi au serveur…';
      });
      try {
        final lay = _layout;
        final planCloud = _kind == 'plan' ? (_planDoc?['cloud_id']) : null;
        final body = planCloud != null
            ? {'plan_id': planCloud, 'assignment': lay['assignment']}
            : {'kind': _kind == 'plan' ? 'free' : _kind, 'positions': lay['positions']};
        final row = await s.api.simulateTwin(s.workshop!.id, _run!.cloudId!, _scenarios, layout: body);
        if (mounted) setState(() => _progress = 'Simulation en cours sur le serveur…');
        final sim = await s.api.waitSimulation(s.workshop!.id, '${row['id']}');
        if (!mounted) return;
        _setResults(((sim['results'] as Map?) ?? const {}).cast<String, dynamic>(), 'api');
      } on ApiException catch (e) {
        if (mounted) {
          showSnack(context, 'Serveur indisponible, simulation locale : ${e.message}', error: true);
          _simulateLocal();
        }
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
            _progress = null;
          });
        }
      }
    } else {
      _simulateLocal();
    }
  }

  // ------------------------------------------------------------------ animation
  void _onTick(Duration d) {
    final dt = (d - _lastTick).inMicroseconds / 1e6;
    _lastTick = d;
    final end = ((_current?['shift_minutes'] ?? 480) as num).toDouble();
    setState(() {
      _t = (_t + dt * _speed).clamp(0, end);
      if (_t >= end) {
        _playing = false;
        _ticker.stop();
      }
    });
  }

  void _toggle() {
    setState(() {
      _playing = !_playing;
      if (_playing) {
        final end = ((_current?['shift_minutes'] ?? 480) as num).toDouble();
        if (_t >= end) _t = 0;
        _lastTick = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    });
  }

  // ------------------------------------------------------------------ réel vs simulé
  Future<void> _compareReal(SessionRecord sess) async {
    final s = context.read<AppState>();
    setState(() {
      _sessionId = sess.id;
      _sync = null;
    });
    final bundle = ((_scenarios.first['bundle_size'] ?? 10) as num).toInt();
    if (s.cloudAvailable && sess.cloudId != null && _run?.cloudId != null) {
      try {
        final r = await s.api.twinSync(s.workshop!.id, _run!.cloudId!, sess.cloudId!, bundleSize: bundle);
        if (mounted) {
          setState(() {
            _sync = r;
            _syncSource = 'api';
          });
        }
        return;
      } on ApiException catch (e) {
        if (mounted) showSnack(context, 'Serveur : ${e.message} — calcul local.', error: true);
      }
    }
    final plan = sess.plan['stations'] is List && (sess.plan['stations'] as List).isNotEmpty
        ? twinPlan(_run!.balance!, _run!.problem, sess.plan)
        : _plan!;
    final res = twinSync(s.dashboardFor(sess), plan, _layout, bundleSize: bundle);
    if (mounted) {
      setState(() {
        _sync = res;
        _syncSource = 'local';
      });
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final r = _run;
    if (r == null || _plan == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Jumeau numérique')),
        body: const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable ou sans répartition des stations.'),
      );
    }
    final res = _current;
    final phone = isPhone(context);
    return Scaffold(
      appBar: AppBar(title: Text('Jumeau numérique — ${r.problem.name}', overflow: TextOverflow.ellipsis)),
      body: PageScaffold(
        title: 'Jumeau numérique 2D',
        subtitle: 'Cadence ${fmtNum(r.balance!.actualCycleTime, 3)} min · ${r.balance!.stationsUsed} stations · '
            '${_source == 'api' ? 'simulation serveur (API)' : 'simulation locale'}',
        actions: [
          if (_apiAvailable)
            FilterChip(
              key: const Key('twin-api'),
              label: const Text('Serveur'),
              avatar: const Icon(Icons.cloud_outlined, size: 16),
              selected: _useApi,
              onSelected: (v) => setState(() => _useApi = v),
            ),
          FilledButton.icon(
            key: const Key('twin-simulate'),
            onPressed: _busy ? null : _simulate,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_circle_outline),
            label: const Text('Simuler'),
          ),
        ],
        children: [
          if (_progress != null) Notice(_progress!),
          _layoutBar(s, phone),
          if (res != null) _kpis(res),
          if (res != null) _animation(res, phone),
          _scenarioEditor(),
          if ((_results?['scenarios'] as List?)?.isNotEmpty ?? false) _comparison(),
          if (res != null) _notes(res),
          _realVsSim(s),
        ],
      ),
    );
  }

  Widget _layoutBar(AppState s, bool phone) => Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<String>(
          key: const Key('twin-layout'),
          segments: [
            ButtonSegment(value: 'line', label: const Text('Ligne'), icon: phone ? null : const Icon(Icons.linear_scale)),
            ButtonSegment(value: 'u', label: const Text('U'), icon: phone ? null : const Icon(Icons.u_turn_left)),
            ButtonSegment(value: 'free', label: const Text('Libre'), icon: phone ? null : const Icon(Icons.open_with)),
            ButtonSegment(value: 'plan', label: const Text('Plan'), icon: phone ? null : const Icon(Icons.map_outlined)),
          ],
          selected: {_kind},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _setKind(v.first),
        ),
        if (_kind == 'plan' && s.workshopPlans.length > 1)
          DropdownButton<String>(
            value: _planDocId,
            items: [for (final p in s.workshopPlans) DropdownMenuItem(value: '${p['id']}', child: Text('${p['name']}'))],
            onChanged: (v) async {
              setState(() {
                _planDocId = v;
                _assignment = {};
              });
              await _saveLayout();
              _simulateLocal();
            },
          ),
        if (_kind == 'free') const Text('Glissez les postes pour les déplacer.', style: TextStyle(color: Brand.muted, fontSize: 12)),
      ]);

  Widget _kpis(Map<String, dynamic> res) {
    final ws = (res['workers'] as List? ?? const []).cast<Map>();
    final util = ws.isEmpty ? null : ws.fold<double>(0, (a, w) => a + (w['utilization_pct'] as num).toDouble()) / ws.length;
    return KpiGrid(children: [
      KpiCard(label: 'Production / h', value: fmtNum(res['per_hour'] as num?, 1), icon: Icons.speed),
      KpiCard(label: 'Pièces / jour', value: '${res['pieces'] ?? '—'}', icon: Icons.checkroom),
      KpiCard(label: 'Encours moyen', value: fmtNum(res['wip_avg'] as num?, 1), sub: 'max ${res['wip_max'] ?? '—'} pièces', icon: Icons.inventory_2_outlined),
      KpiCard(label: 'Traversée', value: fmtMin(res['lead_time_min'] as num?, 0), icon: Icons.timelapse),
      KpiCard(label: 'Goulot', value: res['bottleneck'] == null ? '—' : 'S${res['bottleneck']}', color: Brand.danger, icon: Icons.warning_amber),
      KpiCard(label: 'Occupation moy.', value: fmtPct(util, 0), icon: Icons.person_outline),
    ]);
  }

  Widget _animation(Map<String, dynamic> res, bool phone) {
    final order = stationOrder(_plan!);
    final shift = ((res['shift_minutes'] ?? 480) as num).toDouble();
    final layout = _layout;
    final wbs = <int, List<String>>{};
    for (final st in (res['stations'] as List? ?? const []).cast<Map>()) {
      wbs[(st['station'] as num).toInt()] = [for (final w in (st['workers'] as List? ?? const [])) '$w'];
    }
    final bundles = _trace?.at(_t) ?? const <BundleView>[];
    final painter = TwinPainter(
      order: order,
      positions: (layout['positions'] as Map).cast<String, dynamic>(),
      bundles: bundles,
      workersByStation: wbs,
      bottleneck: (res['bottleneck'] as num?)?.toInt(),
      plan: _kind == 'plan' ? _planDoc : null,
      selected: _dragging,
      bundleSize: (((res['config'] as Map?)?['bundle_size'] ?? 10) as num).toInt(),
    );
    final h = (phone ? 300 : 420).toDouble();
    final names = [for (final sc in (_results?['scenarios'] as List? ?? const [])) '${(sc as Map)['name']}'];
    final hh = _t ~/ 60, mm = (_t % 60).floor();
    return SectionCard(
      title: 'Ligne animée',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (names.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (var i = 0; i < names.length; i++)
                ChoiceChip(
                  label: Text(names[i]),
                  selected: _shown == i,
                  onSelected: (_) => setState(() {
                    _shown = i;
                    _trace = TwinTrace(_current!);
                  }),
                ),
            ]),
          ),
        SizedBox(
          height: h,
          child: LayoutBuilder(builder: (context, c) {
            final size = Size(c.maxWidth, h);
            return GestureDetector(
              onPanStart: _kind != 'free' ? null : (d) => setState(() => _dragging = painter.hit(size, d.localPosition)),
              onPanUpdate: _kind != 'free' || _dragging == null
                  ? null
                  : (d) {
                      final v = painter.view(size);
                      final (x, y) = v.toM(d.localPosition);
                      setState(() => _free['$_dragging'] = {'x': snap(x, 0.1), 'y': snap(y, 0.1)});
                    },
              onPanEnd: _kind != 'free'
                  ? null
                  : (_) async {
                      setState(() => _dragging = null);
                      await _saveLayout();
                      _simulateLocal();
                    },
              child: ClipRect(child: CustomPaint(key: const Key('twin-canvas'), size: size, painter: painter)),
            );
          }),
        ),
        const SizedBox(height: 8),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
          IconButton.filledTonal(
            key: const Key('twin-play'),
            tooltip: _playing ? 'Pause' : 'Lecture',
            onPressed: _toggle,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Revenir au début',
            onPressed: () => setState(() => _t = 0),
            icon: const Icon(Icons.replay),
          ),
          DropdownButton<double>(
            key: const Key('twin-speed'),
            value: _speed,
            isDense: true,
            items: const [
              DropdownMenuItem(value: 1, child: Text('×1 (1 min/s)')),
              DropdownMenuItem(value: 5, child: Text('×5')),
              DropdownMenuItem(value: 10, child: Text('×10')),
              DropdownMenuItem(value: 30, child: Text('×30')),
              DropdownMenuItem(value: 60, child: Text('×60')),
            ],
            onChanged: (v) => setState(() => _speed = v ?? 10),
          ),
          Text('t = ${hh}h${mm.toString().padLeft(2, '0')} · ${_trace?.finishedAt(_t) ?? 0} pièces finies',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        Slider(value: _t.clamp(0, shift), max: shift, onChanged: (v) => setState(() => _t = v)),
        const Wrap(spacing: 14, runSpacing: 4, children: [
          _Legend(color: Brand.ok, text: 'ouvrière au travail'),
          _Legend(color: Brand.low, text: 'ouvrière disponible'),
          _Legend(color: Brand.mid, text: 'paquet en attente (encours)'),
          _Legend(color: Brand.orange, text: 'paquet en transit'),
          _Legend(color: Brand.danger, text: 'goulot'),
        ]),
        if (_trace?.truncated ?? false)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Trace tronquée : l\'animation s\'arrête avant la fin de la journée.', style: TextStyle(color: Brand.muted, fontSize: 12)),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------------ scénarios
  List<(String, String)> get _workers {
    final out = <(String, String)>[];
    for (final st in (_plan!['stations'] as List).cast<Map>()) {
      final ids = [for (final w in (st['worker_ids'] as List? ?? const [])) '$w'];
      for (final w in ids) {
        out.add((w, '${workerLabel(_plan!, w)} (S${st['station']})'));
      }
    }
    return out;
  }

  Widget _scenarioEditor() => SectionCard(
        title: 'Scénarios « et si » (${_scenarios.length}/3)',
        trailing: _scenarios.length < 3
            ? TextButton.icon(
                key: const Key('twin-add-scenario'),
                onPressed: () => setState(() => _scenarios.add(twinScenario(name: 'Scénario ${_scenarios.length + 1}'))),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter'),
              )
            : null,
        child: Column(children: [
          for (var i = 0; i < _scenarios.length; i++)
            _ScenarioTile(
              key: ValueKey('sc$i${_scenarios.length}'),
              scenario: _scenarios[i],
              stations: stationOrder(_plan!),
              workers: _workers,
              canDelete: i > 0,
              onChanged: () => setState(() {}),
              onDelete: () => setState(() {
                _scenarios.removeAt(i);
                _shown = 0;
              }),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _simulate,
              icon: const Icon(Icons.compare_arrows),
              label: Text(_scenarios.length > 1 ? 'Simuler et comparer' : 'Simuler'),
            ),
          ),
        ]),
      );

  Widget _comparison() {
    final names = [for (final sc in (_results!['scenarios'] as List)) '${(sc as Map)['name']}'];
    final rows = ((_results!['comparison'] as List?) ?? const []).cast<Map>();
    String cell(Object? v, String key) {
      if (v == null) return '—';
      if (key == 'bottleneck') return 'S$v';
      return v is num ? fmtNum(v, 1) : '$v';
    }

    return SectionCard(
      title: 'Comparaison des scénarios',
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: ScrollTable(
        columns: [
          const DataColumn(label: Text('Indicateur')),
          for (final n in names) DataColumn(label: Text(n), numeric: true),
        ],
        rows: [
          for (final r in rows)
            DataRow(cells: [
              DataCell(Text('${r['label']}')),
              for (var i = 0; i < names.length; i++)
                DataCell(Text(
                  cell((r['values'] as List).length > i ? (r['values'] as List)[i] : null, '${r['key']}'),
                  style: TextStyle(
                    fontWeight: i == 0 ? FontWeight.w600 : null,
                    color: i > 0 ? _deltaColor('${r['key']}', (r['values'] as List)[0], (r['values'] as List)[i]) : null,
                  ),
                )),
            ]),
        ],
      ),
    );
  }

  Color? _deltaColor(String key, Object? ref, Object? v) {
    if (ref is! num || v is! num || key == 'bottleneck' || key == 'operators') return null;
    if ((v - ref).abs() < 1e-9) return null;
    final higherBetter = key == 'pieces' || key == 'per_hour' || key == 'utilization_avg';
    return (v > ref) == higherBetter ? Brand.ok : Brand.danger;
  }

  Widget _notes(Map<String, dynamic> res) {
    final notes = [for (final n in (res['notes'] as List? ?? const [])) '$n'];
    final lean = [for (final w in (((res['lean'] as Map?)?['warnings'] as List?) ?? const [])) '${(w as Map)['message']}'];
    if (notes.isEmpty && lean.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Points d\'attention',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final n in notes) Padding(padding: const EdgeInsets.only(bottom: 4), child: Notice(n)),
        for (final n in lean) Padding(padding: const EdgeInsets.only(bottom: 4), child: Notice(n, kind: 'warn')),
      ]),
    );
  }

  Widget _realVsSim(AppState s) {
    final sessions = s.sessions.where((x) => x.runId == _run!.id).toList();
    if (sessions.isEmpty) {
      return const SectionCard(
        title: 'Réel vs simulé',
        child: Text('Aucune session de production pour ce calcul : ouvrez-en une dans « Production » pour comparer le réel au simulé.',
            style: TextStyle(color: Brand.muted)),
      );
    }
    final y = _sync;
    return SectionCard(
      title: 'Réel vs simulé',
      trailing: _syncSource == null ? null : Text(_syncSource == 'api' ? 'serveur' : 'local', style: const TextStyle(color: Brand.muted)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final x in sessions)
            ChoiceChip(
              label: Text('${x.model.isEmpty ? 'Session' : x.model} · ${x.sessionDate}'),
              selected: _sessionId == x.id,
              onSelected: (_) => _compareReal(x),
            ),
        ]),
        if (y != null) ...[
          const SizedBox(height: 12),
          KpiGrid(children: [
            KpiCard(label: 'Réalisé', value: '${y['output']}', sub: 'après ${fmtNum(y['elapsed_minutes'] as num?, 0)} min'),
            KpiCard(label: 'Prévu (simulé)', value: '${y['planned_day']}', sub: 'journée au temps standard'),
            KpiCard(label: 'Recalé', value: '${y['calibrated_day']}', sub: 'efficience ${fmtPct(y['efficiency_used_pct'] as num?, 0)}'),
            KpiCard(label: 'Prévision fin de journée', value: '${y['forecast_end_of_day']}', color: Brand.navy),
            KpiCard(label: 'Goulot prévu / observé', value: 'S${y['bottleneck_planned'] ?? '—'} / ${y['bottleneck_observed'] == null ? '—' : 'S${y['bottleneck_observed']}'}'),
          ]),
          const SizedBox(height: 8),
          ScrollTable(
            columns: const [
              DataColumn(label: Text('Heure')),
              DataColumn(label: Text('Objectif'), numeric: true),
              DataColumn(label: Text('Réel'), numeric: true),
              DataColumn(label: Text('Simulé'), numeric: true),
              DataColumn(label: Text('Simulé recalé'), numeric: true),
            ],
            rows: [
              for (final h in (y['hourly'] as List? ?? const []).cast<Map>())
                DataRow(cells: [
                  DataCell(Text('${h['hour']}h')),
                  DataCell(Text(fmtNum(h['target'] as num?, 0))),
                  DataCell(Text('${h['real'] ?? '—'}')),
                  DataCell(Text('${h['simulated'] ?? '—'}')),
                  DataCell(Text('${h['simulated_calibrated'] ?? '—'}')),
                ]),
            ],
          ),
          for (final n in (y['notes'] as List? ?? const [])) Padding(padding: const EdgeInsets.only(top: 4), child: Notice('$n')),
        ],
      ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: const TextStyle(fontSize: 12, color: Brand.muted))),
      ]);
}

/// Édition d'un scénario (format `TwinScenario` de l'API).
class _ScenarioTile extends StatelessWidget {
  const _ScenarioTile({
    super.key,
    required this.scenario,
    required this.stations,
    required this.workers,
    required this.canDelete,
    required this.onChanged,
    required this.onDelete,
  });
  final Map<String, dynamic> scenario;
  final List<int> stations;
  final List<(String, String)> workers;
  final bool canDelete;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  void _set(String k, Object v) {
    scenario[k] = v;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final absent = [for (final w in (scenario['absent'] as List? ?? const [])) '$w'];
    final bds = (scenario['breakdowns'] as List? ?? const []).cast<Map<String, dynamic>>();
    final ops = ((scenario['operators'] as Map?) ?? const {}).cast<String, dynamic>();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: const Color(0xFFF8FAFC),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text('${scenario['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          'Efficience ${fmtNum(scenario['efficiency_pct'] as num?, 0)} % · variabilité ${fmtNum(scenario['variability_pct'] as num?, 0)} % · '
          'paquets de ${scenario['bundle_size']}${absent.isEmpty ? '' : ' · ${absent.length} absente(s)'}${bds.isEmpty ? '' : ' · ${bds.length} panne(s)'}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: canDelete ? IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline), tooltip: 'Supprimer') : null,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 220,
              child: TextFormField(
                initialValue: '${scenario['name']}',
                decoration: const InputDecoration(labelText: 'Nom'),
                onChanged: (v) => scenario['name'] = v.isEmpty ? 'Scénario' : v,
              ),
            ),
            _slider('Efficience', (scenario['efficiency_pct'] as num).toDouble(), 50, 130, (v) => _set('efficiency_pct', v.roundToDouble()), '%'),
            _slider('Variabilité', (scenario['variability_pct'] as num).toDouble(), 0, 40, (v) => _set('variability_pct', v.roundToDouble()), '%'),
            DropdownButton<int>(
              value: (scenario['bundle_size'] as num).toInt(),
              items: [for (final b in const [5, 10, 15, 20, 30]) DropdownMenuItem(value: b, child: Text('Paquets de $b'))],
              onChanged: (v) => _set('bundle_size', v ?? 10),
            ),
            DropdownButton<double>(
              value: (scenario['shift_minutes'] as num).toDouble(),
              items: [for (final h in const [4, 8, 9, 10]) DropdownMenuItem(value: h * 60.0, child: Text('Poste de $h h'))],
              onChanged: (v) => _set('shift_minutes', v ?? 480),
            ),
          ]),
          if (workers.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Align(alignment: Alignment.centerLeft, child: Text('Absentes', style: TextStyle(fontWeight: FontWeight.w600))),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final (id, label) in workers)
                FilterChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: absent.contains(id),
                  onSelected: (v) => _set('absent', v ? [...absent, id] : absent.where((x) => x != id).toList()),
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Réaffecter selon les compétences si un poste se vide'),
              value: scenario['reassign'] != false,
              onChanged: (v) => _set('reassign', v),
            ),
          ],
          const SizedBox(height: 4),
          Row(children: [
            const Expanded(child: Text('Pannes', style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(
              onPressed: bds.length >= 20
                  ? null
                  : () => _set('breakdowns', [
                        ...bds,
                        {'station': stations.first, 'start_min': 60.0, 'duration_min': 30.0},
                      ]),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Panne'),
            ),
          ]),
          for (var i = 0; i < bds.length; i++)
            Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DropdownButton<int>(
                value: (bds[i]['station'] as num).toInt(),
                items: [for (final s in stations) DropdownMenuItem(value: s, child: Text('Station $s'))],
                onChanged: (v) {
                  bds[i]['station'] = v ?? stations.first;
                  onChanged();
                },
              ),
              _num('Début (min)', bds[i]['start_min'] as num, (v) {
                bds[i]['start_min'] = v;
              }),
              _num('Durée (min)', bds[i]['duration_min'] as num, (v) {
                bds[i]['duration_min'] = v <= 0 ? 1 : v;
              }),
              IconButton(
                onPressed: () => _set('breakdowns', [...bds]..removeAt(i)),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Retirer',
              ),
            ]),
          const SizedBox(height: 4),
          Row(children: [
            const Expanded(child: Text('Effectif imposé (renforts)', style: TextStyle(fontWeight: FontWeight.w600))),
            PopupMenuButton<int>(
              tooltip: 'Ajouter un renfort',
              icon: const Icon(Icons.person_add_alt),
              itemBuilder: (_) => [for (final s in stations) PopupMenuItem(value: s, child: Text('Station $s'))],
              onSelected: (s) => _set('operators', {...ops, '$s': ((ops['$s'] as num?)?.toInt() ?? 1) + 1}),
            ),
          ]),
          if (ops.isNotEmpty)
            Wrap(spacing: 6, children: [
              for (final e in ops.entries)
                InputChip(
                  label: Text('S${e.key} : ${e.value} ouvrière(s)'),
                  onDeleted: () => _set('operators', {...ops}..remove(e.key)),
                ),
            ]),
        ],
      ),
    );
  }

  Widget _slider(String label, double v, double min, double max, void Function(double) set, String unit) => SizedBox(
        width: 230,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label : ${fmtNum(v, 0)} $unit', style: const TextStyle(fontSize: 13)),
          Slider(value: v.clamp(min, max), min: min, max: max, divisions: (max - min).round(), onChanged: set),
        ]),
      );

  Widget _num(String label, num v, void Function(double) set) => SizedBox(
        width: 110,
        child: TextFormField(
          initialValue: fmtNum(v, 1),
          decoration: InputDecoration(labelText: label, isDense: true),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (t) {
            final x = parseNum(t);
            if (x != null && x >= 0) set(x);
          },
        ),
      );
}
