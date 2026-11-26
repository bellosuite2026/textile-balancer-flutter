# Librairies 2D / 3D — étude et choix (phase 2, lot 2)

Cibles obligatoires : **Web (CanvasKit / skwasm), Windows, Linux, Android**. Toute librairie retenue doit
fonctionner sur les quatre, ou avoir un repli documenté.

Besoin : éditeur de plan d'atelier vectoriel (CAO légère, mètres), jumeau 2D animé et jumeau 3D d'une ligne
d'environ 40 machines + opératrices + paquets, à 60 images/s, sur un PC d'atelier ou une tablette Android
d'entrée de gamme.

Chiffres relevés le 26/11/2026 sur l'API pub.dev (`/api/packages/<nom>` et `/score`) : dernière version,
date de publication, j'aime, points pub, téléchargements sur 30 jours, plateformes déclarées, licence.

## 1. Tableau comparatif

| Paquet | Version (date) | J'aime · points · DL 30 j | Plateformes déclarées | Licence | Rôle possible | Verdict |
|---|---|---|---|---|---|---|
| **Flutter SDK** (`CustomPainter`, `Canvas.drawVertices`, `Listener`, `Shortcuts`) | 3.50 | — | les 4 | BSD-3 | éditeur, 2D, 3D logiciel | **retenu** |
| **vector_math** | 2.4.4 (26/10/2026) | 382 · 150/160 · 14,3 M | les 4 (+ wasm) | BSD-3 | matrices 4×4, projection, caméra | **retenu** (3D) |
| **printing** | 5.15.1 (19/09/2026) | 1 813 · 150/160 · 1,34 M | les 4 (+ wasm) ; pdfium natif sur Windows/Linux, pdf.js sur Web | Apache-2.0 | import PDF → image (page 1) | **retenu** (import PDF) |
| flame | 1.38.2 (27/08/2026) | 2 340 · 150/160 · 178 k | les 4 (+ wasm), Flutter Favorite | MIT | boucle de jeu 2D, sprites | écarté (voir §2) |
| flame_forge2d | 0.20.0 (17/08/2026) | 82 · 160/160 · 3,8 k | les 4 | MIT | physique 2D | inutile (pas de physique) |
| flame_isometric | 0.4.2 (29/04/2023) | 17 · 140/160 · 83 | les 4 | MIT | tuiles isométriques | non maintenu |
| flutter_scene (+ flutter_gpu) | 0.24.6 (24/11/2026) | 380 · 150/160 · 59,5 k | les 4 ; Web via un backend WebGL2 intégré | MIT | moteur 3D complet (PBR, glTF, ombres) | **piste d'évolution** (voir §4) |
| flutter_gpu (pub) | 0.0.1 (2023, non listé) | 7 · 130 · 1,3 k | — | BSD-3 | API GPU bas niveau (fournie par le SDK) | via flutter_scene seulement |
| three_js (port Dart) | 0.3.0 (02/05/2026) | 76 · 150/160 · 10,6 k | les 4, via `flutter_angle` (plugin natif ANGLE) | MIT | API three.js | repli possible, jeune |
| three_dart | 0.0.16 (19/11/2022) | 201 · 120/160 · 203 | pas Linux, pas Web | MIT | three.js | abandonné |
| flutter_angle | 0.4.2 (10/08/2026) | 40 · 140/160 · 7,8 k | les 4 (plugin) | MIT | contexte OpenGL ES/WebGL | dépendance de three_js |
| flutter_3d_controller | 2.3.0 (13/09/2025) | 381 · 140/160 · 8,2 k | Android, iOS, macOS, Web — **pas Windows/Linux** | MIT | visionneuse glTF (WebView) | écarté |
| model_viewer_plus | 1.10.0 (26/11/2025) | 340 · 150/160 · 49 k | Android, iOS, Web — **pas de bureau** | Apache-2.0 | `<model-viewer>` en WebView | écarté |
| o3d | 3.1.3 (17/12/2024) | 206 · 130/160 · 613 | Android, iOS, Web | BSD-3 | idem | écarté |
| ditredi | 2.0.2 (16/12/2023) | 185 · 150/160 · 1,3 k | les 4 (+ wasm) | MIT | 3D logicielle sur Canvas (tri des faces) | même principe que notre choix, mais figé depuis 2023 |
| flutter_cube | 0.1.1 (13/03/2021) | 334 · 130/160 · 22 k | **pas Web** | Apache-2.0 | OBJ sur Canvas | abandonné |
| rive | 0.14.11 (03/08/2026) | 1 952 · 140/160 · 563 k | les 4 (+ wasm) | MIT | animations vectorielles d'éditeur | hors besoin (pas d'assets Rive) ; possible pour pictos animés |
| graphview | 1.5.1 (17/10/2025) | 518 · 130/160 · 49,5 k | les 4 | MIT | graphes (Process Flow) | déjà couvert par notre disposition maison |
| flutter_svg | 2.5.1 (25/11/2026) | 5 943 · 160/160 · 7 M | les 4, Flutter Favorite | MIT | icônes / symboles SVG | facultatif (symboles machines dessinés au Canvas) |
| perfect_freehand | 2.5.2+1 (26/01/2026) | 193 · 160/160 · 4 k | les 4 | MIT | traits à main levée | hors besoin (plan vectoriel, pas de croquis) |
| flutter_drawing_board | 1.0.1+2 (20/01/2026) | 269 · 160/160 · 1,5 k | les 4 | MIT | tableau de dessin bitmap | inadapté (pas d'objets métier, pas de cotes) |
| pdfrx | 3.2.0 (26/11/2026) | 357 · 160/160 | les 4 (pdfium natif / wasm) | MIT | rendu PDF | alternative à `printing` |
| pdfx | 2.11.0 | 531 · 150/160 | **pas Linux** | MIT | rendu PDF | écarté |
| pdf_render | 1.4.12 (2024) | 223 · 60/160 | — | MIT | rendu PDF | écarté |
| `InteractiveViewer` (SDK) | — | — | les 4 | BSD-3 | zoom / déplacement | non : il capte les gestes dont l'éditeur a besoin ; zoom/pan faits à la main |

## 2. Recommandations

1. **Éditeur de plan → Flutter SDK seul (`CustomPainter` + `Listener` + `Shortcuts`/`Focus`), `printing` pour l'import PDF.**
   Le plan est un modèle vectoriel métier (murs, machines, cotes, convoyeurs) en mètres, synchronisé avec
   `/workshop-plans` : aucune librairie de dessin ne connaît ce modèle, et toutes (drawing_board, freehand)
   produisent des traits bitmap. Le Canvas de Flutter dessine 1 000+ éléments sans effort ; la logique
   (historique, sélection, aimantation, cotes, chemin à pied A*) est en Dart pur dans
   `lib/engine/plan_edit.dart`, donc testable sans écran. `printing` (Apache-2.0, 4 plateformes) rastérise la
   1re page d'un PDF : pdf.js sur le Web, pdfium sur Windows/Linux/Android.
2. **Jumeau 2D → `CustomPainter` + `Ticker` (déjà en place).**
   Flame apporte une boucle de jeu, des composants et des sprites, mais notre animation est une lecture d'une
   trace pré-calculée (`TwinTrace.at(t)`) : un seul `CustomPainter` redessiné par un `Ticker` suffit pour
   40 postes et quelques centaines de paquets à 60 i/s, sans dépendance ni second modèle d'objets.
3. **Jumeau 3D → moteur 3D logiciel maison sur `vector_math` + `Canvas.drawVertices`** (`lib/engine/scene3d.dart`
   + `lib/features/twin/twin3d_view.dart`).
   Pourquoi : fonctionne à l'identique sur les **4 cibles sans drapeau, sans plugin natif, sans build hook**,
   et même dans les tests de widgets ; une scène de 40 machines détaillées ≈ 5 000 triangles, triés par
   profondeur (algorithme du peintre) et dessinés en **un seul appel** `drawVertices` — largement sous le
   budget de 16 ms en CanvasKit comme en Skia/Impeller. Ombrage plat (lumière directionnelle + ambiante),
   caméra orbitale, styles simple/détaillé, opératrices et paquets animés, goulot en rouge.
   Limites assumées : pas d'ombres portées ni de textures, pas de glTF ; des faces qui s'interpénètrent
   peuvent mal se trier (atténué par des volumes disjoints et un tri par triangle).

## 3. Platformes et replis

| Cible | Éditeur | 2D | 3D | Import PDF |
|---|---|---|---|---|
| Web (CanvasKit / skwasm) | oui | oui | oui (Canvas, pas besoin de WebGL côté app — CanvasKit l'utilise lui-même) | oui (pdf.js chargé par `printing`) |
| Windows | oui | oui | oui | oui (pdfium téléchargé au build CMake) |
| Linux | oui | oui | oui | oui (pdfium téléchargé au build CMake) |
| Android | oui | oui | oui | oui (PdfRenderer) |

Repli si l'import PDF échoue sur une machine (pdfium absent) : message clair + import d'une image PNG/JPG
(capture du PDF), qui reste toujours disponible.

## 4. Piste d'évolution 3D : flutter_scene

`flutter_scene` 0.24.6 (Flutter GPU, auteur d'Impeller) annonce désormais les 4 cibles, le Web via un
backend WebGL2 intégré, avec PBR, ombres, glTF. À évaluer dans un lot ultérieur pour un rendu « photo » :
il faut activer Flutter GPU dans `android/app/src/main/AndroidManifest.xml`, `linux/runner/my_application.cc`
et `windows/runner/main.cpp`, accepter son *build hook* (compilation des shaders) dans les 4 jobs de CI, et une
API encore en 0.x. Son rendu ne s'exécute pas dans `flutter test` : la logique de scène (`scene3d.dart`) a été
séparée du rendu pour pouvoir brancher ce backend plus tard sans toucher au reste.

## 5. Parité de l'éditeur de plan (React `/atelier/plan` → Flutter)

Inventaire de `web/src/pages/WorkshopPlan.tsx` et `web/src/lib/workshop.ts` (lecture seule) comparé à
`lib/features/workshop/` (état au commit e42917b, puis après ce lot).

| Fonction (React) | Avant (e42917b) | Après ce lot |
|---|---|---|
| Outil Sélection (V), clic, Maj/Ctrl+clic, case « sélection multiple » (tablette) | sélection simple | **fait** |
| Encadrement (glisser dans le vide) | non | **fait** |
| Déplacer la sélection (groupe), flèches (pas = grille, Maj = 0,5 m) | un élément | **fait** |
| Poignées : redimensionner ● et pivoter ◯ (pas 15°, Alt libre), extrémités de mur | non | **fait** (machine, poteau, allée, zone, porte ; extrémités de mur ; points de convoyeur/cote) |
| Outil Main (H), clic droit/milieu, molette, pincement | molette + glisser le vide | **fait** |
| Gomme (E) : toucher ou glisser sur plusieurs | non | **fait** (survol rouge à la souris) |
| Mesure (M) : distance, chaîne, surface, chemin à pied (A* autour des obstacles) | non | **fait** |
| Aimantation de la mesure (coins/centres machines, place opératrice, murs, faces de mur), Alt = libre | non | **fait** |
| Garder la cote sur le plan (élément `dim`), cotes sélectionnables/effaçables | non | **fait** |
| Aimantation à la grille (case « Aimantation », pas de grille réglable) | grille fixe | **fait** (`settings.snap`, `settings.grid`) |
| Mur aimanté aux extrémités voisines, mur libre (oblique) | mur H/V | **fait** (Maj = H/V) |
| Porte posée dans l'axe du mur le plus proche, issue de secours | porte libre | **fait** |
| Convoyeur suspendu (boucle, Entrée/double-clic/1er point pour fermer), longueur | non | **fait** |
| Dupliquer (Ctrl+D), numérotation M01, M02… | non | **fait** |
| Copier / coller (Ctrl+C / Ctrl+V), couper (Ctrl+X) | absent de React | **fait** (en plus) |
| Pivoter (R = 90°, Maj+R = −15°), sélection multiple | 90° / +15° | **fait** |
| Aligner en ligne / en colonne (centres), répartir | non | **fait** (+ répartir, en plus) |
| Tout sélectionner (Ctrl+A), Suppr/Retour arrière, Échap | non | **fait** |
| Annuler / rétablir (Ctrl+Z, Ctrl+Y, Ctrl+Maj+Z), 100 étapes, un geste = une étape | non | **fait** |
| Calques / visibilité | absent de React | **fait** (en plus : masquer/verrouiller par type, local) |
| Import fond PNG/JPG + calibrage 2 points | oui | oui |
| Import **PDF** (1re page) comme fond | non | **fait** (`printing`) |
| Import **DXF** (LINE / LWPOLYLINE / POLYLINE → murs, unité auto mm/cm/m) | non | **fait** |
| Outil « Déplacer le fond », opacité du fond, ajuster la salle au fond | non | **fait** |
| Propriétés : machine (repère, état, côté opératrice, station), mur (épaisseur), porte (largeur, issue), allée (principale), zone, convoyeur (hauteur, libellé) | partiel | **fait** |
| Contrôles (allées trop étroites, chevauchements, distance aux issues) | non | **fait** (chevauchements, largeurs d'allée, machines hors salle, absence d'issue) — distance à l'issue : **non** |
| Export PNG / PDF du plan | non | **non** (lot suivant) |
| Vue 3D du plan (PlanScene3D) | non | **fait** (onglet 3D de l'éditeur, même moteur que le jumeau) |
| Brouillon local, versions « actuel / projet », synchro `/workshop-plans` | oui (local + synchro) | oui ; contrat inchangé (champs locaux `background_local`, `ui_layers` non envoyés) |
| Fond d'image synchronisé (Supabase Storage) | non (local) | **non** (le fond reste sur l'appareil) |
