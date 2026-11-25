/// Éditeur de gamme : opérations, postes & machines, ouvriers & compétences,
/// diagnostic. Fonctionne entièrement hors ligne.
library;

import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/exporters.dart';
import '../../data/file_io.dart';
import '../../data/importers.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/shell.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'editors.dart';

class GammeEditorScreen extends StatefulWidget {
  const GammeEditorScreen({super.key, required this.gammeId});
  final String gammeId;

  @override
  State<GammeEditorScreen> createState() => _GammeEditorScreenState();
}

class _GammeEditorScreenState extends State<GammeEditorScreen> with SingleTickerProviderStateMixin {
  late GammeRecord _g;
  late Problem _p;
  late TabController _tabs;
  late TextEditingController _name;
  late TextEditingController _cycle;
  bool _dirty = false;
  PrecheckResult? _check;

  @override
  void initState() {
    super.initState();
    final rec = context.read<AppState>().repo.gamme(widget.gammeId)!;
    _g = rec;
    _p = rec.problem.deepCopy();
    _tabs = TabController(length: 4, vsync: this);
    _name = TextEditingController(text: _p.name);
    _cycle = TextEditingController(text: fmtNum(_p.targetCycleTime, 3));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    _cycle.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        _dirty = true;
        _check = null;
      });

  bool get _readOnly => !(context.read<AppState>().workshop?.canWrite ?? true);

  Future<bool> _save() async {
    if (_readOnly) {
      showSnack(context, 'Votre rôle (lecteur) ne permet pas de modifier une gamme.', error: true);
      return false;
    }
    final ids = <String>{};
    for (final o in _p.operations) {
      if (o.id.trim().isEmpty || !ids.add(o.id)) {
        showSnack(context, 'Identifiant d\'opération vide ou en double : « ${o.id} ».', error: true);
        return false;
      }
    }
    _p.name = _name.text.trim().isEmpty ? 'Gamme sans nom' : _name.text.trim();
    final c = parseNum(_cycle.text);
    if (c == null || c <= 0) {
      showSnack(context, 'Cadence cible invalide (min / pièce > 0).', error: true);
      return false;
    }
    _p.targetCycleTime = c;
    _g.problem = _p.deepCopy();
    await context.read<AppState>().saveGamme(_g);
    if (!mounted) return true;
    setState(() => _dirty = false);
    showSnack(context, 'Gamme enregistrée. Elle est disponible dans « Nouveau calcul ».');
    return true;
  }

  void _verify() {
    final c = parseNum(_cycle.text);
    if (c != null && c > 0) _p.targetCycleTime = c;
    setState(() => _check = runPrecheck(_p));
    _tabs.animateTo(3);
  }

  Future<void> _export(String kind) async {
    _p.name = _name.text.trim();
    final Uint8List bytes;
    final String name;
    if (kind == 'json') {
      bytes = problemJson(_p);
      name = '${_safe(_p.name)}.json';
    } else {
      bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(operationsToCsv(_p.operations))]);
      name = '${_safe(_p.name)}_SAM.csv';
    }
    final msg = await saveBytes(name, bytes);
    if (msg != null && mounted) showSnack(context, msg);
  }

  Future<void> _importInto(String what) async {
    final f = await pickFile();
    if (f == null || !mounted) return;
    try {
      setState(() {
        switch (what) {
          case 'sam':
            _p.operations = importOperations(f.name, f.bytes);
          case 'postes':
            _p.workstations = importWorkstations(f.name, f.bytes);
          case 'ouvriers':
            _p.workers = importWorkers(f.name, f.bytes);
        }
      });
      _changed();
      showSnack(context, 'Import réussi (${f.name}).');
    } catch (e) {
      showSnack(context, 'Import impossible : $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final total = _p.totalSam;
    final c = parseNum(_cycle.text) ?? _p.targetCycleTime;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirm(context, 'Modifications non enregistrées', 'Quitter sans enregistrer ?', ok: 'Quitter');
        if (leave && context.mounted) {
          setState(() => _dirty = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_dirty ? '${_p.name} •' : _p.name, overflow: TextOverflow.ellipsis),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Plus',
              onSelected: (v) async {
                switch (v) {
                  case 'csv':
                  case 'json':
                    await _export(v);
                  case 'imp_sam':
                    await _importInto('sam');
                  case 'imp_postes':
                    await _importInto('postes');
                  case 'imp_ouvriers':
                    await _importInto('ouvriers');
                  case 'delete':
                    if (await confirm(context, 'Supprimer la gamme', 'Supprimer « ${_p.name} » de cet appareil ?',
                            ok: 'Supprimer') &&
                        context.mounted) {
                      await context.read<AppState>().deleteGamme(_g);
                      if (context.mounted) {
                        setState(() => _dirty = false);
                        Navigator.pop(context);
                      }
                    }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'imp_sam', child: Text('Importer la gamme SAM (CSV / Excel / JSON)')),
                PopupMenuItem(value: 'imp_postes', child: Text('Importer les postes')),
                PopupMenuItem(value: 'imp_ouvriers', child: Text('Importer les ouvriers')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'csv', child: Text('Exporter les opérations (CSV)')),
                PopupMenuItem(value: 'json', child: Text('Exporter la gamme complète (JSON)')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'delete', child: Text('Supprimer la gamme')),
              ],
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            isScrollable: phone,
            tabs: [
              Tab(text: 'Opérations (${_p.operations.length})'),
              Tab(text: 'Postes (${_p.workstations.length})'),
              Tab(text: 'Ouvriers (${_p.workers.length})'),
              const Tab(text: 'Diagnostic'),
            ],
          ),
        ),
        body: Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(phone ? 12 : 20, 12, phone ? 12 : 20, 4),
            child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: phone ? double.infinity : 340,
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Nom de la gamme', hintText: 'Pantalon Théo – réf. 1203'),
                  onChanged: (_) => _changed(),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _cycle,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Cadence cible (min/pièce)'),
                  onChanged: (_) => _changed(),
                ),
              ),
              _Summary(label: 'Opérations', value: '${_p.operations.length}'),
              _Summary(label: 'Temps total SAM', value: fmtMin(total)),
              _Summary(label: 'Stations théoriques minimum', value: '${theoreticalMinStations(total, c)}'),
              _Summary(label: 'Postes', value: '${_p.workstations.length}'),
              _Summary(label: 'Ouvriers', value: '${_p.workers.length}'),
            ]),
          ),
          Expanded(
            child: TabBarView(controller: _tabs, children: [
              OperationsEditor(problem: _p, onChanged: _changed, readOnly: _readOnly),
              WorkstationsEditor(problem: _p, onChanged: _changed, readOnly: _readOnly),
              WorkersEditor(problem: _p, onChanged: _changed, readOnly: _readOnly),
              _DiagnosticTab(problem: _p, check: _check, onVerify: _verify),
            ]),
          ),
        ]),
        bottomNavigationBar: SafeArea(
          child: Container(
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Brand.border))),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: _verify, icon: const Icon(Icons.fact_check_outlined), label: const Text('Vérifier')),
              OutlinedButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: const Text('Enregistrer')),
              FilledButton.icon(
                onPressed: () async {
                  if (await _save() && context.mounted) {
                    context.read<ShellNav>().go(2, gamme: _g.id);
                    Navigator.popUntil(context, (r) => r.isFirst);
                  }
                },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Enregistrer et calculer'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

String _safe(String s) => s.replaceAll(RegExp(r'[^\w\-]+', unicode: true), '_');

class _Summary extends StatelessWidget {
  const _Summary({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Brand.muted)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}

class _DiagnosticTab extends StatelessWidget {
  const _DiagnosticTab({required this.problem, required this.check, required this.onVerify});
  final Problem problem;
  final PrecheckResult? check;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final skills = <String, int>{};
    for (final o in problem.operations) {
      for (final s in o.requiredSkills) {
        skills[s] = 0;
      }
    }
    for (final s in skills.keys.toList()) {
      skills[s] = problem.workers.where((w) => w.available && w.skills.contains(s)).length;
    }
    final errors = check?.issues.where((i) => i.isError).length ?? 0;
    return ListView(padding: const EdgeInsets.all(16), children: [
      SectionCard(
        title: 'Diagnostic de faisabilité',
        trailing: FilledButton.icon(onPressed: onVerify, icon: const Icon(Icons.fact_check), label: const Text('Vérifier')),
        child: check == null
            ? const Text('Lancez la vérification : précédences, machines, compétences, effectif, opérations plus longues que la cadence.',
                style: TextStyle(color: Brand.muted))
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                IssueList(issues: check!.issues, extraErrors: check!.validationErrors),
                if (errors > 0) ...[
                  const SizedBox(height: 8),
                  Notice(
                      '$errors point${errors > 1 ? 's' : ''} bloquant${errors > 1 ? 's' : ''} : le calcul peut échouer ou donner une solution non conforme.',
                      kind: 'warn'),
                ],
              ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Compétences requises par la gamme',
        child: skills.isEmpty
            ? const Text('Aucune compétence requise.', style: TextStyle(color: Brand.muted))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Chiffre = ouvriers disponibles qui la maîtrisent. En rouge, personne : le calcul échouera.',
                    style: TextStyle(color: Brand.muted, fontSize: 12.5)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in skills.entries)
                    Chip(
                      label: Text('${e.key}  ${problem.workers.isEmpty ? '—' : e.value}'),
                      backgroundColor: problem.workers.isNotEmpty && e.value == 0
                          ? Brand.danger.withValues(alpha: 0.12)
                          : (e.value == 1 ? Brand.warn.withValues(alpha: 0.12) : null),
                    ),
                ]),
              ]),
      ),
    ]);
  }
}
