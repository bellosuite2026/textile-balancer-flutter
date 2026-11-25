/// Simulation simple et déterministe d'une ligne en série (hors ligne).
///
/// Modèle : stations dans l'ordre du résultat d'équilibrage, chacune avec
/// `opérateurs` serveurs en parallèle ; temps par pièce et par serveur =
/// temps de station × opérateurs / efficience ; matière illimitée en tête ;
/// encours limité entre stations (blocage amont si le tampon aval est plein) ;
/// transport fixe entre stations. Sert à estimer débit, encours, temps de
/// traversée et goulot sans serveur. La simulation détaillée (variabilité,
/// pannes, convoyeur, réplications) reste côté API (`/simulation/:runId`).
library;

import 'dart:math' as math;

import 'models.dart';
import 'pyfmt.dart';

class SimStation {
  final int station;
  final double minutesPerPiece; // par opérateur (total_time)
  final int operators;
  final List<String> operations;
  const SimStation(this.station, this.minutesPerPiece, this.operators, [this.operations = const []]);
}

class SimConfig {
  final double durationMinutes;
  final double efficiency; // 1.0 = 100 %
  final int bufferCapacity; // pièces max entre deux stations
  final int initialWipPerBuffer;
  final double transportMinutes;
  final double variability; // coefficient de variation (0 = déterministe)
  final int seed;
  final bool useWorkerTimes;
  const SimConfig({
    this.durationMinutes = 480,
    this.efficiency = 1.0,
    this.bufferCapacity = 10,
    this.initialWipPerBuffer = 0,
    this.transportMinutes = 0,
    this.variability = 0,
    this.seed = 42,
    this.useWorkerTimes = true,
  });
}

class SimStationStats {
  final int station;
  final int operators;
  final double minutesPerPiece;
  int processed = 0;
  double busy = 0; // minutes·serveur
  double blocked = 0;
  double starved = 0;
  int maxQueue = 0;
  double queueArea = 0;
  SimStationStats(this.station, this.operators, this.minutesPerPiece);

  double utilization(double horizon) => horizon > 0 ? busy / (operators * horizon) : 0;
  double blockedPct(double horizon) => horizon > 0 ? blocked / (operators * horizon) : 0;
  double starvedPct(double horizon) => horizon > 0 ? starved / (operators * horizon) : 0;
  double avgQueue(double horizon) => horizon > 0 ? queueArea / horizon : 0;

  Map<String, dynamic> toJson(double h) => {
        'station': station,
        'operators': operators,
        'minutes_per_piece': pyRound(minutesPerPiece, 3),
        'processed': processed,
        'utilization_pct': pyRound(utilization(h) * 100, 1),
        'blocked_pct': pyRound(blockedPct(h) * 100, 1),
        'starved_pct': pyRound(starvedPct(h) * 100, 1),
        'avg_queue': pyRound(avgQueue(h), 2),
        'max_queue': maxQueue,
      };
}

class SimResult {
  final double horizon;
  final int completed;
  final double throughputPerHour;
  final double avgWip;
  final double avgLeadTimeMinutes;
  final int bottleneckStation;
  final List<SimStationStats> stations;
  final List<(double, int)> outputCurve; // (minute, pièces finies cumulées)
  const SimResult(this.horizon, this.completed, this.throughputPerHour, this.avgWip, this.avgLeadTimeMinutes,
      this.bottleneckStation, this.stations, this.outputCurve);

  Map<String, dynamic> toJson() => {
        'duration_minutes': horizon,
        'completed': completed,
        'throughput_per_hour': pyRound(throughputPerHour, 1),
        'avg_wip': pyRound(avgWip, 1),
        'avg_lead_time_minutes': pyRound(avgLeadTimeMinutes, 1),
        'bottleneck_station': bottleneckStation,
        'stations': [for (final s in stations) s.toJson(horizon)],
      };
}

/// Stations simulables à partir d'un résultat d'équilibrage.
List<SimStation> stationsFromResult(BalanceResult r, {bool useWorkerTimes = true}) => [
      for (final s in r.stationDetails)
        SimStation(
          s.station,
          (useWorkerTimes && s.workerTime != null && s.workerTime! > 0) ? s.workerTime! : s.totalTime,
          math.max(1, s.parallel),
          s.operations,
        ),
    ];

class _Server {
  double until = 0; // fin de la pièce en cours
  bool busy = false;
  bool holding = false; // pièce finie bloquée (aval plein)
  double since = 0; // début de l'état courant
}

