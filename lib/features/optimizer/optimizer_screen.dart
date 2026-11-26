/// Optimiseur multi-objectif (NSGA-II sur le modèle à événements discrets, côté serveur) :
/// objectifs réels de l'API (pièces / jour, coût minute, encours, marche + transport), contraintes
/// (effectif, cadence, encours, coût), leviers ; suivi de la tâche ; front de Pareto (tableau + nuage
/// effectif × pièces / jour coloré par occupation ou encours) ; « Appliquer » une solution = simulation
/// détaillée créée par le serveur (+ implantation enregistrée), comme l'application web.
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
import '../des/des_screen.dart';

const _decimals = {
  'pieces': 0,
  'per_hour': 1,
  'cost_minute': 4,
  'cost_piece': 3,
  'wip_avg': 0,
  'walk_m': 0,
  'people': 0,
  'operator_util_avg': 1,
  'lead_time_avg': 0,
};

String optFmt(String k, double? v) => v == null ? '—' : fmtNum(v, _decimals[k] ?? 1);

class OptimizerScreen extends StatefulWidget {
  const OptimizerScreen({super.key, required this.runId});
  final String runId;

  @override
  State<OptimizerScreen> createState() => _OptimizerScreenState();
}

class _OptimizerScreenState extends State<OptimizerScreen> {
  RunRecord? _run;
  List<SimJob> _history = [];
  Map<String, dynamic>? _sim;
  String? _error;
  bool _busy = false;
  int _pct = 0;
  int _evals = 0;
  // formulaire
  final _objs = <String>{...optObjectiveKeys};
  final _vary = <String, bool>{for (final k in optLevers.keys) k: true};
  final _cost = TextEditingController(text: '0,06');
  final _minPerHour = TextEditingController();
  final _maxPeople = TextEditingController();
  double _budget = 45;
  int _reps = 3;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _run = s.repo.run(widget.runId);
    if (_available(s)) unawaited(_load());
  }

  @override
  void dispose() {
    _cost.dispose();
    _minPerHour.dispose();
    _maxPeople.dispose();
    super.dispose();
  }

  bool _available(AppState s) => s.cloudAvailable && _run?.cloudId != null;

  double? _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _load() async {
    final s = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final h = await s.api.optimizations(s.workshop!.id, _run!.cloudId!);
      if (!mounted) return;
      setState(() => _history = [for (final x in h) SimJob(x)]);
      final last = _history.where((j) => j.done).firstOrNull;
      if (last != null) await _open(last.id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String id) async {
    final s = context.read<AppState>();
    try {
      final sim = await s.api.simulation(s.workshop!.id, id);
      if (mounted) setState(() => _sim = sim);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _launch() async {
    if (_objs.length < 2) {
      setState(() => _error = 'Choisissez au moins deux objectifs.');
      return;
    }
    final s = context.read<AppState>();
    setState(() {
      _busy = true;
      _pct = 0;
      _evals = 0;
      _error = null;
    });
    try {
      final config = optConfigBody(
        objectives: [
          for (final k in optObjectiveKeys)
            if (_objs.contains(k)) k,
        ],
        timeBudgetS: _budget,
        replications: _reps,
        costPerMinute: _num(_cost) ?? 0.06,
        minPerHour: _num(_minPerHour),
        maxPeople: _num(_maxPeople)?.round(),
        vary: _vary,
      );
      final row = await s.api.optimize(s.workshop!.id, _run!.cloudId!, config, name: 'Optimisation ${fmtDate(DateTime.now())}');
      final sim = await s.api.waitSimulation(
        s.workshop!.id,
        '${row['id']}',
        onProgress: (x) {
          if (!mounted) return;
          final j = SimJob(x);
          setState(() {
            _pct = j.pct;
            _evals = (j.progress['evals'] as num?)?.toInt() ?? _evals;
          });
        },
      );
      if (mounted) setState(() => _sim = sim);
      final h = await s.api.optimizations(s.workshop!.id, _run!.cloudId!);
      if (mounted) setState(() => _history = [for (final x in h) SimJob(x)]);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(ParetoSolution sol) async {
    final s = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Appliquer la solution ${sol.id} ?'),
        content: Text(
          'Le serveur crée une simulation détaillée de cette configuration (5 réplications) et enregistre '
          'l\'implantation correspondante pour ce calcul.\n\n${sol.changes.join('\n')}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(key: const Key('opt-apply-confirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Oui, appliquer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await s.api.applyOptimization(s.workshop!.id, '${_sim!['id']}', sol.id);
      if (!mounted) return;
      final sim = (r['simulation'] as Map).cast<String, dynamic>();
      showSnack(context, r['layout_saved'] == true ? 'Implantation enregistrée ; simulation en cours.' : 'Simulation en cours.');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DesResultScreen(simId: '${sim['id']}', initial: sim, title: 'Solution ${sol.id} — simulation'),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final r = _run;
    final avail = _available(s);
    final done = _sim != null && _sim!['status'] == 'done';
    return Scaffold(
      appBar: AppBar(title: Text('Optimiseur${r == null ? '' : ' — ${r.problem.name}'}', overflow: TextOverflow.ellipsis)),
      body: PageScaffold(
        title: 'Optimiseur Pareto',
        subtitle: 'Meilleurs compromis débit / coût / encours / déplacements, simulés sur le serveur',
        children: [
          if (r == null) const EmptyState(icon: Icons.search_off, text: 'Calcul introuvable.'),
          if (r != null && !avail) ...[
            const StatusBadge('En ligne seulement', color: Brand.muted, icon: Icons.cloud_off_outlined),
            const SizedBox(height: 8),
            onlineOnlyNotice(s, r),
          ],
          if (_error != null) Notice(_error!, kind: 'error'),
          if (r != null && avail) _form(),
          if (_busy && _sim == null && _pct == 0 && _evals == 0) const LinearProgressIndicator(),
          if (_busy && (_pct > 0 || _evals > 0))
            Column(
              key: const Key('opt-progress'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: _pct > 0 ? _pct / 100 : null),
                const SizedBox(height: 6),
                Text(
                  'Recherche des meilleurs compromis… $_pct % · $_evals configurations évaluées',
                  style: const TextStyle(color: Brand.muted),
                ),
              ],
            ),
          if (done) OptResultView(result: OptResult.fromSimulation(_sim!), onApply: avail ? _apply : null),
          if (_history.isNotEmpty)
            SectionCard(
              title: 'Historique',
              child: Column(
                children: [
                  for (final h in _history.take(10))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        h.done ? Icons.check_circle_outline : (h.failed ? Icons.error_outline : Icons.schedule),
                        color: h.done ? Brand.ok : (h.failed ? Brand.danger : Brand.muted),
                      ),
                      title: Text(h.name.isEmpty ? 'Optimisation' : h.name),
                      subtitle: Text(fmtDate(h.createdAt)),
                      selected: _sim?['id'] == h.id,
                      onTap: h.done ? () => _open(h.id) : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {String? hint}) => SizedBox(
    width: 190,
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  Widget _form() => SectionCard(
    title: 'Lancer une optimisation',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Objectifs (au moins deux)', style: TextStyle(fontWeight: FontWeight.w600)),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final k in optObjectiveKeys)
              FilterChip(
                key: Key('opt-obj-$k'),
                label: Text('${optMetrics[k]!.$1} (${optMetrics[k]!.$3 == 'max' ? 'max' : 'min'})'),
                selected: _objs.contains(k),
                onSelected: (v) => setState(() => v ? _objs.add(k) : _objs.remove(k)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('Leviers', style: TextStyle(fontWeight: FontWeight.w600)),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final e in optLevers.entries)
              FilterChip(label: Text(e.value), selected: _vary[e.key]!, onSelected: (v) => setState(() => _vary[e.key] = v)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _field(_cost, 'Coût minute (TND / pers.)'),
            _field(_minPerHour, 'Cadence min. (pcs/h)', hint: 'facultatif'),
            _field(_maxPeople, 'Effectif max.', hint: 'facultatif'),
            SizedBox(
              width: 230,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Budget de temps : ${_budget.round()} s', style: const TextStyle(fontSize: 13)),
                  Slider(value: _budget, min: 10, max: 120, divisions: 22, onChanged: (v) => setState(() => _budget = v)),
                ],
              ),
            ),
            SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Réplications : $_reps', style: const TextStyle(fontSize: 13)),
                  Slider(value: _reps.toDouble(), min: 1, max: 5, divisions: 4, onChanged: (v) => setState(() => _reps = v.round())),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('opt-run'),
            onPressed: _busy ? null : _launch,
            icon: const Icon(Icons.bolt),
            label: Text(_busy ? 'Optimisation en cours…' : 'Lancer l\'optimisation'),
          ),
        ),
      ],
    ),
  );
}

/// Résultats : solution recommandée, nuage (effectif × pièces / jour), front de Pareto en tableau.
class OptResultView extends StatefulWidget {
  const OptResultView({super.key, required this.result, this.onApply});
  final OptResult result;
  final Future<void> Function(ParetoSolution)? onApply;

  @override
  State<OptResultView> createState() => _OptResultViewState();
}

class _OptResultViewState extends State<OptResultView> {
  int? _sel;
  String _color = 'operator_util_avg'; // ou wip_avg

  @override
  Widget build(BuildContext context) {
    final res = widget.result;
    final pareto = res.pareto;
    final base = res.base;
    if (pareto.isEmpty) {
      return const Notice(
        'Aucune solution réalisable trouvée : assouplissez les contraintes ou augmentez le budget de temps.',
        kind: 'warn',
      );
    }
    final reco = res.recommended();
    final balanced = res.compromise();
    final picked = pareto.where((p) => p.id == (_sel ?? reco?.id)).firstOrNull ?? reco ?? pareto.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KpiGrid(
          children: [
            KpiCard(label: 'Compromis (front)', value: '${pareto.length}', icon: Icons.scatter_plot_outlined),
            KpiCard(label: 'Configurations', value: '${res.evals}', icon: Icons.tune),
            KpiCard(label: 'Durée', value: '${fmtNum(res.elapsedS, 0)} s', sub: res.stoppedBy, icon: Icons.timer_outlined),
            if (base != null) KpiCard(label: 'Actuel : pièces / jour', value: optFmt('pieces', base.metric('pieces'))),
            if (base != null) KpiCard(label: 'Actuel : coût minute', value: optFmt('cost_minute', base.metric('cost_minute'))),
            if (base != null) KpiCard(label: 'Actuel : effectif', value: optFmt('people', base.metric('people'))),
          ],
        ),
        if (!res.feasibleFound)
          const Notice('Aucune solution ne respecte toutes les contraintes : solutions les moins mauvaises affichées.', kind: 'warn'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (reco != null)
              ActionChip(
                key: const Key('opt-pick-reco'),
                avatar: const Icon(Icons.star_outline, size: 18),
                label: Text('Recommandée (n° ${reco.id})'),
                onPressed: () => setState(() => _sel = reco.id),
              ),
            if (balanced != null)
              ActionChip(
                key: const Key('opt-pick-balanced'),
                avatar: const Icon(Icons.balance, size: 18),
                label: Text('Équilibrée (n° ${balanced.id})'),
                onPressed: () => setState(() => _sel = balanced.id),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _SolutionCard(
          key: const Key('opt-picked'),
          s: picked,
          base: base,
          recommended: picked.id == reco?.id,
          onApply: widget.onApply == null ? null : () => widget.onApply!(picked),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Front de Pareto · ${pareto.length} compromis',
          trailing: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'operator_util_avg', label: Text('Occupation')),
              ButtonSegment(value: 'wip_avg', label: Text('Encours')),
            ],
            selected: {_color},
            onSelectionChanged: (v) => setState(() => _color = v.first),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 280,
                child: ParetoScatter(
                  key: const Key('opt-scatter'),
                  result: res,
                  colorBy: _color,
                  selected: picked.id,
                  onPick: (id) => setState(() => _sel = id),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Axe horizontal : effectif (personnes) · axe vertical : pièces / jour · couleur : '
                '${_color == 'wip_avg' ? 'encours moyen (vert = faible)' : 'occupation des opératrices (vert = élevée)'} · '
                'gris = configurations essayées · ★ = configuration actuelle. Touchez un point pour le détail.',
                style: const TextStyle(color: Brand.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Solutions',
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: ScrollTable(
            columns: const [
              DataColumn(label: Text('N°'), numeric: true),
              DataColumn(label: Text('Pièces / j'), numeric: true),
              DataColumn(label: Text('Coût min.'), numeric: true),
              DataColumn(label: Text('Encours'), numeric: true),
              DataColumn(label: Text('Marche (m)'), numeric: true),
              DataColumn(label: Text('Effectif'), numeric: true),
              DataColumn(label: Text('Occup. %'), numeric: true),
              DataColumn(label: Text('Changements')),
            ],
            rows: [
              for (final p in pareto)
                DataRow(
                  key: ValueKey('opt-row-${p.id}'),
                  selected: p.id == picked.id,
                  onSelectChanged: (_) => setState(() => _sel = p.id),
                  cells: [
                    DataCell(Text('${p.id}${p.id == reco?.id ? ' ★' : ''}')),
                    for (final k in const ['pieces', 'cost_minute', 'wip_avg', 'walk_m', 'people', 'operator_util_avg'])
                      DataCell(Text(optFmt(k, p.metric(k)))),
                    DataCell(
                      SizedBox(
                        width: 260,
                        child: Text(
                          p.changes.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SolutionCard extends StatelessWidget {
  const _SolutionCard({super.key, required this.s, required this.base, required this.recommended, this.onApply});
  final ParetoSolution s;
  final ParetoSolution? base;
  final bool recommended;
  final VoidCallback? onApply;

  static const _rows = [
    ('Pièces / jour', 'pieces'),
    ('Pièces / heure', 'per_hour'),
    ('Coût minute (TND)', 'cost_minute'),
    ('Coût par pièce (TND)', 'cost_piece'),
    ('Encours moyen (pcs)', 'wip_avg'),
    ('Traversée moyenne (min)', 'lead_time_avg'),
    ('Marche + transport (m)', 'walk_m'),
    ('Occupation opératrices (%)', 'operator_util_avg'),
    ('Effectif (personnes)', 'people'),
  ];

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Solution ${s.id}${recommended ? ' — recommandée' : ''}',
    trailing: onApply == null
        ? null
        : FilledButton.icon(key: const Key('opt-apply'), onPressed: onApply, icon: const Icon(Icons.check), label: const Text('Appliquer')),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (recommended)
          const Text(
            'Choisie car c\'est le coût minute le plus bas sans perdre de production.',
            style: TextStyle(color: Brand.muted, fontSize: 12),
          ),
        for (final c in s.changes) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $c')),
        const SizedBox(height: 8),
        ScrollTable(
          columns: const [
            DataColumn(label: Text('Indicateur')),
            DataColumn(label: Text('Actuel'), numeric: true),
            DataColumn(label: Text('Solution'), numeric: true),
          ],
          rows: [
            for (final (l, k) in _rows)
              DataRow(
                cells: [
                  DataCell(Text(l)),
                  DataCell(Text(optFmt(k, base?.metric(k)))),
                  DataCell(Text(optFmt(k, s.metric(k)), style: const TextStyle(fontWeight: FontWeight.w700))),
                ],
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Goulot : poste ${s.bottleneck ?? '—'} (actuel : poste ${base?.bottleneck ?? '—'}).',
          style: const TextStyle(color: Brand.muted, fontSize: 12),
        ),
      ],
    ),
  );
}

/// Nuage effectif × pièces / jour : essais (gris), front (couleur = occupation ou encours), actuel (★).
class ParetoScatter extends StatelessWidget {
  const ParetoScatter({super.key, required this.result, required this.colorBy, this.selected, required this.onPick});
  final OptResult result;
  final String colorBy;
  final int? selected;
  final void Function(int id) onPick;

  @override
  Widget build(BuildContext context) {
    final pareto = result.pareto;
    final base = result.base;
    final cv = [for (final p in pareto) p.metric(colorBy)].whereType<double>().toList();
    final lo = cv.isEmpty ? 0.0 : cv.reduce((a, b) => a < b ? a : b), hi = cv.isEmpty ? 1.0 : cv.reduce((a, b) => a > b ? a : b);
    Color col(double? v) {
      if (v == null) return Brand.mid;
      var t = hi - lo < 1e-9 ? 0.5 : (v - lo) / (hi - lo);
      if (colorBy == 'wip_avg') t = 1 - t; // encours faible = vert
      return Color.lerp(Brand.danger, Brand.good, t)!;
    }

    final xs = <double>[], ys = <double>[];
    void acc(Map<String, dynamic> m) {
      final x = (m['people'] as num?)?.toDouble(), y = (m['pieces'] as num?)?.toDouble();
      if (x != null && y != null) {
        xs.add(x);
        ys.add(y);
      }
    }

    for (final c in result.cloud) {
      acc(c.$1);
    }
    for (final p in pareto) {
      acc(p.mean);
    }
    if (base != null) acc(base.mean);
    if (xs.isEmpty) return const Center(child: Text('—'));
    double mn(List<double> l) => l.reduce((a, b) => a < b ? a : b);
    double mx(List<double> l) => l.reduce((a, b) => a > b ? a : b);
    final yPad = ((mx(ys) - mn(ys)) * 0.08).clamp(1.0, double.infinity);
    final spots = <ScatterSpot>[
      for (final c in result.cloud)
        if (c.$1['people'] is num && c.$1['pieces'] is num)
          ScatterSpot(
            (c.$1['people'] as num).toDouble(),
            (c.$1['pieces'] as num).toDouble(),
            dotPainter: FlDotCirclePainter(radius: 3, color: c.$2 ? const Color(0xFFC4CAD2) : const Color(0xFFF3C9C4)),
          ),
    ];
    final firstFront = spots.length;
    for (final p in pareto) {
      final x = p.metric('people'), y = p.metric('pieces');
      if (x == null || y == null) continue;
      spots.add(
        ScatterSpot(
          x,
          y,
          dotPainter: FlDotCirclePainter(
            radius: p.id == selected ? 8 : 6,
            color: col(p.metric(colorBy)),
            strokeColor: p.id == selected ? Brand.navy : Colors.white,
            strokeWidth: 2,
          ),
        ),
      );
    }
    final frontIds = [
      for (final p in pareto)
        if (p.metric('people') != null && p.metric('pieces') != null) p.id,
    ];
    if (base?.metric('people') != null && base?.metric('pieces') != null) {
      spots.add(
        ScatterSpot(
          base!.metric('people')!,
          base.metric('pieces')!,
          dotPainter: FlDotSquarePainter(size: 11, color: Brand.orange, strokeColor: Colors.white, strokeWidth: 1.5),
        ),
      );
    }
    return ScatterChart(
      ScatterChartData(
        scatterSpots: spots,
        minX: mn(xs) - 1,
        maxX: mx(xs) + 1,
        minY: mn(ys) - yPad,
        maxY: mx(ys) + yPad,
        borderData: FlBorderData(
          show: true,
          border: const Border(
            left: BorderSide(color: Brand.border),
            bottom: BorderSide(color: Brand.border),
          ),
        ),
        gridData: const FlGridData(drawVerticalLine: true),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            axisNameWidget: const Text('Pièces / jour', style: TextStyle(fontSize: 11)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, m) => Text(fmtNum(v, 0), style: const TextStyle(fontSize: 10)),
            ),
          ),
          bottomTitles: AxisTitles(
            axisNameWidget: const Text('Effectif (personnes)', style: TextStyle(fontSize: 11)),
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              reservedSize: 24,
              getTitlesWidget: (v, m) =>
                  v == v.roundToDouble() ? Text(fmtNum(v, 0), style: const TextStyle(fontSize: 10)) : const SizedBox(),
            ),
          ),
        ),
        scatterTouchData: ScatterTouchData(
          enabled: true,
          handleBuiltInTouches: false,
          touchCallback: (event, resp) {
            if (event is! FlTapUpEvent) return;
            final i = resp?.touchedSpot?.spotIndex;
            if (i == null) return;
            final j = i - firstFront;
            if (j >= 0 && j < frontIds.length) onPick(frontIds[j]);
          },
        ),
      ),
    );
  }
}
