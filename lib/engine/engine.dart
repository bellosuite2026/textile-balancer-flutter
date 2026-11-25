/// Moteur d'équilibrage hors ligne (Dart pur : aucune dépendance Flutter).
///
/// - `models.dart` : modèle de données = schémas de l'API.
/// - `rpw.dart` : solveur RPW (multi-machines, partage, ouvriers) + cadence minimale.
/// - `diagnostics.dart` : diagnostic avant calcul, validation, KPI.
/// - `resources.dart` : partage des opérations, postes, ouvriers (méthode hongroise).
/// - `simulation.dart` : simulation déterministe simple d'une ligne.
/// - `production.dart` : plan figé et tableau de bord de production.
/// - `parsers.dart` : import CSV (gamme SAM, postes, ouvriers).
library;

export 'diagnostics.dart';
export 'models.dart';
export 'parsers.dart';
export 'production.dart';
export 'pyfmt.dart';
export 'resources.dart';
export 'rpw.dart';
export 'simulation.dart';
export 'twin.dart';
export 'workshop.dart';
