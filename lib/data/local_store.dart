/// Stockage local hors ligne : collections de documents JSON.
///
/// Implémentation : Hive CE (Dart pur) → fichiers sur Windows / Linux /
/// Android, IndexedDB sur le Web. Chaque document est stocké en texte JSON
/// (pas d'adaptateur généré) : le format est exactement celui de l'API, ce qui
/// rend la synchronisation triviale et l'export / la sauvegarde lisibles.
library;

import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'storage_path.dart';

/// Collections utilisées par l'application.
abstract class Col {
  static const settings = 'settings';
  static const workshops = 'workshops';
  static const gammes = 'gammes';
  static const runs = 'runs';
  static const sessions = 'sessions';
  static const entries = 'entries';
  static const outbox = 'outbox';
  static const plans = 'workshop_plans'; // plans d'atelier (format API)
  static const layouts = 'twin_layouts'; // implantation du jumeau par calcul
  static const all = [settings, workshops, gammes, runs, sessions, entries, outbox, plans, layouts];
}

abstract class LocalStore {
  Future<void> open();
  Map<String, dynamic>? get(String col, String id);
  List<Map<String, dynamic>> all(String col);
  Future<void> put(String col, String id, Map<String, dynamic> doc);
  Future<void> delete(String col, String id);
  Future<void> clear(String col);
}

/// Magasin Hive (production).
class HiveLocalStore implements LocalStore {
  final Map<String, Box<String>> _boxes = {};

  @override
  Future<void> open() async {
    final dir = await localStoragePath();
    if (dir != null) Hive.init(dir);
    for (final c in Col.all) {
      _boxes[c] = await Hive.openBox<String>('tlb_$c');
    }
  }

  Box<String> _b(String col) => _boxes[col] ?? (throw StateError('Collection non ouverte : $col'));

  @override
  Map<String, dynamic>? get(String col, String id) {
    final s = _b(col).get(id);
    return s == null ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
  }

  @override
  List<Map<String, dynamic>> all(String col) =>
      [for (final s in _b(col).values) (jsonDecode(s) as Map).cast<String, dynamic>()];

  @override
  Future<void> put(String col, String id, Map<String, dynamic> doc) => _b(col).put(id, jsonEncode(doc));

  @override
  Future<void> delete(String col, String id) => _b(col).delete(id);

  @override
  Future<void> clear(String col) async {
    await _b(col).clear();
  }
}

/// Magasin en mémoire (tests).
class MemoryLocalStore implements LocalStore {
  final Map<String, Map<String, String>> _data = {for (final c in Col.all) c: {}};

  @override
  Future<void> open() async {}

  @override
  Map<String, dynamic>? get(String col, String id) {
    final s = _data[col]![id];
    return s == null ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
  }

  @override
  List<Map<String, dynamic>> all(String col) =>
      [for (final s in _data[col]!.values) (jsonDecode(s) as Map).cast<String, dynamic>()];

  @override
  Future<void> put(String col, String id, Map<String, dynamic> doc) async => _data[col]![id] = jsonEncode(doc);

  @override
  Future<void> delete(String col, String id) async => _data[col]!.remove(id);

  @override
  Future<void> clear(String col) async => _data[col]!.clear();
}
