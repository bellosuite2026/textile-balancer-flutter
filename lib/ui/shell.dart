/// Coque responsive : barre latérale étendue (bureau), rail (tablette),
/// barre de navigation basse + tiroir (téléphone).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../features/analysis/analysis_hub_screen.dart';
import '../features/calcul/new_run_screen.dart';
import '../features/gamme/gamme_list_screen.dart';
import '../features/history/history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/production/production_screen.dart';
import '../features/settings/settings_screen.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Navigation entre sections (avec un argument facultatif, ex. la gamme à calculer).
class ShellNav extends ChangeNotifier {
  int index = 0;
  String? gammeId;

  void go(int i, {String? gamme}) {
    index = i;
    gammeId = gamme;
    notifyListeners();
  }
}

class _Dest {
  final String label;
  final IconData icon;
  final IconData selected;
  const _Dest(this.label, this.icon, this.selected);
}

const _dests = [
  _Dest('Tableau de bord', Icons.dashboard_outlined, Icons.dashboard),
  _Dest('Gammes', Icons.list_alt_outlined, Icons.list_alt),
  _Dest('Nouveau calcul', Icons.calculate_outlined, Icons.calculate),
  _Dest('Historique', Icons.history_outlined, Icons.history),
  _Dest('Production', Icons.precision_manufacturing_outlined, Icons.precision_manufacturing),
  _Dest('Analyse', Icons.insights_outlined, Icons.insights),
  _Dest('Atelier & compte', Icons.settings_outlined, Icons.settings),
];

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  Widget _page(int i) => switch (i) {
        0 => const HomeScreen(),
        1 => const GammeListScreen(),
        2 => const NewRunScreen(),
        3 => const HistoryScreen(),
        4 => const ProductionScreen(),
        5 => const AnalysisHubScreen(),
        _ => const SettingsScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<ShellNav>();
    final state = context.watch<AppState>();
    final w = MediaQuery.sizeOf(context).width;
    final page = KeyedSubtree(key: ValueKey('page${nav.index}${nav.gammeId}'), child: _page(nav.index));
    final title = Row(children: [
      const Icon(Icons.linear_scale, color: Brand.navy),
      const SizedBox(width: 8),
      Flexible(
        child: Text(state.workshop?.name ?? 'Textile Line Balancer', overflow: TextOverflow.ellipsis),
      ),
    ]);

    if (w < Breakpoints.phone) {
      // Téléphone : 4 sections principales en bas, le reste dans le tiroir.
      const bottom = [0, 1, 2, 4];
      final sel = bottom.indexOf(nav.index);
      return Scaffold(
        appBar: AppBar(title: title, actions: const [Padding(padding: EdgeInsets.only(right: 8), child: NetChip())]),
        drawer: _Drawer(nav: nav, state: state),
        body: page,
        bottomNavigationBar: NavigationBar(
          selectedIndex: sel < 0 ? 0 : sel,
          indicatorColor: sel < 0 ? Colors.transparent : null,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => nav.go(bottom[i]),
          destinations: [
            for (final i in bottom)
              NavigationDestination(
                icon: Icon(_dests[i].icon),
                selectedIcon: Icon(_dests[i].selected),
                label: i == 2 ? 'Calcul' : (i == 0 ? 'Accueil' : _dests[i].label),
              ),
          ],
        ),
      );
    }

    final extended = w >= Breakpoints.desktop;
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          extended: extended,
          minExtendedWidth: 230,
          selectedIndex: nav.index,
          onDestinationSelected: nav.go,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: extended
                ? const SizedBox(
                    width: 200,
                    child: Row(children: [
                      Icon(Icons.linear_scale, color: Brand.navy, size: 28),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Textile Line\nBalancer',
                            style: TextStyle(fontWeight: FontWeight.w800, color: Brand.navy, height: 1.1)),
                      ),
                    ]),
                  )
                : const Icon(Icons.linear_scale, color: Brand.navy, size: 28),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: extended
                    ? SizedBox(
                        width: 210,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const NetChip(),
                          const SizedBox(height: 6),
                          Text(state.workshop?.name ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            state.isCloud ? (state.userEmail ?? '') : roleLabels['local']!,
                            style: const TextStyle(color: Brand.muted, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ]),
                      )
                    : Icon(state.online || !state.isCloud ? Icons.cloud_done_outlined : Icons.cloud_off,
                        color: state.online || !state.isCloud ? Brand.ok : Brand.warn),
              ),
            ),
          ),
          destinations: [
            for (final d in _dests)
              NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(child: page),
      ]),
    );
  }
}

class _Drawer extends StatelessWidget {
  const _Drawer({required this.nav, required this.state});
  final ShellNav nav;
  final AppState state;

  @override
  Widget build(BuildContext context) => NavigationDrawer(
        selectedIndex: nav.index,
        onDestinationSelected: (i) {
          Navigator.pop(context);
          nav.go(i);
        },
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Textile Line Balancer',
                  style: TextStyle(fontWeight: FontWeight.w800, color: Brand.navy, fontSize: 18)),
              const SizedBox(height: 4),
              Text(state.workshop?.name ?? '', style: const TextStyle(color: Brand.muted)),
            ]),
          ),
          for (final d in _dests)
            NavigationDrawerDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
        ],
      );
}
