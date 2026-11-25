// Parité moteur Dart <-> moteur Python de référence.
//
// Les fixtures (test/fixtures/engine/*.json) sont produites par
// tool/parity/gen_fixtures.py en exécutant le moteur Python (engine/ + api/conversion.py).
// Tolérance : aucune sur les stations, opérations, postes, ouvriers, messages ;
// 1e-9 sur les nombres (déjà arrondis à l'identique côté Python et Dart).
// Seul `solve_time_seconds` (chronométrage) est ignoré.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textile_balancer_flutter/engine/engine.dart';

Object? _norm(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _norm(v[k])};
  }
  if (v is List) return v.map(_norm).toList();
  if (v is int) return v.toDouble();
  return v;
}

void expectSame(Object? actual, Object? expected, String path) {
  final a = _norm(actual), e = _norm(expected);
  if (e is Map && a is Map) {
    expect(a.keys.toSet(), e.keys.toSet(), reason: '$path : clés');
    for (final k in e.keys) {
      expectSame(a[k], e[k], '$path.$k');
    }
  } else if (e is List && a is List) {
    expect(a.length, e.length, reason: '$path : longueur\nDart=$a\nPython=$e');
    for (var i = 0; i < e.length; i++) {
      expectSame(a[i], e[i], '$path[$i]');
    }
  } else if (e is double && a is double) {
    expect(a, closeTo(e, 1e-9), reason: path);
  } else {
    expect(a, e, reason: path);
  }
}

void main() {
  final dir = Directory('test/fixtures/engine');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures présentes', () => expect(files.length, greaterThanOrEqualTo(20)));

  for (final f in files) {
    final fx = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final name = fx['name'] as String;
    final problem = Problem.fromJson(fx['problem'] as Map<String, dynamic>);

    if (fx['kind'] == 'min_cycle') {
      test('cadence minimale RPW — $name', () {
        final r = findMinCycleRpw(problem, precision: (fx['precision'] as num).toDouble());
        final exp = fx['expected'] as Map<String, dynamic>;
        final got = r.toJson();
        if (got['result'] != null) (got['result'] as Map)['solve_time_seconds'] = 0.0;
        expectSame(got, exp, name);
      });
      continue;
    }

    test('RPW — $name (${fx['description']})', () {
      final r = solveRpw(problem, maxStations: problem.maxStations).toJson();
      r['solve_time_seconds'] = 0.0;
      expectSame(r, fx['expected'], name);
    });

    test('diagnostic — $name', () {
      final pre = runPrecheck(problem).toJson();
      final exp = Map<String, dynamic>.from(fx['precheck'] as Map);
      // L'ordre des erreurs de validation dépend de l'itération d'un set Python : comparé en ensemble.
      expect((pre['validation_errors'] as List).toSet(), (exp['validation_errors'] as List).toSet());
      pre.remove('validation_errors');
      exp.remove('validation_errors');
      expectSame(pre, exp, '$name.precheck');
    });
  }
}
