# Feuille de route

## Phase 1 — livrée

- Moteur RPW en Dart, à parité avec le moteur Python de référence (tests de parité).
- Modes local (hors ligne) et cloud, stockage local, import / export CSV et Excel.
- Écrans : gammes, calcul, résultats + Yamazumi, simulation simple, suivi de production,
  historique, réglages.
- Builds Windows, Linux, Web et Android en intégration continue ; déploiement Web.

## Phase 2 — prévue

### Visualisation
- **Jumeau numérique de la ligne** : d'abord en **2D** (postes, flux, encours, goulot animés),
  puis en **3D**.
- **Plan d'atelier** : disposition des postes et des machines, glisser-déposer, lien avec
  l'équilibrage.
- **Process Flow** : diagramme du flux des opérations et des précédences.

### Calcul
- **Interface de l'optimiseur Pareto** : comparaison des solutions (postes, rendement,
  régularité, ouvriers) et choix d'un compromis.
- **Simulation détaillée via l'API** (stochastique, pannes, absentéisme) avec restitution
  dans l'application.

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
