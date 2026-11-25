/// Suivi de production hors ligne : plan figé d'une session et tableau de
/// bord temps réel. Portage de `api/production.py` (build_plan, dashboard) :
/// mêmes définitions et même JSON que `GET .../production/sessions/{id}/dashboard`.
///
/// - réalisé ligne = pièces déclarées à la DERNIÈRE station ;
/// - objectif à date = objectif pièces/heure × temps écoulé dans le poste ;
/// - minutes produites (station) = pièces × temps de la station ;
/// - minutes de présence = opérateurs × temps écoulé − arrêts « absence » ;
/// - efficience = minutes produites / minutes de présence ;
/// - goulot observé = station qui a sorti le moins de pièces ;
/// - alerte < 80 % de l'objectif à date (après 15 min), arrêt > 15 min.
///
/// Fuseau : le Python utilise le fuseau de la session (Africa/Tunis par
/// défaut). Ici, les heures sont celles de l'appareil (même fuseau en atelier).
library;

import 'dart:math' as math;

import 'models.dart';
import 'pyfmt.dart';

const downtimeReasons = <String, String>{
  'panne': 'Panne machine',
  'manque_fourniture': 'Manque de fourniture',
  'absence': 'Absence',
  'changement_modele': 'Changement de modèle',
  'autre': 'Autre',
};
const double underTarget = 0.80;
const double longStopMin = 15.0;
const double minElapsedForAlert = 15.0;

/// Copie figée des stations d'un calcul (opérations, ouvriers, temps).
Map<String, dynamic> buildPlan(BalanceResult r, Problem? problem) {
  final ops = {for (final o in problem?.operations ?? const <Operation>[]) o.id: o};
  final workers = {for (final w in problem?.workers ?? const <Worker>[]) w.id: w};
  final stations = <Map<String, dynamic>>[];
  for (final sd in r.stationDetails) {
    final shares = sd.shares ?? const <String, double>{};
    final total = sd.totalTime;
    final opIds = sd.operations;
    final opList = <Map<String, dynamic>>[];
    for (final oid in opIds) {
      double? minutes = shares[oid] ?? ops[oid]?.duration;
      if (minutes == null && opIds.length == 1) minutes = total;
      opList.add({
        'id': oid,
        'name': ops[oid]?.name ?? '',
        'minutes': pyRound(minutes ?? 0, 4),
        'shared': shares.containsKey(oid),
      });
    }
    final workerIds = List<String>.of(sd.workerIds ?? const []);
    final names = sd.workers.isNotEmpty ? List<String>.of(sd.workers) : [for (final w in workerIds) workers[w]?.name ?? w];
    stations.add({
      'station': sd.station,
      'operations': opList,
      'workers': names,
      'worker_ids': workerIds,
      'operators': math.max(1, sd.parallel),
      'minutes': pyRound(total, 4),
      'load_pct': sd.loadPct,
      'machine_types': sd.machineTypes ?? const <String>[],
      'workstations': sd.allWorkstations,
    });
  }
  stations.sort((a, b) => (a['station'] as int).compareTo(b['station'] as int));
  Map<String, dynamic>? bn;
  for (final s in stations) {
    if (bn == null ||
        (s['minutes'] as double) / (s['operators'] as int) > (bn['minutes'] as double) / (bn['operators'] as int)) {
      bn = s;
    }
  }
  var sam = 0.0, operators = 0;
  for (final s in stations) {
    sam += s['minutes'] as double;
    operators += s['operators'] as int;
  }
  return {
    'stations': stations,
    'cycle_time': r.actualCycleTime > 0 ? r.actualCycleTime : null,
    'takt_time': r.targetCycleTime > 0 ? r.targetCycleTime : problem?.targetCycleTime,
    'sam_total': pyRound(sam, 4),
    'operators': operators,
    'bottleneck_station': bn?['station'],
    'problem_name': problem?.name ?? '',
    'solver': r.solver,
  };
}

double? defaultTargetPerHour(Map<String, dynamic> plan) {
  final c = (plan['cycle_time'] ?? plan['takt_time']) as num?;
  return c != null && c > 0 ? pyRound(60.0 / c, 1) : null;
}

