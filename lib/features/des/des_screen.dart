/// Simulation détaillée via l'API (événements discrets : variabilité, pannes aléatoires,
/// absentéisme, réplications) : formulaire, suivi de la tâche, résultats avec intervalles de confiance.
/// En ligne uniquement (mode cloud, calcul synchronisé) : `routes_des.py`.
library;

import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/analysis_models.dart';
import '../../data/api_client.dart';
import '../../data/records.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

const _palette = [Brand.navy, Brand.orange, Brand.good];

/// Message commun aux écrans serveur quand le calcul n'est pas accessible en ligne.
Widget onlineOnlyNotice(AppState s, RunRecord? r) => Notice(
      !s.isCloud
          ? 'Fonction serveur : passez en mode cloud (compte) pour l\'utiliser. Le jumeau numérique reste disponible hors ligne.'
          : !s.online
              ? 'Hors ligne : cette fonction nécessite le serveur. Réessayez une fois la connexion rétablie.'
              : 'Ce calcul n\'est pas encore synchronisé avec le serveur (copie cloud en attente).',
      kind: 'warn',
    );

class DesScreen extends StatefulWidget {
  const DesScreen({super.key, required this.runId});
  final String runId;

  @override
  State<DesScreen> createState() => _DesScreenState();
}

class _DesScreenState extends State<DesScreen> {
  RunRecord? _run;
  Map<String, dynamic>? _model;
  String? _error;
  bool _loading = false;
  bool _running = false;
  int _pct = 0;
  int _reps = 5;
  final _scenarios = <_DesForm>[_DesForm('Référence', reference: true)];
  Map<String, dynamic>? _sim;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _run = s.repo.run(widget.runId);
    if (_available(s)) unawaited(_load());
  }

  bool _available(AppState s) => s.cloudAvailable && _run?.cloudId != null;

  Future<void> _load() async {
    final s = context.read<AppState>();
    setState(() => _loading = true);
    try {
      final m = await s.api.desModel(s.workshop!.id, _run!.cloudId!);
      if (mounted) setState(() => _model = m);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _operators => [
        for (final o in (((_model?['model'] as Map?)?['operators'] as List?) ?? const [])) (o as Map).cast<String, dynamic>(),
      ];

  Future<void> _launch() async {
    final s = context.read<AppState>();
    setState(() {
      _running = true;
      _pct = 0;
      _error = null;
    });
    try {
      final row = await s.api.runDes(s.workshop!.id, _run!.cloudId!,
          scenarios: [for (final f in _scenarios) f.body()], replications: _reps, name: _scenarios.map((f) => f.name).join(' / '));
      final sim = await s.api.waitSimulation(s.workshop!.id, '${row['id']}',
          onProgress: (x) => mounted ? setState(() => _pct = SimJob(x).pct) : null);
      if (mounted) setState(() => _sim = sim);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _open(String id) async {
    final s = context.read<AppState>();
    try {
      final sim = await s.api.simulation(s.workshop!.id, id);
      if (mounted) setState(() => _sim = sim);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final r = _run;
    final summary = (_model?['summary'] as Map?) ?? const {};
    final history = [for (final x in (_model?['simulations'] as List? ?? const [])) SimJob((x as Map).cast<String, dynamic>())];
    return Scaffold(
      appBar: AppBar(title: Text('Simulation détaillée${r == null ? '' : ' — ${r.problem.name}'}', overflow: TextOverflow.ellipsis)),
      body: PageScaffold(
        title: 'Simulation détaillée',
        subtitle: 'Événements discrets sur le serveur : variabilité, pannes, absentéisme, réplications',
        children: [
          if (r == null) const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable.'),
          if (r != null && !_available(s)) onlineOnlyNotice(s, r),
          if (_error != null) Notice(_error!, kind: 'error'),
          if (_loading) const LinearProgressIndicator(),
          if (_model != null)
            KpiGrid(children: [
              KpiCard(label: 'Stations', value: '${summary['stations'] ?? '—'}'),
              KpiCard(label: 'Opératrices', value: '${summary['operators'] ?? '—'}'),
              KpiCard(label: 'SAM total', value: fmtMin(summary['sam_total'] as num?, 2)),
              KpiCard(label: 'Trajets', value: '${fmtNum(summary['path_m'] as num?, 1)} m'),
            ]),
          if (r != null && _available(s)) _form(),
          if (_running)
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LinearProgressIndicator(value: _pct > 0 ? _pct / 100 : null),
              const SizedBox(height: 6),
              Text('Simulation en cours sur le serveur… $_pct %', style: const TextStyle(color: Brand.muted)),
            ]),
          if (_sim != null) DesResultView(result: DesResult.fromSimulation(_sim!), title: '${_sim!['name'] ?? 'Résultats'}'),
          if (history.isNotEmpty)
            SectionCard(
              title: 'Historique',
              child: Column(children: [
                for (final h in history.take(10))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(h.done ? Icons.check_circle_outline : (h.failed ? Icons.error_outline : Icons.schedule),
                        color: h.done ? Brand.ok : (h.failed ? Brand.danger : Brand.muted)),
                    title: Text(h.name.isEmpty ? 'Simulation' : h.name),
                    subtitle: Text(fmtDate(h.createdAt)),
                    onTap: h.done ? () => _open(h.id) : null,
                  ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _form() => SectionCard(
        title: 'Scénarios (${_scenarios.length}/3)',
        trailing: _scenarios.length < 3
            ? TextButton.icon(
                onPressed: () => setState(() => _scenarios.add(_DesForm('Scénario ${_scenarios.length + 1}'))),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter'),
              )
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < _scenarios.length; i++)
            _DesFormTile(
              key: ValueKey('des$i${_scenarios.length}'),
              form: _scenarios[i],
              operators: _operators,
              onChanged: () => setState(() {}),
              onDelete: i == 0 ? null : () => setState(() => _scenarios.removeAt(i)),
            ),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
            SizedBox(
              width: 260,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Réplications : $_reps', style: const TextStyle(fontSize: 13)),
                Slider(value: _reps.toDouble(), min: 1, max: 20, divisions: 19, onChanged: (v) => setState(() => _reps = v.round())),
              ]),
            ),
            FilledButton.icon(
              key: const Key('des-run'),
              onPressed: _running ? null : _launch,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Lancer la simulation'),
            ),
          ]),
        ]),
      );
}

class _DesForm {
  _DesForm(this.name, {this.reference = false});
  String name;
  final bool reference;
  double eff = 100, cv = 10, mtbf = 0, mttr = 0, shift = 480;
  int bundle = 10;
  final absent = <String>{};

  Map<String, dynamic> body() => desScenarioBody(
        name: name,
        reference: reference && absent.isEmpty,
        efficiencyPct: eff,
        cvPct: cv,
        mtbfMin: mtbf,
        mttrMin: mttr,
        shiftMinutes: shift,
        bundleSize: bundle,
        absent: absent.toList(),
      );
}

class _DesFormTile extends StatelessWidget {
  const _DesFormTile({super.key, required this.form, required this.operators, required this.onChanged, this.onDelete});
  final _DesForm form;
  final List<Map<String, dynamic>> operators;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

  Widget _slider(String label, double v, double min, double max, int div, void Function(double) set, String shown) => SizedBox(
        width: 230,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label : $shown', style: const TextStyle(fontSize: 13)),
          Slider(value: v.clamp(min, max), min: min, max: max, divisions: div, onChanged: (x) {
            set(x);
            onChanged();
          }),
        ]),
      );

  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xFFF8FAFC),
        margin: const EdgeInsets.only(bottom: 8),
        child: ExpansionTile(
          title: Text(form.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            form.reference
                ? 'Modèle généré depuis le calcul (paramètres par défaut)${form.absent.isEmpty ? '' : ' · ${form.absent.length} absente(s)'}'
                : 'Efficience ${fmtNum(form.eff, 0)} % · CV ${fmtNum(form.cv, 0)} % · '
                    '${form.mtbf > 0 ? 'pannes MTBF ${fmtNum(form.mtbf, 0)} / MTTR ${fmtNum(form.mttr, 0)} min' : 'sans panne'}'
                    '${form.absent.isEmpty ? '' : ' · ${form.absent.length} absente(s)'}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: onDelete == null ? null : IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            if (!form.reference)
              Wrap(spacing: 16, runSpacing: 4, children: [
                SizedBox(
                  width: 220,
                  child: TextFormField(
                    initialValue: form.name,
                    decoration: const InputDecoration(labelText: 'Nom'),
                    onChanged: (v) => form.name = v.isEmpty ? 'Scénario' : v,
                  ),
                ),
                _slider('Efficience', form.eff, 50, 130, 80, (v) => form.eff = v.roundToDouble(), '${fmtNum(form.eff, 0)} %'),
                _slider('Variabilité (CV)', form.cv, 0, 50, 50, (v) => form.cv = v.roundToDouble(), '${fmtNum(form.cv, 0)} %'),
                _slider('Pannes : MTBF', form.mtbf, 0, 600, 24, (v) => form.mtbf = v.roundToDouble(),
                    form.mtbf == 0 ? 'aucune' : '${fmtNum(form.mtbf, 0)} min'),
                _slider('Réparation : MTTR', form.mttr, 0, 60, 12, (v) => form.mttr = v.roundToDouble(), '${fmtNum(form.mttr, 0)} min'),
                DropdownButton<double>(
                  value: form.shift,
                  items: [for (final h in const [4, 8, 9, 10]) DropdownMenuItem(value: h * 60.0, child: Text('Poste de $h h'))],
                  onChanged: (v) {
                    form.shift = v ?? 480;
                    onChanged();
                  },
                ),
                DropdownButton<int>(
                  value: form.bundle,
                  items: [for (final b in const [5, 10, 15, 20, 30]) DropdownMenuItem(value: b, child: Text('Paquets de $b'))],
                  onChanged: (v) {
                    form.bundle = v ?? 10;
                    onChanged();
                  },
                ),
              ]),
            if (operators.isNotEmpty) ...[
              const Align(alignment: Alignment.centerLeft, child: Text('Absentéisme', style: TextStyle(fontWeight: FontWeight.w600))),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final o in operators)
                  FilterChip(
                    label: Text('${o['name'] ?? o['id']}', style: const TextStyle(fontSize: 12)),
                    selected: form.absent.contains('${o['id']}'),
                    onSelected: (v) {
                      v ? form.absent.add('${o['id']}') : form.absent.remove('${o['id']}');
                      onChanged();
                    },
                  ),
              ]),
            ],
          ],
        ),
      );
}

