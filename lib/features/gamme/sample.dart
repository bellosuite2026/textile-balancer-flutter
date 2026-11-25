import 'package:flutter/services.dart' show rootBundle;

import '../../engine/engine.dart';

/// Exemple « chemise homme » du manuel : 21 opérations (SAM 16,50 min),
/// 14 postes, 19 ouvriers. Cadence 1,5 min → N_min = 11.
Future<Problem> loadChemiseExample() async {
  final sam = await rootBundle.loadString('assets/samples/exemple_chemise_SAM.csv');
  final postes = await rootBundle.loadString('assets/samples/exemple_chemise_postes.csv');
  final ouvriers = await rootBundle.loadString('assets/samples/exemple_chemise_ouvriers.csv');
  return Problem(
    name: 'Chemise homme (exemple)',
    targetCycleTime: 1.5,
    operations: parseSamCsv(sam),
    workstations: parseWorkstationsCsv(postes),
    workers: parseWorkersCsv(ouvriers),
  );
}