double? _r(double? v, [int d = 1]) => v == null ? null : pyRound(v, d);

DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

(DateTime, DateTime) shiftWindow(Map<String, dynamic> session) {
  final d = DateTime.tryParse((session['session_date'] ?? '').toString()) ?? DateTime.now();
  final st = (session['shift_start'] ?? '08:00').toString().split(':');
  final h = int.tryParse(st[0]) ?? 8;
  final m = st.length > 1 ? int.tryParse(st[1]) ?? 0 : 0;
  final start = DateTime(d.year, d.month, d.day, h, m);
  final hours = ((session['shift_hours'] ?? 8) as num).toDouble();
  return (start, start.add(Duration(seconds: (hours * 3600).round())));
}

DateTime _stopTime(Map<String, dynamic> session, DateTime now) {
  final (_, end) = shiftWindow(session);
  var t = now;
  if (session['status'] == 'closed') t = _dt(session['closed_at']) ?? end;
  return t.isBefore(end) ? t : end;
}

double _minutes(DateTime a, DateTime b) => b.difference(a).inMilliseconds / 60000.0;

/// Tableau de bord d'une session (même JSON que l'API).
Map<String, dynamic> productionDashboard(Map<String, dynamic> session, List<Map<String, dynamic>> entries,
    {DateTime? now}) {
  now ??= DateTime.now();
  final plan = (session['plan'] as Map?)?.cast<String, dynamic>() ?? {};
  final stations = [for (final s in (plan['stations'] as List? ?? [])) (s as Map).cast<String, dynamic>()];
  final order = [for (final s in stations) s['station'] as int];
  final bySt = {for (final s in stations) s['station'] as int: s};
  final targetH = ((session['target_per_hour'] ?? 0) as num).toDouble();
  final (start, end) = shiftWindow(session);
  final stop = _stopTime(session, now);
  final elapsed = math.max(0.0, _minutes(start, stop));
  final shiftMin = _minutes(start, end);

  final hours = <int>[];
  var t = DateTime(start.year, start.month, start.day, start.hour);
  while (t.isBefore(end)) {
    hours.add(t.hour);
    t = t.add(const Duration(hours: 1));
  }
  final hourTarget = <int, double>{};
  t = DateTime(start.year, start.month, start.day, start.hour);
  for (final h in List.of(hours)) {
    final a = t.isAfter(start) ? t : start;
    final tEnd = t.add(const Duration(hours: 1));
    final b = tEnd.isBefore(stop) ? tEnd : stop;
    hourTarget[h] = targetH * math.max(0.0, b.difference(a).inMilliseconds / 3600000.0);
    t = tEnd;
  }

  final live = entries.where((e) => e['voided'] != true).toList();
  for (final e in live) {
    final h = ((e['slot_hour'] ?? 0) as num).toInt();
    if (!hours.contains(h)) {
      hours.add(h);
      hourTarget.putIfAbsent(h, () => 0.0);
    }
    final st = ((e['station'] ?? 0) as num).toInt();
    if (!bySt.containsKey(st)) {
      bySt[st] = {'station': st, 'operations': [], 'workers': [], 'operators': 1, 'minutes': 0.0};
      order.add(st);
    }
  }
  order.sort();

  (double, bool) stopMinutes(Map<String, dynamic> e) {
    if (e['downtime_reason'] == null || e['downtime_reason'] == '') return (0.0, false);
    if (e['downtime_minutes'] != null) return ((e['downtime_minutes'] as num).toDouble(), false);
    final s = _dt(e['downtime_start']);
    if (s == null) return (0.0, false);
    final endt = session['status'] == 'closed' ? stop : now!;
    return (math.max(0.0, _minutes(s, endt)), true);
  }

  final stStats = <int, Map<String, dynamic>>{
    for (final n in order)
      n: {
        'pieces': 0,
        'defects': 0,
        'rework': 0,
        'downtime': 0.0,
        'absence': 0.0,
        'ongoing_stop': null,
        'by_hour': {for (final h in hours) h: 0},
      },
  };
  final reasons = {for (final k in downtimeReasons.keys) k: 0.0};
  final reasonsHour = {for (final h in hours) h: 0.0};
  final alerts = <Map<String, dynamic>>[];
  final stopsList = <Map<String, dynamic>>[];
  for (final e in live) {
    final stNo = ((e['station'] ?? 0) as num).toInt();
    final s = stStats[stNo]!;
    final h = ((e['slot_hour'] ?? 0) as num).toInt();
    final pcs = ((e['pieces'] ?? 0) as num).toInt();
    s['pieces'] = (s['pieces'] as int) + pcs;
    final bh = s['by_hour'] as Map<int, int>;
    bh[h] = (bh[h] ?? 0) + pcs;
    s['defects'] = (s['defects'] as int) + ((e['defects'] ?? 0) as num).toInt();
    s['rework'] = (s['rework'] as int) + ((e['rework'] ?? 0) as num).toInt();
    final (mins, ongoing) = stopMinutes(e);
    final reason = e['downtime_reason'];
    if (reason != null && reason != '') {
      s['downtime'] = (s['downtime'] as double) + mins;
      reasons[reason] = (reasons[reason] ?? 0.0) + mins;
      reasonsHour[h] = (reasonsHour[h] ?? 0.0) + mins;
      if (reason == 'absence') s['absence'] = (s['absence'] as double) + mins;
      final label = downtimeReasons[reason] ?? reason.toString();
      final item = {
        'station': stNo,
        'reason': reason,
        'label': label,
        'minutes': _r(mins),
        'ongoing': ongoing,
        'start': e['downtime_start'] ?? e['entered_at'],
        'slot_hour': h,
        'comment': e['comment'] ?? '',
        'id': e['id'],
        'client_id': e['client_id'],
      };
      stopsList.add(item);
      if (ongoing) s['ongoing_stop'] = item;
      if (mins > longStopMin) {
        alerts.add({
          'level': ongoing ? 'danger' : 'warning',
          'kind': 'long_stop',
          'station': stNo,
          'message': ongoing
              ? 'Station $stNo : arrêt en cours depuis ${pyFixed(mins, 0)} min (${label.toLowerCase()})'
              : 'Station $stNo : arrêt de ${pyFixed(mins, 0)} min à $h h (${label.toLowerCase()})',
        });
      }
    }
  }

  final expected = targetH * elapsed / 60;
  final last = order.isNotEmpty ? order.last : null;
  final output = last != null ? stStats[last]!['pieces'] as int : 0;
  final rows = <Map<String, dynamic>>[];
  var producedTotal = 0.0, presenceTotal = 0.0;
  for (final n in order) {
    final s = stStats[n]!, p = bySt[n]!;
    final ops = math.max(1, ((p['operators'] ?? 1) as num).toInt());
    final minutes = ((p['minutes'] ?? 0) as num).toDouble();
    final pieces = s['pieces'] as int;
    final produced = pieces * minutes;
    final presence = math.max(0.0, ops * elapsed - (s['absence'] as double));
    producedTotal += produced;
    presenceTotal += presence;
    final runMin = math.max(0.0, elapsed - (s['downtime'] as double) / ops);
    final realPp = pieces > 0 ? runMin * ops / pieces : null;
    final pct = expected >= 1 ? pieces / expected : null;
    final bh = s['by_hour'] as Map<int, int>;
    rows.add({
      'station': n,
      'operations': [for (final o in (p['operations'] as List? ?? [])) (o as Map)['id']],
      'workers': p['workers'] ?? [],
      'operators': ops,
      'planned_minutes': p['minutes'],
      'planned_per_operator': _r(minutes / ops, 3),
      'pieces': pieces,
      'expected': _r(expected),
      'pct_target': _r(pct != null ? pct * 100 : null),
      'defects': s['defects'],
      'rework': s['rework'],
      'downtime_minutes': _r(s['downtime'] as double),
      'produced_minutes': _r(produced),
      'presence_minutes': _r(presence),
      'efficiency': _r(presence > 0 ? produced / presence * 100 : null),
      'real_minutes_per_piece': _r(realPp, 3),
      'by_hour': [
        for (final h in hours) {'hour': h, 'pieces': bh[h] ?? 0, 'target': _r(hourTarget[h] ?? 0.0)},
      ],
      'ongoing_stop': s['ongoing_stop'],
    });
    if (pct != null && elapsed >= minElapsedForAlert && pct < underTarget && session['status'] == 'open') {
      alerts.add({
        'level': 'warning',
        'kind': 'under_target',
        'station': n,
        'message': 'Station $n à ${pyFixed(pct * 100, 0)} % de l\'objectif ($pieces / ${pyFixed(expected, 0)} pièces)',
      });
    }
  }

  final wip = [
    for (var i = 0; i + 1 < order.length; i++)
      {
        'between': [order[i], order[i + 1]],
        'pieces': math.max(0, (stStats[order[i]]!['pieces'] as int) - (stStats[order[i + 1]]!['pieces'] as int)),
      },
  ];
  int? observed;
  if (order.isNotEmpty && order.any((n) => (stStats[n]!['pieces'] as int) > 0)) {
    observed = order.first;
    int cmp(int a, int b) {
      final pa = stStats[a]!['pieces'] as int, pb = stStats[b]!['pieces'] as int;
      if (pa != pb) return pa.compareTo(pb);
      final da = stStats[a]!['downtime'] as double, db = stStats[b]!['downtime'] as double;
      if (da != db) return db.compareTo(da);
      final ma = ((bySt[a]!['minutes'] ?? 0) as num).toDouble(), mb = ((bySt[b]!['minutes'] ?? 0) as num).toDouble();
      return mb.compareTo(ma);
    }

    for (final n in order) {
      if (cmp(n, observed!) < 0) observed = n;
    }
  }
  final hourly = [
    for (final h in hours)
      {
        'hour': h,
        'target': _r(hourTarget[h] ?? 0.0),
        'output': last != null ? (stStats[last]!['by_hour'] as Map<int, int>)[h] ?? 0 : 0,
        'downtime_minutes': _r(reasonsHour[h] ?? 0.0),
      },
  ];
  var defects = 0, rework = 0, wipTotal = 0;
  for (final s in stStats.values) {
    defects += s['defects'] as int;
    rework += s['rework'] as int;
  }
  for (final w in wip) {
    wipTotal += w['pieces'] as int;
  }
  var downtimeTotal = 0.0;
  for (final v in reasons.values) {
    downtimeTotal += v;
  }
  int lvl(Map a) => a['level'] == 'danger' ? 0 : (a['level'] == 'warning' ? 1 : 2);
  final sortedAlerts = [for (var i = 0; i < alerts.length; i++) (i, alerts[i])]
    ..sort((a, b) => lvl(a.$2) != lvl(b.$2) ? lvl(a.$2).compareTo(lvl(b.$2)) : a.$1.compareTo(b.$1));
  return {
    'session_id': session['id'],
    'status': session['status'],
    'now': now.toIso8601String(),
    'shift_start': start.toIso8601String(),
    'shift_end': end.toIso8601String(),
    'elapsed_minutes': _r(elapsed),
    'shift_minutes': _r(shiftMin),
    'current_hour': now.hour,
    'target_per_hour': targetH,
    'target_shift': _r(targetH * shiftMin / 60),
    'expected_to_date': _r(expected),
    'output': output,
    'pct_target': _r(expected >= 1 ? output / expected * 100 : null),
    'efficiency': _r(presenceTotal > 0 ? producedTotal / presenceTotal * 100 : null),
    'produced_minutes': _r(producedTotal),
    'presence_minutes': _r(presenceTotal),
    'bottleneck_planned': plan['bottleneck_station'],
    'bottleneck_observed': observed,
    'wip': wip,
    'wip_total': wipTotal,
    'defects': defects,
    'rework': rework,
    'defect_rate': _r(output > 0 ? defects / output * 100 : null),
    'downtime_by_reason': [
      for (final e in reasons.entries) {'reason': e.key, 'label': downtimeReasons[e.key] ?? e.key, 'minutes': _r(e.value)},
    ],
    'downtime_total': _r(downtimeTotal),
    'hourly': hourly,
    'stations': rows,
    'stops': stopsList,
    'alerts': [for (final a in sortedAlerts) a.$2],
    'cycle_time': plan['cycle_time'],
    'takt_time': plan['takt_time'],
  };
}
