/// Import de fichiers (CSV « ; » ou « , », Excel .xlsx, JSON) vers le modèle.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../engine/engine.dart';

String _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes); // fichiers Excel « CSV (séparateur ;) » Windows-1252
  }
}

/// Lignes de la première feuille d'un classeur .xlsx (cellules en texte).
List<List<String>> xlsxRows(Uint8List bytes) {
  final book = Excel.decodeBytes(bytes);
  if (book.tables.isEmpty) return [];
  final sheet = book.tables[book.getDefaultSheet() ?? book.tables.keys.first] ?? book.tables.values.first;
  final rows = <List<String>>[];
  for (final r in sheet.rows) {
    final cells = <String>[];
    for (final c in r) {
      final v = c?.value;
      String s;
      if (v == null) {
        s = '';
      } else if (v is DoubleCellValue) {
        s = v.value.toString();
      } else if (v is IntCellValue) {
        s = v.value.toString();
      } else if (v is BoolCellValue) {
        s = v.value ? 'TRUE' : 'FALSE';
      } else if (v is TextCellValue) {
        s = v.value.toString();
      } else {
        s = v.toString();
      }
      cells.add(s);
    }
    while (cells.isNotEmpty && cells.last.trim().isEmpty) {
      cells.removeLast();
    }
    rows.add(cells);
  }
  return rows;
}

List<List<String>> _rows(String name, Uint8List bytes) {
  final ext = name.toLowerCase().split('.').last;
  if (ext == 'xlsx' || ext == 'xls') return xlsxRows(bytes);
  return parseCsvText(_decodeText(bytes));
}

List<dynamic>? _json(String name, Uint8List bytes) {
  if (!name.toLowerCase().endsWith('.json')) return null;
  final d = jsonDecode(_decodeText(bytes));
  if (d is List) return d;
  if (d is Map && d['operations'] is List) return d['operations'] as List;
  throw const FormatException('JSON attendu : une liste d\'objets.');
}

List<Operation> importOperations(String name, Uint8List bytes) {
  final j = _json(name, bytes);
  if (j != null) return [for (final o in j) Operation.fromJson((o as Map).cast<String, dynamic>())];
  final ops = parseSamRows(_rows(name, bytes));
  if (ops.isEmpty) throw const FormatException('Aucune opération lue dans le fichier SAM.');
  return ops;
}

List<Workstation> importWorkstations(String name, Uint8List bytes) {
  final j = _json(name, bytes);
  if (j != null) return [for (final o in j) Workstation.fromJson((o as Map).cast<String, dynamic>())];
  return parseWorkstationRows(_rows(name, bytes));
}

List<Worker> importWorkers(String name, Uint8List bytes) {
  final j = _json(name, bytes);
  if (j != null) return [for (final o in j) Worker.fromJson((o as Map).cast<String, dynamic>())];
  return parseWorkerRows(_rows(name, bytes));
}

/// Problème complet depuis un fichier JSON (format ProblemIn / export API).
Problem? importProblemJson(Uint8List bytes) {
  final d = jsonDecode(_decodeText(bytes));
  if (d is Map && d['operations'] is List) return Problem.fromJson(d.cast<String, dynamic>());
  if (d is Map && d['problem'] is Map) return Problem.fromJson((d['problem'] as Map).cast<String, dynamic>());
  return null;
}
