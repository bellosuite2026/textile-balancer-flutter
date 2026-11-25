/// Saisie tablette : gros boutons par station (+1 / +5 / +10, défaut, retouche,
/// arrêt avec motif, annulation). Fonctionne hors ligne (file locale).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/records.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'production_dashboard_screen.dart';

const reasonIcons = {
  'panne': Icons.build,
  'manque_fourniture': Icons.inventory_2_outlined,
  'absence': Icons.person_off_outlined,
  'changement_modele': Icons.sync_alt,
  'autre': Icons.more_horiz,
};

class ProductionEntryScreen extends StatefulWidget {
  const ProductionEntryScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<ProductionEntryScreen> createState() => _ProductionEntryScreenState();
}

class _ProductionEntryScreenState extends State<ProductionEntryScreen> {
  Timer? _tick;
  final List<EntryRecord> _undo = [];

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final sess = s.repo.session(widget.sessionId);
    if (sess != null) s.pullEntries(sess);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _add(SessionRecord sess, int station, {int pieces = 0, int defects = 0, int rework = 0}) async {
    HapticFeedback.lightImpact();
    final e = await context.read<AppState>().addEntry(sess, station, pieces: pieces, defects: defects, rework: rework);
    _undo.add(e);
  }

  Future<void> _stop(SessionRecord sess, int station, EntryRecord? ongoing) async {
    final s = context.read<AppState>();
    if (ongoing != null) {
      await s.endStop(ongoing);
      return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('Arrêt — station $station'),
        children: [
          for (final e in downtimeReasons.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [Icon(reasonIcons[e.key]), const SizedBox(width: 12), Text(e.value, style: const TextStyle(fontSize: 16))]),
              ),
            ),
        ],
      ),
    );
    if (reason == null) return;
    final e = await s.addEntry(sess, station, downtimeReason: reason);
    _undo.add(e);
  }

  Future<void> _undoLast() async {
    if (_undo.isEmpty) return;
    final e = _undo.removeLast();
    final cur = context.read<AppState>().repo.entry(e.clientId);
    if (cur != null) await context.read<AppState>().voidEntry(cur);
    if (mounted) showSnack(context, 'Dernière saisie annulée.');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final sess = s.repo.session(widget.sessionId);
    if (sess == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, text: 'Session introuvable.'));
    final entries = s.repo.entries(sess.id).where((e) => !e.voided).toList();
    final stations = [for (final st in (sess.plan['stations'] as List? ?? [])) (st as Map).cast<String, dynamic>()];
    final dash = s.dashboardFor(sess);
    final pending = entries.where((e) => !e.synced).length;
    final locked = !sess.isOpen;
    return Scaffold(
      appBar: AppBar(
        title: Text('Saisie · ${sess.model}', overflow: TextOverflow.ellipsis),
        actions: [
          if (s.workshop?.isCloud == true)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: StatusBadge(
                pending == 0 ? 'Tout est envoyé' : '$pending en attente',
                color: pending == 0 ? Brand.ok : Brand.warn,
                icon: pending == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              ),
            ),
          IconButton(tooltip: 'Annuler la dernière saisie', onPressed: _undo.isEmpty || locked ? null : _undoLast, icon: const Icon(Icons.undo)),
          IconButton(
            tooltip: 'Tableau de bord',
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProductionDashboardScreen(sessionId: sess.id))),
          ),
        ],
      ),
      body: Column(children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Wrap(spacing: 20, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _big('Réalisé', '${dash['output']}'),
            _big('Objectif à date', fmtNum(dash['expected_to_date'] as num?, 0)),
            _big('% objectif', dash['pct_target'] == null ? '—' : '${fmtNum(dash['pct_target'] as num, 0)} %',
                color: (dash['pct_target'] as num? ?? 100) < 80 ? Brand.danger : Brand.ok),
            _big('Objectif du poste', fmtNum(dash['target_shift'] as num?, 0)),
            Text('Heure ${DateTime.now().hour} h · poste ${sess.shiftStart}', style: const TextStyle(color: Brand.muted)),
          ]),
        ),
        if (locked) const Padding(padding: EdgeInsets.all(12), child: Notice('Session fermée : la saisie est verrouillée.', kind: 'warn')),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth < 560 ? 1 : (c.maxWidth < 1000 ? 2 : 3);
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: 290,
              ),
              itemCount: stations.length,
              itemBuilder: (_, i) {
                final st = stations[i];
                final n = st['station'] as int;
                final mine = entries.where((e) => e.station == n).toList();
                final pieces = mine.fold<int>(0, (a, e) => a + e.pieces);
                final defects = mine.fold<int>(0, (a, e) => a + e.defects);
                final rework = mine.fold<int>(0, (a, e) => a + e.rework);
                EntryRecord? ongoing;
                for (final e in mine) {
                  if (e.downtimeReason != null && e.downtimeMinutes == null) ongoing = e;
                }
                final row = (dash['stations'] as List).cast<Map>().firstWhere((r) => r['station'] == n, orElse: () => {});
                final pct = row['pct_target'] as num?;
                return Card(
                  color: ongoing != null ? const Color(0xFFFFF7ED) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Text('Station $n', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Brand.navy)),
                        const Spacer(),
                        Text('$pieces pcs', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        if (pct != null) ...[
                          const SizedBox(width: 8),
                          StatusBadge('${fmtNum(pct, 0)} %', color: pct < 80 ? Brand.danger : Brand.ok),
                        ],
                      ]),
                      Text(
                        [
                          (st['operations'] as List).map((o) => (o as Map)['id']).join(', '),
                          if ((st['workers'] as List).isNotEmpty) (st['workers'] as List).join(', '),
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Brand.muted, fontSize: 12),
                      ),
                      const Spacer(),
                      Row(children: [
                        for (final k in const [1, 5, 10]) ...[
                          Expanded(
                            child: SizedBox(
                              height: 56,
                              child: FilledButton(
                                onPressed: locked ? null : () => _add(sess, n, pieces: k),
                                child: Text('+$k', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                              ),
                            ),
                          ),
                          if (k != 10) const SizedBox(width: 8),
                        ],
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: locked ? null : () => _add(sess, n, defects: 1),
                            child: Text('Défaut +1 ($defects)'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: locked ? null : () => _add(sess, n, rework: 1),
                            child: Text('Retouche +1 ($rework)'),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 44,
                        child: ongoing != null
                            ? FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Brand.orange),
                                onPressed: locked ? null : () => _stop(sess, n, ongoing),
                                icon: Icon(reasonIcons[ongoing.downtimeReason]),
                                label: Text(
                                    '${downtimeReasons[ongoing.downtimeReason]} depuis ${_since(ongoing.downtimeStart)} — toucher pour reprendre'),
                              )
                            : OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(foregroundColor: Brand.orange),
                                onPressed: locked ? null : () => _stop(sess, n, null),
                                icon: const Icon(Icons.pause_circle_outline),
                                label: const Text('Arrêt'),
                              ),
                      ),
                    ]),
                  ),
                );
              },
            );
          }),
        ),
      ]),
    );
  }

  String _since(String? iso) {
    final d = DateTime.tryParse(iso ?? '');
    if (d == null) return '?';
    final m = DateTime.now().difference(d).inMinutes;
    return '$m min';
  }

  Widget _big(String label, String value, {Color? color}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
        ],
      );
}
