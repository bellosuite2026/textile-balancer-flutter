/// Bibliothèque de machines et zones du plan d'atelier.
///
/// GÉNÉRÉ depuis `engine/machine_library.py` / `engine/workshop.py` (dépôt Python de référence,
/// `GET /v1/orgs/{org}/workshop-catalog`). Mètres : w = largeur (le long de la table), d = profondeur.
library;

class MachineSpec {
  final String type;
  final String label;
  final double w;
  final double d;
  final String machineType;
  final String category;
  final String shape;
  const MachineSpec(this.type, this.label, this.w, this.d, this.machineType, this.category, this.shape);
  bool get isWorkstation => machineType.isNotEmpty;
}

const machineCatalog = <String, MachineSpec>{
  "piqueuse_plate": MachineSpec("piqueuse_plate", "Piqueuse plate 1 aiguille", 1.2, 0.6, "piqueuse_plate", "piqure", "sew_flat"),
  "piqueuse_2_aiguilles": MachineSpec("piqueuse_2_aiguilles", "Piqueuse 2 aiguilles", 1.2, 0.6, "piqueuse_2_aiguilles", "piqure", "sew_flat"),
  "piqueuse_triple_entrainement": MachineSpec("piqueuse_triple_entrainement", "Piqueuse à triple entraînement", 1.2, 0.6, "piqueuse_triple_entrainement", "piqure", "sew_flat"),
  "piqueuse_colonne": MachineSpec("piqueuse_colonne", "Piqueuse à colonne", 1.2, 0.55, "piqueuse_colonne", "piqure", "sew_post"),
  "piqueuse_bras": MachineSpec("piqueuse_bras", "Piqueuse à bras (canon)", 1.2, 0.55, "piqueuse_bras", "piqure", "sew_arm"),
  "zigzag": MachineSpec("zigzag", "Zigzag", 1.2, 0.55, "zigzag", "piqure", "sew_flat"),
  "surjeteuse_3_fils": MachineSpec("surjeteuse_3_fils", "Surjeteuse 3 fils", 1.05, 0.55, "surjeteuse_3_fils", "surjet", "sew_overlock"),
  "surjeteuse_4_fils": MachineSpec("surjeteuse_4_fils", "Surjeteuse 4 fils", 1.05, 0.55, "surjeteuse_4_fils", "surjet", "sew_overlock"),
  "surjeteuse_5_fils": MachineSpec("surjeteuse_5_fils", "Surjeteuse 5 fils (point de sécurité)", 1.1, 0.55, "surjeteuse_5_fils", "surjet", "sew_overlock"),
  "recouvreuse": MachineSpec("recouvreuse", "Recouvreuse plateau", 1.2, 0.54, "recouvreuse", "surjet", "sew_flat"),
  "recouvreuse_bras": MachineSpec("recouvreuse_bras", "Recouvreuse à bras", 1.2, 0.54, "recouvreuse_bras", "surjet", "sew_arm"),
  "chainette": MachineSpec("chainette", "Chaînette multi-aiguilles", 1.2, 0.6, "chainette", "surjet", "sew_flat"),
  "point_invisible": MachineSpec("point_invisible", "Point invisible / ourleuse", 1.05, 0.55, "point_invisible", "surjet", "sew_overlock"),
  "feed_off_arm": MachineSpec("feed_off_arm", "Feed-off-the-arm (jean)", 1.05, 0.55, "feed_off_arm", "surjet", "sew_arm"),
  "pose_elastique": MachineSpec("pose_elastique", "Pose élastique / ceinture (multi-aiguilles)", 1.2, 0.6, "pose_elastique", "surjet", "sew_flat"),
  "piqueuse_boutonniere": MachineSpec("piqueuse_boutonniere", "Boutonnière droite", 1.2, 0.66, "piqueuse_boutonniere", "auto", "sew_auto"),
  "boutonniere_oeillet": MachineSpec("boutonniere_oeillet", "Boutonnière à œillet", 1.2, 0.8, "boutonniere_oeillet", "auto", "sew_auto"),
  "piqueuse_bouton": MachineSpec("piqueuse_bouton", "Pose-boutons", 1.2, 0.66, "piqueuse_bouton", "auto", "sew_auto"),
  "bride": MachineSpec("bride", "Bartack / brides", 1.2, 0.66, "bride", "auto", "sew_auto"),
  "pose_passants": MachineSpec("pose_passants", "Pose-passants", 1.2, 0.8, "pose_passants", "auto", "sew_auto"),
  "machine_poches_auto": MachineSpec("machine_poches_auto", "Machine à poches automatique", 1.4, 1.75, "machine_poches_auto", "auto", "sew_station"),
  "machine_pinces": MachineSpec("machine_pinces", "Machine à pinces", 1.2, 1.0, "machine_pinces", "auto", "sew_station"),
  "table_coupe": MachineSpec("table_coupe", "Table de coupe / matelassage", 6.0, 1.8, "table_coupe", "coupe", "cutting_table"),
  "chariot_matelasseur": MachineSpec("chariot_matelasseur", "Chariot matelasseur", 2.4, 0.9, "chariot_matelasseur", "coupe", "spreader"),
  "coupe_automatique": MachineSpec("coupe_automatique", "Coupe automatique (CAO)", 3.82, 2.62, "coupe_automatique", "coupe", "cutter_cad"),
  "scie_ruban": MachineSpec("scie_ruban", "Scie à ruban", 1.32, 1.2, "scie_ruban", "coupe", "bandknife"),
  "table_travail": MachineSpec("table_travail", "Table de préparation / paquetage", 1.6, 0.8, "table_travail", "coupe", "table"),
  "presse_thermocollage": MachineSpec("presse_thermocollage", "Presse / thermocolleuse en continu", 1.7, 1.1, "presse_thermocollage", "repassage", "fusing"),
  "table_repassage": MachineSpec("table_repassage", "Table à repasser aspirante", 1.55, 0.58, "table_repassage", "repassage", "ironing"),
  "mannequin_vapeur": MachineSpec("mannequin_vapeur", "Mannequin vapeur (form finisher)", 1.2, 1.0, "mannequin_vapeur", "repassage", "mannequin"),
  "presse_finition": MachineSpec("presse_finition", "Presse de finition", 1.4, 0.9, "presse_finition", "repassage", "press"),
  "table_controle": MachineSpec("table_controle", "Contrôle qualité / table d'inspection", 1.5, 0.8, "table_controle", "controle", "inspection"),
  "detecteur_aiguilles": MachineSpec("detecteur_aiguilles", "Détecteur de métaux / aiguilles (convoyeur)", 1.8, 0.9, "detecteur_aiguilles", "controle", "detector"),
  "etiqueteuse_emballage": MachineSpec("etiqueteuse_emballage", "Étiquetage / emballage", 1.8, 0.9, "etiqueteuse_emballage", "controle", "packing"),
  "rack_encours": MachineSpec("rack_encours", "Rack d'encours", 1.2, 0.5, "", "logistique", "rack"),
  "chariot": MachineSpec("chariot", "Chariot de paquets", 1.0, 0.6, "", "logistique", "cart"),
  "convoyeur_suspendu": MachineSpec("convoyeur_suspendu", "Convoyeur suspendu (UPS type Eton), poste", 1.5, 1.0, "", "logistique", "conveyor"),
  "palette_carton": MachineSpec("palette_carton", "Palette / cartons", 1.2, 0.8, "", "logistique", "pallet"),
};

