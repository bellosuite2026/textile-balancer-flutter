/// Tableaux éditables de la gamme : opérations, postes, ouvriers.
/// Bureau / tablette : édition en ligne ; téléphone : cartes + formulaire.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

List<String> _list(String s) =>
    s.replaceAll(';', ',').split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();

String _nextId(Iterable<String> ids, String prefix, {int step = 10, int width = 3}) {
  var max = 0;
  final re = RegExp('^${RegExp.escape(prefix)}(\\d+)\$');
  for (final id in ids) {
    final m = re.firstMatch(id);
    if (m != null) max = math.max(max, int.parse(m.group(1)!));
  }
  return '$prefix${(max + step).toString().padLeft(width, '0')}';
}

/// Champ texte compact pour l'édition en ligne.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.width,
    required this.value,
    required this.onChanged,
    this.hint,
    this.numeric = false,
    this.readOnly = false,
    this.error = false,
  });
  final double? width;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool numeric;
  final bool readOnly;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final f = TextFormField(
      initialValue: value,
      readOnly: readOnly,
      onChanged: onChanged,
      keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        enabledBorder: error
            ? OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Brand.danger))
            : null,
      ),
    );
    return width == null ? Expanded(child: f) : SizedBox(width: width, child: f);
  }
}

Widget _header(List<(String, double?)> cols) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: const Color(0xFFF8FAFC),
      child: Row(children: [
        for (final (label, w) in cols)
          w == null
              ? Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: _h(label)))
              : SizedBox(width: w + 6, child: _h(label)),
      ]),
    );

Widget _h(String s) => Text(s, style: const TextStyle(fontWeight: FontWeight.w600, color: Brand.navy, fontSize: 12.5));

/// Conteneur à largeur minimale, défilement horizontal si l'écran est étroit.
class _WideTable extends StatelessWidget {
  const _WideTable({required this.minWidth, required this.child});
  final double minWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= minWidth) return child;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minWidth, height: c.maxHeight, child: child),
        );
      });
}

// ===========================================================================
// Opérations
// ===========================================================================

class OperationsEditor extends StatefulWidget {
  const OperationsEditor({super.key, required this.problem, required this.onChanged, this.readOnly = false});
  final Problem problem;
  final VoidCallback onChanged;
  final bool readOnly;

  @override
  State<OperationsEditor> createState() => _OperationsEditorState();
}

class _OperationsEditorState extends State<OperationsEditor> {
  List<Operation> get ops => widget.problem.operations;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _add([int? at]) {
    final prev = at != null ? ops[at] : (ops.isEmpty ? null : ops.last);
    final o = Operation(
      id: _nextId(ops.map((o) => o.id), 'OP'),
      name: '',
      duration: 0,
      predecessors: prev == null ? [] : [prev.id],
      section: prev?.section ?? '',
    );
    if (at == null) {
      ops.add(o);
    } else {
      ops.insert(at + 1, o);
    }
    _changed();
  }

  void _move(int i, int d) {
    final j = i + d;
    if (j < 0 || j >= ops.length) return;
    final o = ops.removeAt(i);
    ops.insert(j, o);
    _changed();
  }

  void _remove(int i) {
    final id = ops[i].id;
    ops.removeAt(i);
    for (final o in ops) {
      o.predecessors.remove(id);
    }
    _changed();
  }

