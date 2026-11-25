/// Lecture des fichiers de gamme SAM, de postes et d'ouvriers (CSV ou lignes
/// d'un tableur), avec les mêmes alias de colonnes et la même réparation des
/// lignes « débordantes » que `engine/parsers.py`.
///
/// Formats (cf. manuel §4.2) :
/// - SAM : Op_ID ; Description ; SAM_min ; Predecesseurs ; Type_Machine ; Competences ; Section ; Optionnel
/// - Postes : Poste_ID ; Nom ; Type_Machine ; Disponible ; Max_Ouvriers ; Section
/// - Ouvriers : Ouvrier_ID ; Nom ; Competences ; Efficacite ; Disponible ; Poste_Assigne
library;

import 'models.dart';

const samColumns = <String, List<String>>{
  'op_id': ['op_id', 'operation_id', 'id', 'code', 'ref', 'numero', 'num', 'op_id', 'op-id'],
  'name': ['name', 'description', 'designation', 'libelle', 'operation', 'task', 'description'],
  'duration': ['duration', 'time', 'sam', 'sah', 'standard_time', 'std_time', 'minutes', 'min', 'value', 'sam_min'],
  'predecessors': ['predecessors', 'predecessor', 'pre', 'prev', 'dependencies', 'depends_on', 'antecedents', 'predecesseurs'],
  'machine_type': ['machine_type', 'machine', 'equipment', 'machine_code', 'equipement', 'type_machine'],
  'skills': ['skills', 'skill', 'competences', 'competence', 'qualification', 'qualifications'],
  'section': ['section', 'department', 'atelier', 'area', 'zone', 'workshop'],
  'optional': ['optional', 'facultatif', 'option', 'optionnel'],
};

const workstationColumns = <String, List<String>>{
  'id': ['id', 'code', 'station_id', 'poste_id'],
  'name': ['name', 'nom', 'designation', 'libelle'],
  'machine_type': ['machine_type', 'machine', 'equipment', 'type_machine', 'equipement'],
  'available': ['available', 'disponible', 'actif', 'active'],
  'max_workers': ['max_workers', 'max_ouvriers', 'capacity', 'capacite'],
  'section': ['section', 'department', 'atelier', 'area', 'zone'],
};

const workerColumns = <String, List<String>>{
  'id': ['id', 'code', 'worker_id', 'matricule', 'employee_id', 'ouvrier_id', 'ouvrier-id', 'operateur_id', 'operateur-id', 'personnel_id'],
  'name': ['name', 'nom', 'prenom', 'full_name', 'nom_complet'],
  'skills': ['skills', 'skill', 'competences', 'competence', 'qualifications', 'qualification'],
  'efficiency': ['efficiency', 'efficacite', 'performance', 'coefficient', 'ratio'],
  'available': ['available', 'disponible', 'actif', 'active', 'present'],
  'assigned_station': ['assigned_station', 'poste', 'station', 'affectation'],
};

String normalizeHeader(String h) => h
    .trim()
    .toLowerCase()
    .replaceAll(' ', '_')
    .replaceAll('-', '_')
    .replaceAll('(', '')
    .replaceAll(')', '');

/// Retire les accents pour reconnaître « Prédécesseurs », « Compétences »…
String _ascii(String s) {
  const from = 'àâäáãéèêëíìîïóòôöõúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

int? _matchColumn(List<String> headers, List<String> names, {bool normalizeNames = false}) {
  final norm = headers.map((h) => _ascii(normalizeHeader(h))).toList();
  final wanted = normalizeNames ? names.map(normalizeHeader).toList() : names;
  if (normalizeNames) {
    // ordre des alias d'abord (comme _parse_generic / parse_workstations_file)
    for (final p in wanted) {
      final i = norm.indexOf(p);
      if (i >= 0) return i;
    }
    return null;
  }
  for (var i = 0; i < norm.length; i++) {
    if (wanted.contains(norm[i])) return i;
  }
  return null;
}

/// Détecte le séparateur d'un CSV (; , tabulation |) sur la ligne d'en-tête.
String detectDelimiter(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  var best = ';';
  var bestN = 0;
  for (final d in [';', ',', '\t', '|']) {
    final n = d.allMatches(firstLine).length;
    if (n > bestN) {
      best = d;
      bestN = n;
    }
  }
  return best;
}

/// Lecteur CSV minimal (guillemets doubles, séparateur au choix, BOM retiré).
List<List<String>> parseCsvText(String text, {String? delimiter}) {
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final d = delimiter ?? detectDelimiter(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
      } else {
        cell.write(ch);
      }
      i++;
      continue;
    }
    if (ch == '"' && cell.isEmpty) {
      inQuotes = true;
    } else if (ch == d) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      cell.write(ch);
    }
    i++;
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