const workshopZones = <String, String>{
  "coupe": "Coupe",
  "preparation": "Préparation",
  "montage": "Montage",
  "finition": "Finition",
  "repassage": "Repassage",
  "controle": "Contrôle",
  "stock": "Stock / magasin",
  "expedition": "Expédition",
};

/// Familles interchangeables quand le type exact manque (repli signalé).
const machineFamilies = <String, List<String>>{
  "surjeteuse": ["surjeteuse", "surjeteuse_3_fils", "surjeteuse_4_fils", "surjeteuse_5_fils"],
  "repassage": ["fer_repassage", "mannequin_vapeur", "presse_finition", "presse_vapeur", "repassage", "table_repassage"],
  "table": ["etiqueteuse_emballage", "manuel", "table", "table_controle", "table_preparation", "table_travail"],
  "piqueuse": ["piqueuse", "piqueuse_1_aiguille", "piqueuse_bras", "piqueuse_colonne", "piqueuse_plate", "piqueuse_triple_entrainement", "plate"],
  "thermo": ["presse_thermocollage", "thermocollage", "thermocolleuse"],
  "bouton": ["boutons", "piqueuse_bouton", "pose_bouton", "pose_boutons"],
  "boutonniere": ["boutonniere", "boutonniere_oeillet", "piqueuse_boutonniere"],
  "bride": ["bartack", "bride", "brides", "pose_passants"],
  "double": ["2_aiguilles", "double_aiguille", "piqueuse_2_aiguilles"],
  "recouvreuse": ["recouvreuse", "recouvreuse_bras"],
  "chainette": ["chainette", "feed_off_arm", "pose_elastique"],
};
