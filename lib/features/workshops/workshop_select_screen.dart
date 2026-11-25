/// Choix de l'atelier (organisation en mode cloud, atelier local sinon).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/records.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class WorkshopSelectScreen extends StatefulWidget {
  const WorkshopSelectScreen({super.key});

  @override
  State<WorkshopSelectScreen> createState() => _WorkshopSelectScreenState();
}

class _WorkshopSelectScreenState extends State<WorkshopSelectScreen> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    if (s.isCloud && s.api.isSignedIn) _refresh();
  }

  Future<void> _refresh() async {
    final s = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await s.refreshWorkshops();
      } on ApiException catch (e) {
        // Serveur en veille (Render gratuit) : on le réveille puis on réessaie une fois.
        if (e.status != 0) rethrow;
        if (mounted) setState(() => _error = 'Réveil du serveur en cours (jusqu\'à une minute)…');
        if (!await s.api.health(timeout: const Duration(seconds: 60), retries: 1)) rethrow;
        await s.refreshWorkshops();
      }
      _error = null;
    } on ApiException catch (e) {
      _error = '${e.message}${s.workshops.isEmpty ? '' : ' Ateliers en cache affichés.'}';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = (await promptText(context, 'Nouvel atelier', label: 'Nom de l\'atelier'))?.trim();
    if (name == null || !mounted) return;
    if (name.length < 2) {
      showSnack(context, 'Le nom de l\'atelier doit faire au moins 2 caractères.', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await context.read<AppState>().createWorkshop(name);
      if (mounted) await context.read<AppState>().selectWorkshop(w);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'Création de l\'atelier impossible. ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final list = s.workshops;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choisir un atelier'),
        actions: [
          const Padding(padding: EdgeInsets.only(right: 8), child: NetChip()),
          TextButton.icon(
            onPressed: () => s.leaveMode(),
            icon: const Icon(Icons.logout),
            label: Text(s.isCloud ? 'Déconnexion' : 'Changer de mode'),
          ),
        ],
      ),
      body: PageScaffold(
        title: s.isCloud ? 'Vos ateliers' : 'Ateliers sur cet appareil',
        subtitle: s.isCloud ? s.userEmail : 'Mode local : données stockées sur cet appareil uniquement.',
        maxWidth: 760,
        actions: [
          if (s.isCloud)
            IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: 'Actualiser'),
          FilledButton.icon(onPressed: _busy ? null : _create, icon: const Icon(Icons.add), label: const Text('Nouvel atelier')),
        ],
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Notice(_error!, kind: 'error'),
          if (list.isEmpty && !_busy)
            const Card(child: EmptyState(icon: Icons.factory_outlined, text: 'Aucun atelier. Créez-en un pour commencer.')),
          for (final w in list) _tile(context, w),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, WorkshopRecord w) => Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Brand.navy.withValues(alpha: 0.1),
            child: Icon(w.isCloud ? Icons.cloud_outlined : Icons.computer, color: Brand.navy),
          ),
          title: Text(w.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text([
            roleLabels[w.role] ?? w.role,
            if (w.planCode != null) 'offre ${w.planCode}${w.planStatus != null ? ' (${w.planStatus})' : ''}',
          ].join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.read<AppState>().selectWorkshop(w),
        ),
      );
}
