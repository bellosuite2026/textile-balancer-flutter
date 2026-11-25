/// Composants d'interface partagés.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../engine/engine.dart';
import '../state/app_state.dart';
import 'theme.dart';

bool isPhone(BuildContext c) => MediaQuery.sizeOf(c).width < Breakpoints.phone;

/// Page à défilement avec titre, sous-titre et actions.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.children,
    this.maxWidth = 1280,
    this.padding,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> children;
  final double maxWidth;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    return SafeArea(
      child: ListView(
        padding: padding ?? EdgeInsets.all(phone ? 12 : 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 8,
                    spacing: 12,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(color: Brand.navy, fontWeight: FontWeight.w700)),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(subtitle!, style: const TextStyle(color: Brand.muted)),
                            ),
                        ],
                      ),
                      if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
                    ],
                  ),
                  const SizedBox(height: 16),
                  for (final c in children) ...[c, const SizedBox(height: 16)],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(16)});
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null || trailing != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    if (title != null)
                      Expanded(
                        child: Text(title!,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Brand.navy)),
                      ),
                    if (trailing != null) Flexible(child: trailing!),
                  ]),
                ),
              child,
            ],
          ),
        ),
      );
}

class KpiCard extends StatelessWidget {
  const KpiCard({super.key, required this.label, required this.value, this.sub, this.color, this.icon});
  final String label;
  final String value;
  final String? sub;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Container(
          constraints: const BoxConstraints(minWidth: 150),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 16, color: Brand.muted), const SizedBox(width: 6)],
                Flexible(child: Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12.5))),
              ]),
              const SizedBox(height: 6),
              Text(value,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color ?? const Color(0xFF111827))),
              if (sub != null) Text(sub!, style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ],
          ),
        ),
      );
}

/// Grille de KPI qui s'adapte à la largeur.
class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth < 420 ? 2 : (c.maxWidth < 800 ? 3 : 6);
        final w = (c.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final k in children) SizedBox(width: w, child: k)],
        );
      });
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {super.key, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  factory StatusBadge.forRun({required String status, BalanceResult? result, bool found = true}) {
    if (status == 'queued') return const StatusBadge('En file', color: Brand.muted, icon: Icons.schedule);
    if (status == 'running') return const StatusBadge('En cours', color: Brand.mid, icon: Icons.autorenew);
    if (status == 'failed' || !found) return const StatusBadge('Échec', color: Brand.danger, icon: Icons.error_outline);
    if (result == null) return const StatusBadge('—', color: Brand.muted);
    if (result.compliant) return const StatusBadge('Conforme', color: Brand.ok, icon: Icons.check_circle_outline);
    if (result.success) return const StatusBadge('À vérifier', color: Brand.warn, icon: Icons.help_outline);
    return const StatusBadge('Non conforme', color: Brand.danger, icon: Icons.cancel_outlined);
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ]),
      );
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.kind = 'info'});
  final String text;
  final String kind; // info | ok | warn | error

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (kind) {
      'ok' => (Brand.ok, Icons.check_circle_outline),
      'warn' => (Brand.warn, Icons.warning_amber_rounded),
      'error' => (Brand.danger, Icons.error_outline),
      _ => (Brand.mid, Icons.info_outline),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
    );
  }
}

/// Liste de points de diagnostic (Bloquant / Attention).
class IssueList extends StatelessWidget {
  const IssueList({super.key, required this.issues, this.extraErrors = const []});
  final List<Issue> issues;
  final List<String> extraErrors;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty && extraErrors.isEmpty) return const Notice('Aucun problème détecté.', kind: 'ok');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in extraErrors) _row('Données', e, '', Brand.danger),
      for (final i in issues)
        _row(i.isError ? 'Bloquant' : 'Attention', '[${i.code}] ${i.message}', i.suggestion,
            i.isError ? Brand.danger : Brand.warn),
    ]);
  }

  Widget _row(String tag, String msg, String sugg, Color c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 78,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(tag, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: msg),
              if (sugg.isNotEmpty)
                TextSpan(text: '  → $sugg', style: const TextStyle(fontStyle: FontStyle.italic, color: Brand.muted)),
            ])),
          ),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
        child: Column(children: [
          Icon(icon, size: 40, color: Brand.low),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ]),
      );
}

/// Bandeau d'état réseau / synchronisation.
class NetChip extends StatelessWidget {
  const NetChip({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (!s.isCloud) {
      return const Tooltip(
        message: 'Mode local : toutes les données restent sur cet appareil.',
        child: StatusBadge('Mode local', color: Brand.muted, icon: Icons.computer),
      );
    }
    final pending = s.pendingCount;
    final (label, color, icon) = switch (s.net) {
      NetStatus.online => (
          s.syncing ? 'Synchronisation…' : (pending > 0 ? 'En ligne · $pending en attente' : 'En ligne'),
          Brand.ok,
          Icons.cloud_done_outlined
        ),
      NetStatus.offline => (pending > 0 ? 'Hors ligne · $pending en attente' : 'Hors ligne', Brand.warn, Icons.cloud_off),
      NetStatus.unknown => ('Connexion…', Brand.muted, Icons.cloud_queue),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => s.checkNetwork(),
      child: Tooltip(
        message: s.lastSyncError ?? (s.lastSync != null ? 'Dernière synchro : ${fmtDate(s.lastSync)}' : 'Toucher pour vérifier'),
        child: StatusBadge(label, color: color, icon: icon),
      ),
    );
  }
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Brand.danger : null,
    behavior: SnackBarBehavior.floating,
  ));
}

Future<bool> confirm(BuildContext context, String title, String message, {String ok = 'Confirmer'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    ) ??
    false;

Future<String?> promptText(BuildContext context, String title, {String label = '', String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

/// Tableau défilant horizontalement (téléphone) avec en-tête collant visuellement.
class ScrollTable extends StatelessWidget {
  const ScrollTable({super.key, required this.columns, required this.rows, this.columnSpacing = 18});
  final List<DataColumn> columns;
  final List<DataRow> rows;
  final double columnSpacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth),
            child: DataTable(
              columns: columns,
              rows: rows,
              columnSpacing: columnSpacing,
              showCheckboxColumn: false,
              headingRowHeight: 40,
              dataRowMinHeight: 40,
              dataRowMaxHeight: double.infinity,
              headingRowColor: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
            ),
          ),
        ),
      );
}
