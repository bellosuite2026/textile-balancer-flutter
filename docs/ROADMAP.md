# Feuille de route

## Phase 1 — livrée

- Moteur RPW en Dart, à parité avec le moteur Python de référence (tests de parité).
- Modes local (hors ligne) et cloud, stockage local, import / export CSV et Excel.
- Écrans : gammes, calcul, résultats + Yamazumi, simulation simple, suivi de production,
  historique, réglages.
- Builds Windows, Linux, Web et Android en intégration continue ; déploiement Web.

## Phase 2 — lot 1 livré (novembre 2026)

Section **Analyse** de l'application (et boutons depuis un résultat de calcul) :

- [x] **Jumeau numérique 2D** : ligne animée (paquets, encours, goulot, ouvrières),
  dispositions ligne / U / libre / plan, trois scénarios « et si » comparés, réel vs simulé ;
  moteur Dart à parité avec `engine/simulation.py` (hors ligne), API `/simulate` en ligne.
- [x] **Plan d'atelier** : grille, murs, allées, zones, poteaux, portes ; bibliothèque des
  machines du catalogue serveur ; glisser-déposer, rotation ; liaison machine ↔ station ;
  fond image calibré (2 points + distance) ; stockage local + synchronisation.
- [x] **Process Flow** (local, hors ligne) : graphe des précédences par niveaux (plus long
  chemin), nœuds code / libellé / SAM / machine, zoom et déplacement, couleurs par station et
  goulot depuis un résultat, chemin critique, précédences inconnues et cycles signalés,
  export PNG.
- [x] **Simulation détaillée via l'API** (en ligne) : scénarios (efficience, variabilité,
  pannes MTBF / MTTR, poste, paquets, absentéisme), réplications, intervalles de confiance à
  95 %, comparaison, production horaire, occupation des stations.
- [x] **Optimiseur Pareto** (en ligne) : objectifs de l'API (pièces / jour, coût minute,
  encours, marche + transport), contraintes (effectif, cadence), leviers ; front en tableau
  et nuage effectif × pièces / jour (couleur = occupation ou encours) ; solution recommandée
  et compromis équilibré ; « Appliquer » = simulation détaillée + implantation enregistrée.

## Phase 2 — reste à faire

### Visualisation
- **Jumeau numérique 3D**.
- Process Flow : éditeur de logique par blocs (type FlexSim) de l'application web
  (source, file, décision, lot…) et exécution par le moteur à événements discrets.

### Administration et données
- **Super admin** : gestion des organisations, des utilisateurs et des abonnements.
- **Exports PDF** générés sur l'appareil (fiches de poste, rapport d'équilibrage).
- **Conflits de synchronisation** : détection et écran de résolution quand un même élément
  est modifié hors ligne sur plusieurs appareils.

### Distribution
- **Installeurs Windows** : MSIX et Inno Setup, avec **signature de code**.
- **Android** : signature de release et publication sur le **Play Store**.

### Technique
- **Migration vers `material_ui`** (remplacement de `package:flutter/material.dart`, déprécié
  depuis Flutter 3.47) et des localisations Cupertino correspondantes.
