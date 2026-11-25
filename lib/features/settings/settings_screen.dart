/// Atelier, compte, synchronisation et à propos.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final w = s.workshop!;
    final ops = s.repo.outbox();
    return PageScaffold(
      title: 'Atelier & compte',
      maxWidth: 860,
      children: [
        SectionCard(
          title: 'Atelier',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(w.isCloud ? Icons.cloud_outlined : Icons.computer, color: Brand.navy),
              title: Text(w.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                roleLabels[w.role] ?? w.role,
                if (w.planCode != null) 'offre ${w.planCode}',
                if (w.planStatus != null) w.planStatus!,
              ].join(' · ')),
              trailing: !w.isCloud
                  ? IconButton(
                      tooltip: 'Renommer',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final n = await promptText(context, 'Renommer l\'atelier', initial: w.name);
                        if (n != null && n.isNotEmpty) await s.renameLocalWorkshop(w, n);
                      },
                    )
                  : null,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => s.selectWorkshop(null),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Changer d\'atelier'),
              ),
            ),
          ]),
        ),
        SectionCard(
          title: s.isCloud ? 'Compte et synchronisation' : 'Mode local',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (s.isCloud) ...[
              Text('Connecté : ${s.userEmail ?? '—'}${s.isSuperAdmin ? ' · super admin' : ''}'),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft, child: NetChip()),
              const SizedBox(height: 8),
              Text('Dernière synchronisation : ${fmtDate(s.lastSync)}', style: const TextStyle(color: Brand.muted)),
              if (s.lastSyncError != null) Text('Dernier message : ${s.lastSyncError}', style: const TextStyle(color: Brand.warn)),
              const SizedBox(height: 8),
              Text('${ops.length} opération(s) en attente d\'envoi'
                  '${ops.isEmpty ? '' : ' : ${ops.map((o) => _opLabel(o.type)).toSet().join(', ')}'}'),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: s.syncing
                      ? null
                      : () async {
                          await s.checkNetwork();
                          await s.pullCloud();
                        },
                  icon: const Icon(Icons.sync),
                  label: const Text('Synchroniser maintenant'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    if (await confirm(context, 'Déconnexion',
                        'Les données en cache restent sur cet appareil. Les envois en attente reprendront à la prochaine connexion.',
                        ok: 'Se déconnecter')) {
                      await s.leaveMode();
                    }
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Se déconnecter'),
                ),
              ]),
            ] else ...[
              const Text(
                'Toutes les données (gammes, calculs, sessions de production) sont enregistrées sur cet appareil. '
                'Aucune connexion Internet n\'est nécessaire. Pour CP-SAT, l\'historique partagé et la simulation '
                'détaillée, connectez-vous avec un compte.',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => s.leaveMode(),
                  icon: const Icon(Icons.login),
                  label: const Text('Se connecter à un compte'),
                ),
              ),
            ],
          ]),
        ),
        const SectionCard(
          title: 'À propos',
          child: Text(
            '${AppConfig.appName} ${AppConfig.version}\n'
            'Moteur hors ligne : RPW (poids positionnel), postes multi-machines, partage des opérations, '
            'affectation des ouvriers par la méthode hongroise ; résultats identiques au moteur serveur (tests de parité).\n'
            'Serveur : ${AppConfig.apiBase}',
            style: TextStyle(color: Brand.muted),
          ),
        ),
      ],
    );
  }

  String _opLabel(String t) => switch (t) {
        'save_gamme' => 'gammes',
        'push_run' => 'calculs',
        'open_session' => 'sessions',
        'patch_session' => 'statut de session',
        _ => t,
      };
}
