/// Nouveau calcul : 1. Gamme et cadence · 2. Diagnostic · 3. Calcul.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/shell.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../results/result_screen.dart';

class NewRunScreen extends StatefulWidget {
  const NewRunScreen({super.key});

  @override
  State<NewRunScreen> createState() => _NewRunScreenState();
}

class _NewRunScreenState extends State<NewRunScreen> {
  GammeRecord? _g;
  final _cycle = TextEditingController();
  final _qty = TextEditingController();
  final _days = TextEditingController(text: '1');
  final _hours = TextEditingController(text: '8');
  final _eff = TextEditingController(text: '85');
  bool _byObjective = false;
  String _kind = 'balance';
  String _solver = 'rpw';
  int _timeLimit = 20;
  int _maxMachines = 3;
  final _change = TextEditingController(text: '0');
  String _section = 'prefer';
  String _split = 'share';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final nav = context.read<ShellNav>();
    final gs = s.gammes;
    _g = nav.gammeId != null ? s.repo.gamme(nav.gammeId!) : (gs.isNotEmpty ? gs.first : null);
    _loadGamme();
  }

  void _loadGamme() {
    final p = _g?.problem;
    if (p == null) return;
    _cycle.text = fmtNum(p.targetCycleTime, 3);
    _maxMachines = p.maxMachinesPerStation;
    _change.text = fmtNum(p.machineChangeTime, 3);
    _section = p.sectionPolicy;
    _split = p.splitMode;
  }

  @override
  void dispose() {
    for (final c in [_cycle, _qty, _days, _hours, _eff, _change]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _cycleValue {
    if (!_byObjective) return parseNum(_cycle.text);
    final q = parseNum(_qty.text), d = parseNum(_days.text), h = parseNum(_hours.text), e = parseNum(_eff.text);
    if (q == null || d == null || h == null || q <= 0) return null;
    return cycleFromObjective(
        quantity: q, days: d, hoursPerDay: h, expectedEfficiency: (e ?? AppConfig.defaultExpectedEfficiency * 100) / 100);
  }

  Problem? _problem() {
    final g = _g;
    final c = _cycleValue;
    if (g == null || c == null || c <= 0) return null;
    final p = g.problem.deepCopy();
    p.targetCycleTime = pyRound(c, 4);
    p.maxMachinesPerStation = _maxMachines;
    p.machineChangeTime = parseNum(_change.text) ?? 0;
    p.sectionPolicy = _section;
    p.splitMode = _split;
    return p;
  }

  Future<void> _launch() async {
    final p = _problem();
    if (p == null) {
      setState(() => _error = 'Choisissez une gamme et une cadence valide.');
      return;
    }
    if (p.operations.isEmpty) {
      setState(() => _error = 'La gamme ne contient aucune opération.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = context.read<AppState>();
    try {
      final RunRecord r = _solver == 'rpw'
          ? await s.runLocal(p, kind: _kind, gammeId: _g!.id)
          : await s.runCloud(p, kind: _kind, solver: _solver, timeLimit: _timeLimit, gammeId: _g!.id);
      if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => ResultScreen(runId: r.id)));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Calcul impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final gs = s.gammes;
    if (_g != null && !gs.any((g) => g.id == _g!.id)) _g = gs.isEmpty ? null : gs.first;
    final p = _problem();
    final pre = p == null ? null : runPrecheck(p);
    final canCloud = s.cloudAvailable;
    final canWrite = s.workshop?.canWrite ?? true;
    final errors = pre?.issues.where((i) => i.isError).length ?? 0;
    return PageScaffold(
      title: 'Nouveau calcul',
      subtitle: '1. Gamme et cadence · 2. Diagnostic · 3. Calcul',
      maxWidth: 1000,
      children: [
        if (!canWrite) const Notice('Votre rôle (lecteur) ne permet pas de lancer un calcul.', kind: 'warn'),
        if (_error != null) Notice(_error!, kind: 'error'),
        SectionCard(
          title: '1. Gamme et cadence',
          child: gs.isEmpty
              ? EmptyState(
                  icon: Icons.list_alt,
                  text: 'Aucune gamme sur cet appareil.',
                  action: FilledButton(onPressed: () => context.read<ShellNav>().go(1), child: const Text('Créer ou importer une gamme')),
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _g?.id,
                    decoration: const InputDecoration(labelText: 'Gamme'),
                    items: [
                      for (final g in gs)
                        DropdownMenuItem(
                          value: g.id,
                          child: Text('${g.name} · ${g.problem.operations.length} op. · ${fmtMin(g.problem.totalSam)}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (id) => setState(() {
                      _g = gs.firstWhere((g) => g.id == id);
                      _loadGamme();
                    }),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Cadence cible')),
                      ButtonSegment(value: true, label: Text('Objectif de production')),
                    ],
                    selected: {_byObjective},
                    onSelectionChanged: (v) => setState(() => _byObjective = v.first),
                  ),
                  const SizedBox(height: 12),
                  if (!_byObjective)
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _cycle,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Cadence cible (min / pièce)'),
                        onChanged: (_) => setState(() {}),
                      ),
                    )
                  else
                    Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      _num(_qty, 'Quantité (pièces)', 150),
                      _num(_days, 'Jours', 90),
                      _num(_hours, 'Heures productives / jour', 190),
                      _num(_eff, 'Rendement attendu (%)', 170),
                      Text(
                        _cycleValue == null
                            ? 'Takt et cadence : —'
                            : 'Takt ${fmtNum(_cycleValue! / ((parseNum(_eff.text) ?? 85) / 100), 3)} min · cadence à planifier ${fmtNum(_cycleValue, 3)} min',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ]),
                ]),
        ),
        if (p != null && pre != null)
          SectionCard(
            title: '2. Diagnostic',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KpiGrid(children: [
                KpiCard(label: 'Opérations', value: '${p.operations.length}'),
                KpiCard(label: 'Temps total SAM', value: fmtMin(p.totalSam)),
                KpiCard(
                    label: 'Stations théoriques', value: '${theoreticalMinStations(p.totalSam, p.targetCycleTime)}', sub: 'minimum'),
                KpiCard(label: 'Postes', value: p.workstations.isEmpty ? '—' : '${p.workstations.length}'),
                KpiCard(label: 'Ouvriers', value: p.workers.isEmpty ? '—' : '${p.workers.length}'),
                KpiCard(label: 'Production visée', value: '${fmtNum(60 / p.targetCycleTime, 1)} pcs/h'),
              ]),
              const SizedBox(height: 12),
              IssueList(issues: pre.issues, extraErrors: pre.validationErrors),
              if (errors > 0) ...[
                const SizedBox(height: 8),
                Notice(
                    '$errors point${errors > 1 ? 's' : ''} bloquant${errors > 1 ? 's' : ''} : le calcul peut échouer ou donner une solution non conforme.',
                    kind: 'warn'),
              ],
            ]),
          ),
        if (p != null)
          SectionCard(
            title: '3. Calcul',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 12, runSpacing: 12, children: [
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _kind,
                    decoration: const InputDecoration(labelText: 'Objectif'),
                    items: const [
                      DropdownMenuItem(value: 'balance', child: Text('Équilibrer à la cadence cible')),
                      DropdownMenuItem(value: 'min_cycle', child: Text('Trouver la cadence minimale')),
                    ],
                    onChanged: (v) => setState(() => _kind = v!),
                  ),
                ),
                SizedBox(
                  width: 340,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _solver,
                    decoration: const InputDecoration(labelText: 'Méthode'),
                    items: [
                      const DropdownMenuItem(value: 'rpw', child: Text('RPW – rapide, sur cet appareil (hors ligne)')),
                      DropdownMenuItem(
                        value: 'cp_sat',
                        enabled: canCloud,
                        child: Text('CP-SAT – optimisation (serveur)${canCloud ? '' : ' — indisponible'}',
                            style: TextStyle(color: canCloud ? null : Brand.muted)),
                      ),
                    ],
                    onChanged: (v) => setState(() => _solver = v!),
                  ),
                ),
                if (_solver == 'cp_sat')
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: _timeLimit,
                      decoration: InputDecoration(labelText: 'Temps max (s)${_kind == 'min_cycle' ? ' par essai' : ''}'),
                      items: [for (final t in const [5, 10, 20, 30, 60, 120, 300]) DropdownMenuItem(value: t, child: Text('$t s'))],
                      onChanged: (v) => setState(() => _timeLimit = v!),
                    ),
                  ),
              ]),
              if (!canCloud) ...[
                const SizedBox(height: 10),
                Notice(
                  !s.isCloud
                      ? 'Mode local : CP-SAT (solution optimale) nécessite un compte en ligne. RPW fonctionne sans Internet.'
                      : 'Hors ligne : CP-SAT est indisponible jusqu\'au retour du réseau. RPW fonctionne sur cet appareil.',
                ),
              ],
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Options avancées (postes multi-machines, partage)'),
                children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    SizedBox(
                      width: 230,
                      child: DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: _maxMachines,
                        decoration: const InputDecoration(labelText: 'Machines max par ouvrière'),
                        items: [for (var i = 1; i <= 6; i++) DropdownMenuItem(value: i, child: Text(i == 1 ? '1 (une machine)' : '$i'))],
                        onChanged: (v) => setState(() => _maxMachines = v!),
                      ),
                    ),
                    _num(_change, 'Déplacement (min/pièce/machine)', 240),
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _section,
                        decoration: const InputDecoration(labelText: 'Sections'),
                        items: const [
                          DropdownMenuItem(value: 'prefer', child: Text('Regrouper si possible')),
                          DropdownMenuItem(value: 'strict', child: Text('Ne jamais mélanger')),
                        ],
                        onChanged: (v) => setState(() => _section = v!),
                      ),
                    ),
                    SizedBox(
                      width: 330,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _split,
                        decoration: const InputDecoration(labelText: 'Opération plus longue que la cadence'),
                        items: const [
                          DropdownMenuItem(value: 'share', child: Text('Partager (parts + reliquat combinable)')),
                          DropdownMenuItem(value: 'parallel', child: Text('Postes parallèles égaux')),
                        ],
                        onChanged: (v) => setState(() => _split = v!),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('launch'),
                  onPressed: _busy || !canWrite || (_solver != 'rpw' && !canCloud) ? null : _launch,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.play_arrow),
                  label: Text(_busy ? 'Calcul en cours…' : 'Lancer le calcul'),
                ),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _num(TextEditingController c, String label, double w) => SizedBox(
        width: w,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}),
        ),
      );
}