/// Résultats d'une simulation DES : indicateurs ± IC 95 %, comparaison, production horaire, occupation.
class DesResultView extends StatefulWidget {
  const DesResultView({super.key, required this.result, this.title = 'Résultats'});
  final DesResult result;
  final String title;

  @override
  State<DesResultView> createState() => _DesResultViewState();
}

class _DesResultViewState extends State<DesResultView> {
  int _i = 0;

  String _ci(Ci c, [int d = 1]) {
    if (c.mean == null) return '—';
    return c.hasInterval ? '${fmtNum(c.mean, d)} ± ${fmtNum(c.halfWidth, d)}' : fmtNum(c.mean, d);
  }

  @override
  Widget build(BuildContext context) {
    final res = widget.result;
    final scs = res.scenarios;
    if (scs.isEmpty) return const Notice('Résultats vides.');
    final sc = scs[_i.clamp(0, scs.length - 1)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: widget.title,
        trailing: Text('${res.replications} réplication(s) · IC 95 %', style: const TextStyle(color: Brand.muted, fontSize: 12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (scs.length > 1)
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (var i = 0; i < scs.length; i++)
                ChoiceChip(label: Text(scs[i].name), selected: i == _i, onSelected: (_) => setState(() => _i = i)),
            ]),
          const SizedBox(height: 8),
          KpiGrid(children: [
            KpiCard(label: 'Production / h', value: _ci(sc.kpi('per_hour')), icon: Icons.speed),
            KpiCard(label: 'Pièces / jour', value: _ci(sc.kpi('pieces'), 0), icon: Icons.checkroom),
            KpiCard(label: 'Traversée (min)', value: _ci(sc.kpi('lead_time_avg'), 0), icon: Icons.timelapse),
            KpiCard(label: 'Encours moyen', value: _ci(sc.kpi('wip_avg'), 0), icon: Icons.inventory_2_outlined),
            KpiCard(label: 'Occupation', value: '${_ci(sc.kpi('operator_util_avg'), 0)} %', icon: Icons.person_outline),
            KpiCard(label: 'Goulot', value: sc.bottleneck == null ? '—' : 'S${sc.bottleneck}', color: Brand.danger, icon: Icons.warning_amber),
          ]),
          for (final n in sc.notes.take(5)) Padding(padding: const EdgeInsets.only(top: 6), child: Notice(n)),
        ]),
      ),
      const SizedBox(height: 16),
      if (scs.length > 1) ...[
        SectionCard(
          title: 'Comparaison (moyenne [IC 95 %])',
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: ScrollTable(
            columns: [
              const DataColumn(label: Text('Indicateur')),
              for (final s in scs) DataColumn(label: Text(s.name), numeric: true),
            ],
            rows: [
              for (final row in res.comparison)
                DataRow(cells: [
                  DataCell(Text(row.label)),
                  for (var i = 0; i < scs.length; i++)
                    DataCell(Text(i < row.values.length ? _cell(row.key, row.values[i]) : '—')),
                ]),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
      SectionCard(
        title: 'Production par heure',
        child: SizedBox(height: 220, child: _hourlyChart(scs)),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Occupation des stations — ${sc.name}',
        child: Column(children: [
          for (final st in sc.stations)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(
                  width: 44,
                  child: Text('S${st.id}',
                      style: TextStyle(fontWeight: FontWeight.w700, color: st.id == sc.bottleneck ? Brand.danger : Brand.navy)),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: (st.utilization / 100).clamp(0, 1),
                    minHeight: 10,
                    color: st.id == sc.bottleneck ? Brand.danger : (st.utilization > 85 ? Brand.warn : Brand.good),
                    backgroundColor: const Color(0xFFEFF2F6),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: Text(
                    '${_ci(sc.stationUtil[st.id] ?? Ci(mean: st.utilization), 0)} %${st.downMin > 0 ? ' · panne ${fmtNum(st.downMin, 0)} min' : ''}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }

  String _cell(String key, Ci c) {
    if (key == 'bottleneck') return c.mean == null ? '—' : 'S${fmtNum(c.mean, 0)}';
    if (c.mean == null) return '—';
    return c.hasInterval ? '${fmtNum(c.mean, 1)} [${fmtNum(c.lo, 1)} – ${fmtNum(c.hi, 1)}]' : fmtNum(c.mean, 1);
  }

  Widget _hourlyChart(List<DesScenarioResult> scs) {
    final hours = scs.fold<int>(0, (a, s) => s.hourly.length > a ? s.hourly.length : a);
    if (hours == 0) return const Center(child: Text('—'));
    final maxY = scs.expand((s) => s.hourly).fold<int>(1, (a, b) => b > a ? b : a).toDouble();
    return BarChart(BarChartData(
      maxY: maxY * 1.15,
      gridData: const FlGridData(drawVerticalLine: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 34)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, _) => Text('H${v.toInt() + 1}', style: const TextStyle(fontSize: 10))),
        ),
      ),
      barGroups: [
        for (var h = 0; h < hours; h++)
          BarChartGroupData(x: h, barsSpace: 2, barRods: [
            for (var i = 0; i < scs.length; i++)
              BarChartRodData(
                toY: h < scs[i].hourly.length ? scs[i].hourly[h].toDouble() : 0,
                color: _palette[i % _palette.length],
                width: scs.length > 1 ? 6 : 12,
                borderRadius: BorderRadius.circular(2),
              ),
          ]),
      ],
    ));
  }
}

/// Résultat d'une simulation DES ouverte directement (ex. solution appliquée de l'optimiseur).
class DesResultScreen extends StatefulWidget {
  const DesResultScreen({super.key, required this.simId, this.initial, this.title = 'Simulation détaillée'});
  final String simId;
  final Map<String, dynamic>? initial;
  final String title;

  @override
  State<DesResultScreen> createState() => _DesResultScreenState();
}

class _DesResultScreenState extends State<DesResultScreen> {
  Map<String, dynamic>? _sim;
  String? _error;
  int _pct = 0;

  @override
  void initState() {
    super.initState();
    _sim = widget.initial;
    if (_sim == null || _sim!['status'] != 'done') unawaited(_wait());
  }

  Future<void> _wait() async {
    final s = context.read<AppState>();
    if (!s.cloudAvailable) {
      setState(() => _error = 'Hors ligne : résultat indisponible.');
      return;
    }
    try {
      final sim = await s.api.waitSimulation(s.workshop!.id, widget.simId,
          onProgress: (x) => mounted ? setState(() => _pct = SimJob(x).pct) : null);
      if (mounted) setState(() => _sim = sim);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _sim != null && _sim!['status'] == 'done';
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: PageScaffold(
        title: widget.title,
        subtitle: '${_sim?['name'] ?? ''}',
        children: [
          if (_error != null) Notice(_error!, kind: 'error'),
          if (!done && _error == null)
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LinearProgressIndicator(value: _pct > 0 ? _pct / 100 : null),
              const SizedBox(height: 6),
              Text('Simulation en cours sur le serveur… $_pct %', style: const TextStyle(color: Brand.muted)),
            ]),
          if (done) DesResultView(result: DesResult.fromSimulation(_sim!), title: '${_sim!['name'] ?? 'Résultats'}'),
        ],
      ),
    );
  }
}