/// Générateur pseudo-aléatoire déterministe (LCG) pour la variabilité.
class _Rng {
  int _s;
  _Rng(int seed) : _s = seed & 0x7fffffff;
  double next() {
    _s = (1103515245 * _s + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }

  /// Loi normale tronquée à ±2σ (Box-Muller), facteur multiplicatif ≥ 0,2.
  double factor(double cv) {
    if (cv <= 0) return 1;
    final u1 = math.max(1e-9, next()), u2 = next();
    final z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
    return math.max(0.2, 1 + cv * z.clamp(-2.0, 2.0));
  }
}

SimResult simulateLine(List<SimStation> stations, [SimConfig cfg = const SimConfig()]) {
  final n = stations.length;
  final horizon = cfg.durationMinutes;
  final stats = [for (final s in stations) SimStationStats(s.station, s.operators, s.minutesPerPiece)];
  if (n == 0) return SimResult(horizon, 0, 0, 0, 0, 0, stats, const []);
  final rng = _Rng(cfg.seed);
  final eff = cfg.efficiency > 0 ? cfg.efficiency : 1.0;
  final servers = [for (final s in stations) List.generate(s.operators, (_) => _Server())];
  // queue[i] = pièces en attente devant la station i (i >= 1) ; la station 0 est alimentée à volonté.
  final queue = List<int>.filled(n, 0);
  final cap = math.max(1, cfg.bufferCapacity);
  for (var i = 1; i < n; i++) {
    queue[i] = math.min(cap, cfg.initialWipPerBuffer);
  }
  // Transport : pièces en route vers la station i (heure d'arrivée)
  final transit = [for (var i = 0; i < n; i++) <double>[]];
  var t = 0.0;
  var completed = 0;
  var wipArea = 0.0;
  final curve = <(double, int)>[(0, 0)];

  int wipNow() {
    var w = 0;
    for (var i = 1; i < n; i++) {
      w += queue[i] + transit[i].length;
    }
    for (var i = 0; i < n; i++) {
      for (final s in servers[i]) {
        if (s.busy || s.holding) w++;
      }
    }
    return w;
  }

  double serviceTime(int i) =>
      stations[i].minutesPerPiece * stations[i].operators / eff * rng.factor(cfg.variability);

  int occupied(int i) => queue[i] + transit[i].length;

  void settle() {
    var changed = true;
    while (changed) {
      changed = false;
      // arrivées de transport
      for (var i = 1; i < n; i++) {
        final arrived = transit[i].where((a) => a <= t + 1e-12).length;
        if (arrived > 0) {
          transit[i].removeWhere((a) => a <= t + 1e-12);
          queue[i] += arrived;
          changed = true;
        }
      }
      // de l'aval vers l'amont : libérer les pièces bloquées, puis démarrer
      for (var i = n - 1; i >= 0; i--) {
        for (final s in servers[i]) {
          if (s.holding) {
            if (i == n - 1) {
              s.holding = false;
            } else if (occupied(i + 1) < cap) {
              if (cfg.transportMinutes > 0) {
                transit[i + 1].add(t + cfg.transportMinutes);
              } else {
                queue[i + 1]++;
              }
              s.holding = false;
            } else {
              continue;
            }
            stats[i].blocked += t - s.since;
            s.since = t;
            changed = true;
          }
          if (!s.busy && !s.holding) {
            final hasInput = i == 0 || queue[i] > 0;
            if (hasInput) {
              if (i > 0) queue[i]--;
              stats[i].starved += t - s.since;
              s.busy = true;
              s.since = t;
              s.until = t + serviceTime(i);
              changed = true;
            }
          }
        }
      }
    }
    for (var i = 1; i < n; i++) {
      stats[i].maxQueue = math.max(stats[i].maxQueue, queue[i]);
    }
  }

  settle();
  while (true) {
    var next = double.infinity;
    for (var i = 0; i < n; i++) {
      for (final s in servers[i]) {
        if (s.busy && s.until < next) next = s.until;
      }
      for (final a in transit[i]) {
        if (a < next) next = a;
      }
    }
    if (next > horizon || next.isInfinite) next = horizon;
    final dt = next - t;
    wipArea += wipNow() * dt;
    for (var i = 1; i < n; i++) {
      stats[i].queueArea += queue[i] * dt;
    }
    t = next;
    if (t >= horizon) break;
    for (var i = 0; i < n; i++) {
      for (final s in servers[i]) {
        if (s.busy && s.until <= t + 1e-12) {
          s.busy = false;
          stats[i].busy += t - s.since;
          stats[i].processed++;
          s.since = t;
          if (i == n - 1) {
            completed++;
            curve.add((t, completed));
          } else {
            s.holding = true;
          }
        }
      }
    }
    settle();
  }
  // clôture des états en cours
  for (var i = 0; i < n; i++) {
    for (final s in servers[i]) {
      final d = horizon - s.since;
      if (s.busy) {
        stats[i].busy += d;
      } else if (s.holding) {
        stats[i].blocked += d;
      } else {
        stats[i].starved += d;
      }
    }
  }
  final th = horizon > 0 ? completed / horizon * 60 : 0.0;
  final avgWip = horizon > 0 ? wipArea / horizon : 0.0;
  final lead = th > 0 ? avgWip / (th / 60) : 0.0;
  var bn = stats.first;
  for (final s in stats) {
    if (s.utilization(horizon) > bn.utilization(horizon) + 1e-9) bn = s;
  }
  if (curve.last.$1 < horizon) curve.add((horizon, completed));
  return SimResult(horizon, completed, th, avgWip, lead, bn.station, stats, curve);
}
