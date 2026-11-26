/// Process Flow (local) : graphe des précédences de la gamme.
/// - niveaux par plus long chemin (nombre d'arcs depuis une opération sans prédécesseur) ;
/// - ordre dans chaque niveau par barycentre (quelques passes) pour limiter les croisements ;
/// - chemin critique = plus long chemin pondéré par les SAM (durée minimale d'une pièce seule) ;
/// - précédences inconnues ignorées et signalées, cycles détectés (opérations placées après le reste).
library;

import 'models.dart';

class FlowNode {
  FlowNode(this.op, this.level, this.row);
  final Operation op;
  int level;
  double row;
  String get id => op.id;
}

class FlowGraph {
  FlowGraph._(this.nodes, this.edges, this.critical, this.criticalMinutes, this.unknownPredecessors, this.cycle);

  /// Opérations, avec niveau (colonne) et rang (ligne) calculés.
  final List<FlowNode> nodes;

  /// Arcs (prédécesseur → successeur).
  final List<(String, String)> edges;

  /// Opérations du chemin critique, dans l'ordre.
  final List<String> critical;
  final double criticalMinutes;

  /// Références de précédence vers des opérations absentes (« op → précédent inconnu »).
  final List<(String, String)> unknownPredecessors;

  /// Opérations prises dans un cycle (gamme invalide).
  final Set<String> cycle;

  int get levels => nodes.isEmpty ? 0 : nodes.map((n) => n.level).reduce((a, b) => a > b ? a : b) + 1;
  int get maxRows {
    final c = <int, int>{};
    for (final n in nodes) {
      c[n.level] = (c[n.level] ?? 0) + 1;
    }
    return c.values.fold(0, (a, b) => b > a ? b : a);
  }

  FlowNode? node(String id) => nodes.where((n) => n.id == id).firstOrNull;
  Set<(String, String)> get criticalEdges => {for (var i = 0; i + 1 < critical.length; i++) (critical[i], critical[i + 1])};
  List<String> predecessorsOf(String id) => [
    for (final e in edges)
      if (e.$2 == id) e.$1,
  ];
  List<String> successorsOf(String id) => [
    for (final e in edges)
      if (e.$1 == id) e.$2,
  ];

  factory FlowGraph.build(List<Operation> ops) {
    final byId = {for (final o in ops) o.id: o};
    final edges = <(String, String)>[];
    final unknown = <(String, String)>[];
    final seen = <(String, String)>{};
    for (final o in ops) {
      for (final p in o.predecessors) {
        if (p == o.id) continue;
        if (!byId.containsKey(p)) {
          unknown.add((o.id, p));
        } else if (seen.add((p, o.id))) {
          edges.add((p, o.id));
        }
      }
    }
    final preds = {for (final o in ops) o.id: <String>[]};
    final succs = {for (final o in ops) o.id: <String>[]};
    for (final e in edges) {
      preds[e.$2]!.add(e.$1);
      succs[e.$1]!.add(e.$2);
    }
    // Ordre topologique (Kahn), stable dans l'ordre de la gamme.
    final indeg = {for (final o in ops) o.id: preds[o.id]!.length};
    final order = <String>[];
    final ready = [
      for (final o in ops)
        if (indeg[o.id] == 0) o.id,
    ];
    while (ready.isNotEmpty) {
      final id = ready.removeAt(0);
      order.add(id);
      for (final s in succs[id]!) {
        indeg[s] = indeg[s]! - 1;
        if (indeg[s] == 0) ready.add(s);
      }
    }
    final cycle = {
      for (final o in ops)
        if (!order.contains(o.id)) o.id,
    };
    // Niveaux : plus long chemin en nombre d'arcs.
    final level = <String, int>{};
    for (final id in order) {
      level[id] = preds[id]!.where(level.containsKey).fold(-1, (a, p) => level[p]! > a ? level[p]! : a) + 1;
    }
    var next = level.values.fold(-1, (a, b) => b > a ? b : a) + 1;
    for (final o in ops) {
      if (cycle.contains(o.id)) level[o.id] = next++;
    }
    // Chemin critique (SAM) sur la partie acyclique.
    final best = <String, double>{};
    final from = <String, String?>{};
    for (final id in order) {
      String? bp;
      var bv = 0.0;
      for (final p in preds[id]!) {
        if (best.containsKey(p) && best[p]! > bv) {
          bv = best[p]!;
          bp = p;
        }
      }
      best[id] = bv + byId[id]!.duration;
      from[id] = bp;
    }
    final critical = <String>[];
    var critMin = 0.0;
    if (best.isNotEmpty) {
      var end = best.entries.reduce((a, b) => b.value > a.value ? b : a).key;
      critMin = best[end]!;
      String? cur = end;
      while (cur != null) {
        critical.insert(0, cur);
        cur = from[cur];
      }
    }
    // Rangs dans chaque niveau : ordre initial = gamme, puis barycentres (descente / montée).
    final nodes = [for (final o in ops) FlowNode(o, level[o.id]!, 0)];
    final byLevel = <int, List<FlowNode>>{};
    for (final n in nodes) {
      (byLevel[n.level] ??= []).add(n);
    }
    void rank() {
      for (final l in byLevel.values) {
        for (var i = 0; i < l.length; i++) {
          l[i].row = i.toDouble();
        }
      }
    }

    rank();
    final idx = {for (final n in nodes) n.id: n};
    final levels = byLevel.keys.toList()..sort();
    for (var pass = 0; pass < 4; pass++) {
      final down = pass.isEven;
      for (final lv in down ? levels : levels.reversed) {
        final l = byLevel[lv]!;
        double bary(FlowNode n) {
          final nb = down ? preds[n.id]! : succs[n.id]!;
          if (nb.isEmpty) return n.row;
          return nb.map((x) => idx[x]!.row).reduce((a, b) => a + b) / nb.length;
        }

        final keys = {for (final n in l) n.id: bary(n)};
        l.sort((a, b) {
          final d = keys[a.id]!.compareTo(keys[b.id]!);
          return d != 0 ? d : a.row.compareTo(b.row);
        });
        for (var i = 0; i < l.length; i++) {
          l[i].row = i.toDouble();
        }
      }
    }
    // Centrage vertical de chaque niveau.
    final maxN = byLevel.values.fold(0, (a, l) => l.length > a ? l.length : a);
    for (final l in byLevel.values) {
      final off = (maxN - l.length) / 2;
      for (final n in l) {
        n.row += off;
      }
    }
    return FlowGraph._(nodes, edges, critical, critMin, unknown, cycle);
  }
}
