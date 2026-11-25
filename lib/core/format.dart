/// Formatage français (virgule décimale, espace fine pour les milliers) et identifiants.
library;

import 'dart:math';

import 'package:intl/intl.dart';

String fmtNum(num? v, [int maxDecimals = 2]) {
  if (v == null || (v is double && (v.isNaN || v.isInfinite))) return '—';
  final f = NumberFormat.decimalPatternDigits(locale: 'fr_FR', decimalDigits: maxDecimals);
  var s = f.format(v);
  if (s.contains(',')) {
    s = s.replaceFirst(RegExp(r',?0+$'), '');
  }
  return s;
}

String fmtPct(num? v, [int d = 1]) => v == null ? '—' : '${fmtNum(v, d)} %';

String fmtMin(num? v, [int d = 2]) => v == null ? '—' : '${fmtNum(v, d)} min';

String fmtDate(DateTime? d) => d == null ? '—' : DateFormat('dd/MM/yyyy HH:mm', 'fr_FR').format(d.toLocal());

String fmtDay(DateTime? d) => d == null ? '—' : DateFormat('d MMMM yyyy', 'fr_FR').format(d.toLocal());

/// Lit un nombre saisi à la française (« 1,5 ») ou à l'anglaise (« 1.5 »).
double? parseNum(String s) {
  final t = s.trim().replaceAll(' ', '').replaceAll('\u202f', '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

final _rng = Random();

/// UUID v4 (identifiants locaux et `client_id` idempotents des saisies).
String uuid4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = List.generate(16, h).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

const roleLabels = {
  'owner': 'Propriétaire',
  'admin': 'Administrateur',
  'methodes': 'Méthodes',
  'chef_ligne': 'Chef de ligne',
  'lecteur': 'Lecteur',
  'local': 'Atelier local',
};

const solverLabels = {
  'rpw': 'RPW (rapide)',
  'RPW': 'RPW (rapide)',
  'cp_sat': 'CP-SAT (optimal)',
  'CP-SAT': 'CP-SAT (optimal)',
};

const statusLabels = {
  'OPTIMAL': 'solution optimale',
  'FEASIBLE': 'solution réalisable',
  'INFEASIBLE': 'aucune solution',
  'INFEASIBLE_CONSTRAINTS': 'contraintes non respectées',
  'HEURISTIC': 'solution heuristique',
  'TIMEOUT': 'temps limite atteint',
  'ERROR': 'erreur',
};