  Future<void> _paste() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Coller depuis Excel'),
        content: SizedBox(
          width: 640,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'Copiez un bloc de cellules dans Excel (colonnes : Op_ID, Désignation, SAM, Prédécesseurs, '
              'Machine, Compétences, Section, Optionnel), puis collez-le ici.',
              style: TextStyle(color: Brand.muted),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 12,
              minLines: 6,
              autofocus: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(hintText: 'OP010\tPréparation\t0,45\t\ttable_travail\tlecture_plan\tMontage'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Ajouter les lignes')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final added = parsePastedOperations(text);
      final existing = ops.map((o) => o.id).toSet();
      final dup = added.where((o) => existing.contains(o.id)).map((o) => o.id).toList();
      ops.addAll(added.where((o) => !existing.contains(o.id)));
      _changed();
      if (mounted) {
        showSnack(context,
            '${added.length - dup.length} opération(s) ajoutée(s)${dup.isEmpty ? '' : ' ; ignorées (déjà présentes) : ${dup.join(', ')}'}');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Collage impossible : $e', error: true);
    }
  }

  Future<void> _editDialog(Operation o) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => _OperationDialog(op: o, all: ops));
    if (ok == true) _changed();
  }

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final ids = ops.map((o) => o.id).toSet();
    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        if (!widget.readOnly) ...[
          FilledButton.tonalIcon(onPressed: () => _add(), icon: const Icon(Icons.add), label: const Text('Ajouter une ligne')),
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Coller depuis Excel')),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Total ${fmtMin(widget.problem.totalSam)}', style: const TextStyle(color: Brand.muted)),
        ),
      ]),
    );
    if (ops.isEmpty) {
      return Column(children: [
        toolbar,
        const Expanded(
          child: EmptyState(
              icon: Icons.playlist_add,
              text: 'Aucune opération. Ajoutez une ligne, collez depuis Excel ou importez un fichier SAM (menu ⋮).'),
        ),
      ]);
    }
    if (phone) {
      return Column(children: [
        toolbar,
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: ops.length,
            itemBuilder: (_, i) {
              final o = ops[i];
              final bad = o.predecessors.where((p) => !ids.contains(p)).toList();
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  onTap: widget.readOnly ? null : () => _editDialog(o),
                  title: Text('${o.id} · ${o.name.isEmpty ? '(sans nom)' : o.name}'),
                  subtitle: Text([
                    fmtMin(o.duration, 3),
                    if (o.machineType.isNotEmpty) o.machineType,
                    if (o.predecessors.isNotEmpty) 'après ${o.predecessors.join(', ')}',
                    if (bad.isNotEmpty) '⚠ inconnu : ${bad.join(', ')}',
                  ].join(' · ')),
                  trailing: widget.readOnly ? null : _rowMenu(i),
                ),
              );
            },
          ),
        ),
      ]);
    }
    const cols = [
      ('Op_ID', 86.0),
      ('Désignation', null),
      ('SAM (min)', 80.0),
      ('Prédécesseurs', 140.0),
      ('Machine', 150.0),
      ('Compétences', 170.0),
      ('Section', 110.0),
      ('Opt.', 40.0),
      ('', 40.0),
    ];
    return Column(children: [
      toolbar,
      Expanded(
        child: _WideTable(
          minWidth: 1080,
          child: Column(children: [
            _header([for (final c in cols) (c.$1, c.$2)]),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: ops.length,
                itemBuilder: (_, i) {
                  final o = ops[i];
                  final badPred = o.predecessors.any((p) => !ids.contains(p) || p == o.id);
                  final dupId = ops.where((x) => x.id == o.id).length > 1;
                  final ro = widget.readOnly;
                  return Padding(
                    key: ObjectKey(o),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Row(children: [
                      _Cell(width: 86, value: o.id, readOnly: ro, error: dupId || o.id.isEmpty, onChanged: (v) {
                        final old = o.id;
                        o.id = v.trim();
                        for (final x in ops) {
                          final k = x.predecessors.indexOf(old);
                          if (k >= 0 && old.isNotEmpty) x.predecessors[k] = o.id;
                        }
                        widget.onChanged();
                      }),
                      const SizedBox(width: 6),
                      _Cell(width: null, value: o.name, readOnly: ro, hint: 'ourlet, poche, col…', onChanged: (v) {
                        o.name = v;
                        widget.onChanged();
                      }),
                      const SizedBox(width: 6),
                      _Cell(
                          width: 80,
                          value: fmtNum(o.duration, 4),
                          numeric: true,
                          readOnly: ro,
                          error: o.duration <= 0,
                          onChanged: (v) {
                            o.duration = parseNum(v) ?? 0;
                            _changed();
                          }),
                      const SizedBox(width: 6),
                      _Cell(
                          width: 140,
                          value: o.predecessors.join(', '),
                          readOnly: ro,
                          error: badPred,
                          hint: 'OP010, OP020',
                          onChanged: (v) {
                            o.predecessors = _list(v);
                            widget.onChanged();
                          }),
                      const SizedBox(width: 6),
                      _Cell(width: 150, value: o.machineType, readOnly: ro, hint: 'piqueuse_plate', onChanged: (v) {
                        o.machineType = v.trim();
                        widget.onChanged();
                      }),
                      const SizedBox(width: 6),
                      _Cell(width: 170, value: o.requiredSkills.join(', '), readOnly: ro, onChanged: (v) {
                        o.requiredSkills = _list(v);
                        widget.onChanged();
                      }),
                      const SizedBox(width: 6),
                      _Cell(width: 110, value: o.section, readOnly: ro, onChanged: (v) {
                        o.section = v.trim();
                        widget.onChanged();
                      }),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 40,
                        child: Checkbox(
                          value: o.optional,
                          onChanged: ro
                              ? null
                              : (v) {
                                  o.optional = v ?? false;
                                  _changed();
                                },
                        ),
                      ),
                      SizedBox(width: 40, child: ro ? null : _rowMenu(i)),
                    ]),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _rowMenu(int i) => PopupMenuButton<String>(
        tooltip: 'Actions',
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (v) {
          switch (v) {
            case 'edit':
              _editDialog(ops[i]);
            case 'up':
              _move(i, -1);
            case 'down':
              _move(i, 1);
            case 'insert':
              _add(i);
            case 'delete':
              _remove(i);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Modifier…')),
          PopupMenuItem(value: 'up', child: Text('Monter')),
          PopupMenuItem(value: 'down', child: Text('Descendre')),
          PopupMenuItem(value: 'insert', child: Text('Insérer une ligne en dessous')),
          PopupMenuItem(value: 'delete', child: Text('Supprimer')),
        ],
      );
}

class _OperationDialog extends StatefulWidget {
  const _OperationDialog({required this.op, required this.all});
  final Operation op;
  final List<Operation> all;

  @override
  State<_OperationDialog> createState() => _OperationDialogState();
}

class _OperationDialogState extends State<_OperationDialog> {
  late final _id = TextEditingController(text: widget.op.id);
  late final _name = TextEditingController(text: widget.op.name);
  late final _sam = TextEditingController(text: fmtNum(widget.op.duration, 4));
  late final _pred = TextEditingController(text: widget.op.predecessors.join(', '));
  late final _mach = TextEditingController(text: widget.op.machineType);
  late final _sk = TextEditingController(text: widget.op.requiredSkills.join(', '));
  late final _sec = TextEditingController(text: widget.op.section);
  late bool _opt = widget.op.optional;

  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String label, {bool num = false, String? hint}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : null,
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
        );
    return AlertDialog(
      title: const Text('Opération'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            f(_id, 'Op_ID'),
            f(_name, 'Désignation'),
            f(_sam, 'SAM (min)', num: true),
            f(_pred, 'Prédécesseurs', hint: 'séparés par des virgules'),
            f(_mach, 'Machine', hint: 'piqueuse_plate'),
            f(_sk, 'Compétences', hint: 'couture_droite, pose_poche'),
            f(_sec, 'Section', hint: 'Montage, Finition…'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _opt,
              onChanged: (v) => setState(() => _opt = v ?? false),
              title: const Text('Opération optionnelle'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final o = widget.op;
            final old = o.id;
            o.id = _id.text.trim();
            if (old != o.id && old.isNotEmpty) {
              for (final x in widget.all) {
                final k = x.predecessors.indexOf(old);
                if (k >= 0) x.predecessors[k] = o.id;
              }
            }
            o.name = _name.text.trim();
            o.duration = parseNum(_sam.text) ?? 0;
            o.predecessors = _list(_pred.text);
            o.machineType = _mach.text.trim();
            o.requiredSkills = _list(_sk.text);
            o.section = _sec.text.trim();
            o.optional = _opt;
            Navigator.pop(context, true);
          },
          child: const Text('Valider'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Postes & machines
// ===========================================================================

class WorkstationsEditor extends StatefulWidget {
  const WorkstationsEditor({super.key, required this.problem, required this.onChanged, this.readOnly = false});
  final Problem problem;
  final VoidCallback onChanged;
  final bool readOnly;

  @override
  State<WorkstationsEditor> createState() => _WorkstationsEditorState();
}

class _WorkstationsEditorState extends State<WorkstationsEditor> {
  List<Workstation> get ws => widget.problem.workstations;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _add() {
    ws.add(Workstation(id: _nextId(ws.map((w) => w.id), 'WS', step: 1, width: 2), name: '', machineType: ''));
    _changed();
  }

  /// Un poste par machine nécessaire : max(⌈travail machine / cadence⌉, postes parallèles).
  Future<void> _generate() async {
    final p = widget.problem;
    final c = p.targetCycleTime;
    final load = <String, double>{};
    final need = <String, int>{};
    final section = <String, String>{};
    for (final o in p.operations) {
      if (o.machineType.isEmpty) continue;
      load[o.machineType] = (load[o.machineType] ?? 0) + o.duration;
      need[o.machineType] = math.max(need[o.machineType] ?? 0, parallelReplicas(o, c));
      section.putIfAbsent(o.machineType, () => o.section);
    }
    if (load.isEmpty) {
      showSnack(context, 'Aucune machine dans les opérations.', error: true);
      return;
    }
    if (ws.isNotEmpty &&
        !await confirm(context, 'Générer les postes', 'Remplacer les ${ws.length} poste(s) actuels ?', ok: 'Remplacer')) {
      return;
    }
    ws.clear();
    var k = 1;
    for (final m in load.keys) {
      final n = math.max((load[m]! / c - 1e-6).ceil(), need[m]!);
      for (var i = 1; i <= n; i++) {
        ws.add(Workstation(
          id: 'WS${(k++).toString().padLeft(2, '0')}',
          name: n > 1 ? '$m $i' : m,
          machineType: m,
          section: section[m] ?? '',
        ));
      }
    }
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final machines = widget.problem.operations.map((o) => o.machineType).where((m) => m.isNotEmpty).toSet();
    final have = ws.where((w) => w.available).map((w) => w.machineType).toSet();
    final missing = machines.difference(have);
    final ro = widget.readOnly;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (!ro) ...[
            FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Ajouter un poste')),
            OutlinedButton.icon(
                onPressed: _generate, icon: const Icon(Icons.auto_fix_high), label: const Text('Générer depuis la gamme')),
          ],
        ]),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          'Facultatif : sans postes, le calcul répartit les opérations sans vérifier le parc machines. Un poste par machine physique.',
          style: TextStyle(color: Brand.muted, fontSize: 12.5),
        ),
      ),
      if (missing.isNotEmpty && ws.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Notice('Aucun poste pour : ${missing.join(', ')}', kind: 'warn'),
        ),
      Expanded(
        child: ws.isEmpty
            ? const EmptyState(icon: Icons.precision_manufacturing_outlined, text: 'Aucun poste déclaré.')
            : _WideTable(
                minWidth: 760,
                child: Column(children: [
                  _header(const [
                    ('Poste_ID', 80.0),
                    ('Nom', null),
                    ('Machine', 170.0),
                    ('Ouvriers max', 90.0),
                    ('Section', 120.0),
                    ('Dispo.', 56.0),
                    ('', 40.0),
                  ]),
                  Expanded(
                    child: ListView.builder(
                      itemCount: ws.length,
                      itemBuilder: (_, i) {
                        final w = ws[i];
                        return Padding(
                          key: ObjectKey(w),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          child: Row(children: [
                            _Cell(width: 80, value: w.id, readOnly: ro, onChanged: (v) { w.id = v.trim(); widget.onChanged(); }),
                            const SizedBox(width: 6),
                            _Cell(width: null, value: w.name, readOnly: ro, onChanged: (v) { w.name = v; widget.onChanged(); }),
                            const SizedBox(width: 6),
                            _Cell(
                                width: 170,
                                value: w.machineType,
                                readOnly: ro,
                                onChanged: (v) { w.machineType = v.trim(); _changed(); }),
                            const SizedBox(width: 6),
                            _Cell(
                                width: 90,
                                value: '${w.maxWorkers}',
                                numeric: true,
                                readOnly: ro,
                                onChanged: (v) { w.maxWorkers = int.tryParse(v) ?? 1; widget.onChanged(); }),
                            const SizedBox(width: 6),
                            _Cell(width: 120, value: w.section, readOnly: ro, onChanged: (v) { w.section = v.trim(); widget.onChanged(); }),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 56,
                              child: Switch(value: w.available, onChanged: ro ? null : (v) { w.available = v; _changed(); }),
                            ),
                            SizedBox(
                              width: 40,
                              child: ro
                                  ? null
                                  : IconButton(
                                      tooltip: 'Supprimer',
                                      icon: const Icon(Icons.delete_outline, size: 20),
                                      onPressed: () { ws.removeAt(i); _changed(); },
                                    ),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                ]),
              ),
      ),
    ]);
  }
}

// ===========================================================================
// Ouvriers & compétences
// ===========================================================================

class WorkersEditor extends StatefulWidget {
  const WorkersEditor({super.key, required this.problem, required this.onChanged, this.readOnly = false});
  final Problem problem;
  final VoidCallback onChanged;
  final bool readOnly;

  @override
  State<WorkersEditor> createState() => _WorkersEditorState();
}

class _WorkersEditorState extends State<WorkersEditor> {
  bool _matrix = false;
  List<Worker> get wk => widget.problem.workers;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  void _add() {
    wk.add(Worker(id: _nextId(wk.map((w) => w.id), 'W', step: 1, width: 3), name: ''));
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final required = <String>{for (final o in widget.problem.operations) ...o.requiredSkills};
    final ro = widget.readOnly;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!ro) FilledButton.tonalIcon(onPressed: _add, icon: const Icon(Icons.person_add_alt), label: const Text('Ajouter un ouvrier')),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Liste'), icon: Icon(Icons.list)),
              ButtonSegment(value: true, label: Text('Matrice de polyvalence'), icon: Icon(Icons.grid_on)),
            ],
            selected: {_matrix},
            onSelectionChanged: (s) => setState(() => _matrix = s.first),
          ),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text('Facultatif. Compétences séparées par des virgules ; efficacité 1 = 100 %, 0,9 = 90 %.',
            style: TextStyle(color: Brand.muted, fontSize: 12.5)),
      ),
      Expanded(
        child: wk.isEmpty
            ? const EmptyState(icon: Icons.groups_outlined, text: 'Aucun ouvrier déclaré.')
            : _matrix
                ? _matrixView(required, ro)
                : _WideTable(
                    minWidth: 760,
                    child: Column(children: [
                      _header(const [
                        ('Ouvrier_ID', 90.0),
                        ('Nom', 170.0),
                        ('Compétences', null),
                        ('Efficacité', 80.0),
                        ('Dispo.', 56.0),
                        ('', 40.0),
                      ]),
                      Expanded(
                        child: ListView.builder(
                          itemCount: wk.length,
                          itemBuilder: (_, i) {
                            final w = wk[i];
                            return Padding(
                              key: ObjectKey(w),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              child: Row(children: [
                                _Cell(width: 90, value: w.id, readOnly: ro, onChanged: (v) { w.id = v.trim(); widget.onChanged(); }),
                                const SizedBox(width: 6),
                                _Cell(width: 170, value: w.name, readOnly: ro, onChanged: (v) { w.name = v; widget.onChanged(); }),
                                const SizedBox(width: 6),
                                _Cell(
                                    width: null,
                                    value: w.skills.join(', '),
                                    readOnly: ro,
                                    hint: required.take(3).join(', '),
                                    onChanged: (v) { w.skills = _list(v); widget.onChanged(); }),
                                const SizedBox(width: 6),
                                _Cell(
                                    width: 80,
                                    value: fmtNum(w.efficiency, 3),
                                    numeric: true,
                                    readOnly: ro,
                                    error: w.efficiency <= 0,
                                    onChanged: (v) { w.efficiency = parseNum(v) ?? 1.0; widget.onChanged(); }),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 56,
                                  child: Switch(value: w.available, onChanged: ro ? null : (v) { w.available = v; _changed(); }),
                                ),
                                SizedBox(
                                  width: 40,
                                  child: ro
                                      ? null
                                      : IconButton(
                                          tooltip: 'Supprimer',
                                          icon: const Icon(Icons.delete_outline, size: 20),
                                          onPressed: () { wk.removeAt(i); _changed(); },
                                        ),
                                ),
                              ]),
                            );
                          },
                        ),
                      ),
                    ]),
                  ),
      ),
    ]);
  }

  Widget _matrixView(Set<String> required, bool ro) {
    final skills = [...required, ...{for (final w in wk) ...w.skills}.difference(required)];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: ScrollTable(
        columnSpacing: 10,
        columns: [
          const DataColumn(label: Text('Ouvrier')),
          for (final s in skills)
            DataColumn(
              label: RotatedBox(
                quarterTurns: 3,
                child: Text(s, style: TextStyle(color: required.contains(s) ? Brand.navy : Brand.muted)),
              ),
            ),
        ],
        rows: [
          for (final w in wk)
            DataRow(cells: [
              DataCell(Text(w.name.isEmpty ? w.id : w.name)),
              for (final s in skills)
                DataCell(Checkbox(
                  value: w.skills.contains(s),
                  onChanged: ro
                      ? null
                      : (v) {
                          if (v == true) {
                            w.skills.add(s);
                          } else {
                            w.skills.remove(s);
                          }
                          _changed();
                        },
                )),
            ]),
          DataRow(
            color: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
            cells: [
              const DataCell(Text('Nb ouvriers', style: TextStyle(fontWeight: FontWeight.w600))),
              for (final s in skills)
                DataCell(Builder(builder: (_) {
                  final n = wk.where((w) => w.available && w.skills.contains(s)).length;
                  return Text('$n',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: n == 0 ? Brand.danger : (n < 3 ? Brand.warn : Brand.ok)));
                })),
            ],
          ),
        ],
      ),
    );
  }
}
