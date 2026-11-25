# Textile Line Balancer

Application d'**équilibrage de lignes de confection** (problème ALBP) pour les ateliers textiles :
on saisit la gamme opératoire (opérations, SAM, précédences), les postes et les ouvriers, et
l'application propose une répartition des opérations par poste qui respecte la cadence cible,
avec les indicateurs habituels (nombre de postes, rendement, retard d'équilibrage, indice de
régularité) et un graphique Yamazumi.

Une seule base de code Flutter pour **Windows, Linux, Web et Android**.

## Fonctionnalités (phase 1)

- **Gammes** : éditeur d'opérations (SAM, type de machine, section, précédences), postes et
  ouvriers ; import / export CSV et Excel ; exemple « chemise homme » intégré.
- **Calcul local** : moteur RPW (*Ranked Positional Weight*) écrit en Dart, avec contraintes de
  machines, de postes et d'ouvriers, recherche de la cadence minimale et diagnostics
  (pré-contrôle des données, précédences, surcharges).
- **Résultats** : tableau des postes, Yamazumi, indicateurs, export.
- **Simulation simple** de la ligne (débit, goulot, encours) à partir d'un équilibrage.
- **Suivi de production** : saisie horaire sur tablette et tableau de bord.
- **Historique** des calculs par atelier.

## Modes d'utilisation

| Mode | Compte | Données | Calculs |
|------|--------|---------|---------|
| **Local** | aucun | stockées sur l'appareil (Hive ; IndexedDB sur le Web) | moteur RPW en Dart, 100 % hors ligne |
| **Cloud** | compte de l'application | ateliers = organisations, synchronisés avec le serveur | RPW local **ou** CP-SAT / simulation côté serveur |

En mode cloud, l'appareil garde une copie locale : on peut continuer à travailler sans réseau,
les opérations sont rejouées à la reconnexion. Le passage d'un mode à l'autre conserve les
données locales.

L'adresse de l'API et la configuration d'authentification peuvent être surchargées à la
compilation :

```bash
flutter build web --release \
  --dart-define=TLB_API_URL=https://votre-api.example.com \
  --dart-define=TLB_SUPABASE_URL=https://votre-projet.supabase.co \
  --dart-define=TLB_SUPABASE_KEY=sb_publishable_...
```

Seule une clé **publishable** (publique) doit être utilisée côté client ; l'isolation entre
ateliers est assurée par les règles RLS côté base.

## Prérequis

- Flutter **3.50** (Dart 3.14)
- `flutter pub get` à la racine du dépôt

## Compilation par plateforme

| Plateforme | Commande | Sortie |
|------------|----------|--------|
| Web | `flutter build web --release` | `build/web/` |
| Linux | `flutter build linux --release` | `build/linux/<arch>/release/bundle/` |
| Windows | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |

Dépendances Linux (Debian / Ubuntu) :

```bash
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev
```

Android : JDK 21 (requis par le plugin Android Gradle 9 ; le code est compilé en Java 17) et SDK Android. L'APK de release est pour l'instant signé avec la clé de
débogage (installation directe ; la signature Play Store est prévue en phase 2).

Windows : Visual Studio 2022 avec la charge « Développement Desktop en C++ ».

## Tests

```bash
flutter analyze --no-fatal-infos
flutter test
```

La suite comprend :

- **Tests de parité** (`test/engine_parity_test.dart`, `test/engine_misc_test.dart`) : le moteur
  Dart est comparé, cas par cas, aux résultats du moteur Python de référence (équilibrage RPW,
  cadence minimale, diagnostics, lecture des CSV, arrondis identiques à Python). Les fixtures
  sont dans `test/fixtures/` et sont régénérées avec `tool/parity/gen_fixtures.py`.
- Tests du parcours hors ligne (`test/offline_flow_test.dart`).
- Tests d'écrans à trois tailles (téléphone, tablette, bureau) et test de démarrage.

Exemple de contrôle (chemise homme du manuel) : 21 opérations, SAM total 16,50 min,
N_min = 11 postes à la cadence 1,5 min.

## Intégration continue

`.github/workflows/flutter-build.yml` : analyse, tests, puis builds Linux, Windows (zip),
Web et APK Android publiés comme artefacts ; le build Web de `main` est déployé sur
Cloudflare Pages.

## Structure

```
lib/
  engine/     moteur d'équilibrage (RPW, diagnostics, simulation, production) — Dart pur
  data/       stockage local, dépôt, client API, import / export
  state/      état de l'application (modes local / cloud, synchronisation)
  features/   écrans (gammes, calcul, résultats, simulation, production, historique…)
  ui/         thème, coque de navigation, composants communs
test/         tests et fixtures de parité
tool/parity/  génération des fixtures depuis le moteur Python de référence
```

Feuille de route : voir [docs/ROADMAP.md](docs/ROADMAP.md).