final _opIdRe = RegExp(r'^[A-Za-z]{0,6}[-_]?\d+[A-Za-z]?$');

/// Fusionne les cellules en trop d'une colonne « liste » écrite avec le même
/// séparateur que le fichier (ex. « a;b » dans un CSV « ; »).
/// [listCols] : indices des colonnes liste ; une colonne prédécesseurs est
/// passée en négatif-1 (`-(idx+1)`) et n'absorbe que des identifiants d'opération.
List<String> repairOverflow(List<String> row, int nHeaders, List<int?> listCols) {
  var r = List<String>.of(row);
  var extra = r.length - nHeaders;
  if (extra <= 0) return r;
  for (final spec in listCols) {
    if (extra <= 0) break;
    if (spec == null) continue;
    final isPred = spec < 0;
    final idx = isPred ? -spec - 1 : spec;
    if (idx >= r.length) continue;
    int take;
    if (isPred) {
      var k = 0;
      while (idx + k < r.length) {
        final v = r[idx + k].trim();
        if (!_opIdRe.hasMatch(v.isEmpty ? '-' : v)) break;
        k++;
      }
      take = (k - 1).clamp(0, extra);
    } else {
      take = extra;
    }
    if (take > 0) {
      final merged = r.sublist(idx, idx + take + 1).map((c) => c.trim()).where((c) => c.isNotEmpty).join(',');
      r = [...r.sublist(0, idx), merged, ...r.sublist(idx + take + 1)];
      extra -= take;
    }
  }
  while (extra > 0 && r.isNotEmpty && r.last.trim().isEmpty) {
    r = r.sublist(0, r.length - 1);
    extra -= 1;
  }
  return r;
}

List<String> _splitList(String s) =>
    s.replaceAll(',', ';').split(';').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();

String _at(List<String> row, int? col) => (col != null && col < row.length) ? row[col] : '';

/// Gamme SAM depuis des lignes (1re ligne = en-têtes).
List<Operation> parseSamRows(List<List<String>> rows) {
  if (rows.isEmpty) throw const FormatException('Fichier vide');
  final headers = rows.first;
  int? col(String k) => _matchColumn(headers, samColumns[k]!);
  final cId = col('op_id'), cName = col('name'), cDur = col('duration'), cPred = col('predecessors');
  final cMach = col('machine_type'), cSk = col('skills'), cSec = col('section'), cOpt = col('optional');
  if (cId == null || cDur == null) {
    throw FormatException('Colonnes obligatoires manquantes (Op_ID et SAM_min). Trouvées : ${headers.join(', ')}');
  }
  final out = <Operation>[];
  for (var i = 1; i < rows.length; i++) {
    var row = rows[i];
    if (row.isEmpty || row.every((c) => c.trim().isEmpty)) continue;
    row = repairOverflow(row, headers.length, [cPred == null ? null : -(cPred + 1), cSk]);
    final id = cId < row.length ? row[cId].trim() : 'OP${i + 1}';
    if (id.isEmpty) continue;
    final durStr = (cDur < row.length ? row[cDur] : '0').trim().replaceAll(',', '.');
    final dur = durStr.isEmpty ? 0.0 : double.tryParse(durStr);
    if (dur == null) continue; // ligne ignorée (comme Python)
    final name = cName != null && cName < row.length ? row[cName].trim() : id;
    final pred = _at(row, cPred).trim();
    final sk = _at(row, cSk).trim();
    final opt = _at(row, cOpt).trim().toLowerCase();
    out.add(Operation(
      id: id,
      name: name,
      duration: dur,
      predecessors: pred.isEmpty ? [] : _splitList(pred),
      machineType: _at(row, cMach).trim(),
      requiredSkills: sk.isEmpty ? [] : _splitList(sk),
      section: _at(row, cSec).trim(),
      optional: const {'1', 'true', 'oui', 'yes', 'x'}.contains(opt),
    ));
  }
  return out;
}

