/// Liste des gammes de l'atelier (locales + serveur).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/file_io.dart';
import '../../data/importers.dart';
import '../../engine/engine.dart';
import '../../state/app_state.dart';
import '../../ui/shell.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'gamme_editor_screen.dart';
import 'sample.dart';

class GammeListScreen extends StatefulWidget {
  const GammeListScreen({super.key});

  @override
  State<GammeListScreen> createState() => _GammeListScreenState();
}

class _GammeListScreenState extends State<GammeListScreen> {
  String _q = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    if (s.cloudAvailable) s.pullCloud();
  }

  void _open(String id) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => GammeEditorScreen(gammeId: id)));

  Future<void> _new([Problem? p]) async {
    final s = context.read<AppState>();
    final g = await s.saveGamme(s.newGamme(p));
    _open(g.id);
  }

  Future<void> _import() async {
    final f = await pickFile(extensions: ['csv', 'xlsx', 'json', 'txt']);
    if (f == null || !mounted) return;
    try {
      Problem? p;
      if (f.extension == 'json') p = importProblemJson(f.bytes);
      p ??= Problem(
        name: f.name.replaceAll(RegExp(r'\.\w+$'), ''),
        targetCycleTime: 1.0,
        operations: importOperations(f.name, f.bytes),
      );
      await _new(p);
      if (mounted) showSnack(context, '${p.operations.length} opérations importées. Ajoutez postes et ouvriers si besoin.');
    } catch (e) {
      if (mounted) showSnack(context, 'Import impossible : $e', error: true);
    }
  }

  Future<void> _openCloud(String id) async {
    setState(() => _busy = true);
    try {
      final g = await context.read<AppState>().openCloudGamme(id);
      _open(g.id);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = _q.toLowerCase();
    final local = s.gammes.where((g) => g.name.toLowerCase().contains(q)).toList();
    final cloud = s.cloudGammes.where((g) => (g['name'] ?? '').toString().toLowerCase().contains(q)).toList();
    final canWrite = s.workshop?.canWrite ?? true;
    return PageScaffold(
      title: 'Gammes',
      subtitle: 'Opérations, temps SAM, précédences, postes et ouvriers',
      actions: [
        if (canWrite) ...[
          OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.upload_file), label: const Text('Importer')),
          OutlinedButton.icon(
            onPressed: () async => _new(await loadChemiseExample()),
            icon: const Icon(Icons.checkroom),
            label: const Text('Exemple chemise'),
          ),
          FilledButton.icon(onPressed: () => _new(), icon: const Icon(Icons.add), label: const Text('Nouvelle gamme')),
        ],
      ],
      children: [
        TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Rechercher une gamme'),
          onChanged: (v) => setState(() => _q = v),
        ),
        if (_busy) const LinearProgressIndicator(),
        SectionCard(
          title: 'Sur cet appareil',
          child: local.isEmpty
              ? const EmptyState(icon: Icons.list_alt, text: 'Aucune gamme enregistrée sur cet appareil.')
              : Column(children: [
                  for (final g in local)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined, color: Brand.navy),
                      title: Text(g.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        '${g.problem.operations.length} op.',
                        fmtMin(g.problem.totalSam),
                        'cadence ${fmtNum(g.problem.targetCycleTime, 3)}',
                        fmtDate(g.updatedAt),
                      ].join(' · ')),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (s.workshop?.isCloud == true)
                          Tooltip(
                            message: g.dirty ? 'En attente d\'envoi au serveur' : 'Enregistrée sur le serveur',
                            child: Icon(g.dirty ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined,
                                color: g.dirty ? Brand.warn : Brand.ok, size: 20),
                          ),
                        IconButton(
                          tooltip: 'Calculer',
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () => context.read<ShellNav>().go(2, gamme: g.id),
                        ),
                      ]),
                      onTap: () => _open(g.id),
                    ),
                ]),
        ),
        if (s.isCloud)
          SectionCard(
            title: 'Sur le serveur',
            trailing: IconButton(
              tooltip: 'Actualiser',
              onPressed: s.cloudAvailable ? () => s.pullCloud() : null,
              icon: const Icon(Icons.refresh),
            ),
            child: !s.online
                ? const Notice('Hors ligne : les gammes du serveur non ouvertes sur cet appareil ne sont pas disponibles.')
                : cloud.isEmpty
                    ? const EmptyState(icon: Icons.cloud_outlined, text: 'Toutes les gammes du serveur sont déjà sur cet appareil.')
                    : Column(children: [
                        for (final g in cloud)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.cloud_outlined, color: Brand.muted),
                            title: Text((g['name'] ?? '').toString()),
                            subtitle: Text([
                              '${g['operations_count'] ?? '?'} op.',
                              'cadence ${fmtNum((g['target_cycle_time'] as num?) ?? 0, 3)}',
                              fmtDate(DateTime.tryParse(g['created_at']?.toString() ?? '')),
                            ].join(' · ')),
                            trailing: const Icon(Icons.download_outlined),
                            onTap: () => _openCloud(g['id'].toString()),
                          ),
                      ]),
          ),
      ],
    );
  }
}