bool _avail(String v) => !const {'0', 'false', 'non', 'no', ''}.contains(v.trim().toLowerCase());

List<Workstation> parseWorkstationRows(List<List<String>> rows) {
  if (rows.isEmpty) return [];
  final headers = rows.first;
  int? col(String k) => _matchColumn(headers, workstationColumns[k]!, normalizeNames: true);
  final cId = col('id'), cName = col('name'), cMach = col('machine_type'), cAv = col('available');
  final cMax = col('max_workers'), cSec = col('section');
  final out = <Workstation>[];
  for (final row in rows.skip(1)) {
    final id = cId != null && cId < row.length ? row[cId] : '';
    if (id.isEmpty) continue;
    var maxW = 1;
    if (cMax != null && cMax < row.length) {
      maxW = int.tryParse(row[cMax].trim().isEmpty ? '1' : row[cMax].trim()) ?? 1;
    }
    out.add(Workstation(
      id: id,
      name: cName != null && cName < row.length ? row[cName] : id,
      machineType: _at(row, cMach),
      available: cAv != null && cAv < row.length ? _avail(row[cAv]) : true,
      maxWorkers: maxW,
      section: _at(row, cSec),
    ));
  }
  return out;
}

List<Worker> parseWorkerRows(List<List<String>> rows) {
  if (rows.isEmpty) return [];
  final headers = rows.first;
  int? col(String k) => _matchColumn(headers, workerColumns[k]!, normalizeNames: true);
  final cId = col('id'), cName = col('name'), cSk = col('skills'), cEff = col('efficiency');
  final cAv = col('available'), cAss = col('assigned_station');
  final out = <Worker>[];
  for (var row in rows.skip(1)) {
    if (row.isNotEmpty && row.length > headers.length) row = repairOverflow(row, headers.length, [cSk]);
    final id = cId != null && cId < row.length ? row[cId] : '';
    if (id.isEmpty) continue;
    final sk = _at(row, cSk).trim();
    var eff = 1.0;
    if (cEff != null && cEff < row.length) {
      final s = row[cEff].trim().replaceAll(',', '.');
      eff = double.tryParse(s.isEmpty ? '1.0' : s) ?? 1.0;
    }
    final ass = _at(row, cAss).trim();
    out.add(Worker(
      id: id,
      name: cName != null && cName < row.length ? row[cName] : id,
      skills: sk.isEmpty ? [] : _splitList(sk),
      efficiency: eff,
      available: cAv != null && cAv < row.length ? _avail(row[cAv]) : true,
      assignedStation: ass.isEmpty ? null : ass,
    ));
  }
  return out;
}

List<Operation> parseSamCsv(String text) => parseSamRows(parseCsvText(text));
List<Workstation> parseWorkstationsCsv(String text) => parseWorkstationRows(parseCsvText(text));
List<Worker> parseWorkersCsv(String text) => parseWorkerRows(parseCsvText(text));

/// Collage depuis Excel (tabulations), avec ou sans ligne d'en-têtes.
/// Sans en-têtes, l'ordre des colonnes est celui de la gamme SAM.
List<Operation> parsePastedOperations(String text) {
  final rows = parseCsvText(text.trimRight(), delimiter: '\t');
  if (rows.isEmpty) return [];
  final looksHeader = _matchColumn(rows.first, samColumns['op_id']!) != null &&
      _matchColumn(rows.first, samColumns['duration']!) != null;
  final withHeader = looksHeader
      ? rows
      : [
          ['Op_ID', 'Description', 'SAM_min', 'Predecesseurs', 'Type_Machine', 'Competences', 'Section', 'Optionnel'],
          ...rows,
        ];
  return parseSamRows(withHeader);
}

/// Écrit une gamme au format CSV « ; » (modèle SAM du manuel).
String operationsToCsv(List<Operation> ops) {
  String esc(String s) => (s.contains(';') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
  final b = StringBuffer('Op_ID;Description;SAM_min;Predecesseurs;Type_Machine;Competences;Section;Optionnel\n');
  for (final o in ops) {
    b.writeln([
      o.id,
      o.name,
      o.duration.toString(),
      o.predecessors.join(','),
      o.machineType,
      o.requiredSkills.join(','),
      o.section,
      o.optional ? 'TRUE' : 'FALSE',
    ].map(esc).join(';'));
  }
  return b.toString();
}
