/// Exports d'un résultat d'équilibrage, générés sur l'appareil (hors ligne) :
/// CSV (« ; », virgule décimale, ouvrable dans Excel FR), Excel .xlsx et PDF.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../engine/engine.dart';

String _n(num? v, [int d = 3]) => v == null ? '' : fmtNum(v, d).replaceAll('\u202f', '').replaceAll(' ', '');

String _opsLabel(StationDetail s) => s.operations
    .map((o) => s.shares?[o] != null ? '$o (part ${_n(s.shares![o], 2)} min)' : o)
    .join(', ');

List<List<String>> stationRows(BalanceResult r) => [
      ['Station', 'Opérations', 'Temps (min)', 'Charge (%)', 'Postes parallèles', 'Machines', 'Poste(s)', 'Ouvrier(s)', 'Temps réel ouvrier (min)'],
      for (final s in r.stationDetails)
        [
          '${s.station}',
          _opsLabel(s),
          _n(s.totalTime),
          _n(s.loadPct, 1),
          '${s.parallel}',
          (s.machineTypes ?? const []).join(', '),
          s.allWorkstations.join(', '),
          s.workers.join(', '),
          _n(s.workerTime),
        ],
    ];

List<List<String>> summaryRows(BalanceResult r, Problem p) => [
      ['Indicateur', 'Valeur'],
      ['Gamme', p.name],
      ['Solveur', r.solver],
      ['Statut', r.compliant ? 'Conforme' : (r.success ? 'À vérifier' : 'Non conforme')],
      ['Cadence cible (min/pièce)', _n(r.targetCycleTime)],
      ['Travail total SAM (min)', _n(p.totalSam)],
      ['Stations théoriques minimum (N_min)', '${theoreticalMinStations(p.totalSam, r.targetCycleTime)}'],
      ['Stations', '${r.stationsUsed}'],
      ['Opérateurs', '${r.operators}'],
      ['Cycle réel (min)', _n(r.actualCycleTime)],
      ['Rendement ligne (%)', _n(r.efficiency, 1)],
      ['Perte d\'équilibrage (%)', _n(r.balanceDelay, 1)],
      ['Indice de lissage', _n(r.smoothnessIndex, 2)],
      ['Production (pièces/h)', _n(r.outputPerHour, 1)],
      ['Production (pièces / 8 h)', _n(r.outputPerHour * 8, 0)],
      ['Goulot', r.bottleneck == null ? '' : 'Station ${r.bottleneck!.station}'],
    ];

String _csv(List<List<String>> rows) {
  String esc(String s) => (s.contains(';') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
  return rows.map((r) => r.map(esc).join(';')).join('\r\n');
}

/// CSV UTF-8 avec BOM (accents corrects dans Excel).
Uint8List resultCsv(BalanceResult r, Problem p) {
  final text = '${_csv(summaryRows(r, p))}\r\n\r\n${_csv(stationRows(r))}\r\n';
  return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
}

Uint8List resultXlsx(BalanceResult r, Problem p) {
  final book = Excel.createExcel();
  final first = book.getDefaultSheet() ?? 'Sheet1';
  book.rename(first, 'Synthèse');
  void fill(String name, List<List<String>> rows) {
    final sh = book[name];
    for (final row in rows) {
      sh.appendRow([
        for (final c in row)
          (double.tryParse(c.replaceAll(',', '.')) != null && !c.contains(' '))
              ? DoubleCellValue(double.parse(c.replaceAll(',', '.')))
              : TextCellValue(c),
      ]);
    }
  }

  fill('Synthèse', summaryRows(r, p));
  fill('Stations', stationRows(r));
  fill('Opérations', [
    ['Op_ID', 'Désignation', 'SAM (min)', 'Prédécesseurs', 'Machine', 'Compétences', 'Section', 'Station'],
    for (final o in p.operations)
      [
        o.id,
        o.name,
        _n(o.duration),
        o.predecessors.join(','),
        o.machineType,
        o.requiredSkills.join(','),
        o.section,
        '${r.operationAssignments[o.id] ?? ''}',
      ],
  ]);
  fill('Points d\'attention', [
    ['Type', 'Message'],
    for (final v in r.violations) [v.code, v.toString()],
    for (final w in r.warnings) ['info', w],
  ]);
  book.setDefaultSheet('Synthèse');
  return Uint8List.fromList(book.encode() ?? const []);
}

/// Les polices PDF standard ne couvrent que le Latin-1 : on remplace le reste.
String _pdfSafe(String s) => s
    .replaceAll('→', '->')
    .replaceAll('≥', '>=')
    .replaceAll('≤', '<=')
    .replaceAll('⚠️', '!')
    .replaceAll('ℹ️', 'i')
    .replaceAll('…', '...')
    .replaceAll('’', "'")
    .replaceAll('«', '"')
    .replaceAll('»', '"')
    .replaceAll('\u202f', ' ')
    .replaceAll(RegExp(r'[^\x00-\xFF]'), '');

Future<Uint8List> resultPdf(BalanceResult r, Problem p, {String workshop = ''}) async {
  final doc = pw.Document(title: 'Équilibrage — ${p.name}', author: 'Textile Line Balancer');
  final c = r.targetCycleTime;
  final maxT = [c * 1.15, ...r.stationDetails.map((s) => s.totalTime)].reduce((a, b) => a > b ? a : b);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    header: (ctx) => pw.Text(_pdfSafe('Textile Line Balancer — ${workshop.isEmpty ? '' : '$workshop · '}${p.name}'),
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
    footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
    build: (ctx) => [
      pw.Text(_pdfSafe('Rapport d\'équilibrage'), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text(_pdfSafe('${p.name} · cadence ${_n(c)} min · ${r.solver} · ${fmtDate(DateTime.now())}'),
          style: const pw.TextStyle(fontSize: 10)),
      pw.SizedBox(height: 12),
      pw.TableHelper.fromTextArray(
        data: [for (final row in summaryRows(r, p).skip(1)) row.map(_pdfSafe).toList()],
        headers: const ['Indicateur', 'Valeur'],
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF1E3A5F)),
      ),
      pw.SizedBox(height: 14),
      pw.Text('Charge par station (min) — ligne rouge : cadence', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.Container(
        height: 150,
        child: pw.Stack(children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              for (final s in r.stationDetails)
                pw.Expanded(
                  child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
                    pw.Container(
                      height: 130 * (s.totalTime / maxT),
                      margin: const pw.EdgeInsets.symmetric(horizontal: 2),
                      color: s.totalTime > c + 1e-6
                          ? PdfColors.red400
                          : (s.totalTime >= 0.85 * c ? PdfColors.green600 : PdfColors.blue300),
                    ),
                    pw.Text('${s.station}', style: const pw.TextStyle(fontSize: 7)),
                  ]),
                ),
            ],
          ),
          pw.Positioned(
            left: 0,
            right: 0,
            bottom: 10 + 130 * (c / maxT),
            child: pw.Container(height: 1, color: PdfColors.red),
          ),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Text('Répartition', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const ['St.', 'Opérations', 'Temps', 'Charge', 'Poste(s)', 'Ouvrier(s)'],
        data: [
          for (final s in r.stationDetails)
            [
              '${s.station}${s.parallel > 1 ? ' x${s.parallel}' : ''}',
              _pdfSafe(_opsLabel(s)),
              _n(s.totalTime),
              '${_n(s.loadPct, 0)} %',
              s.allWorkstations.join(', '),
              _pdfSafe(s.workers.join(', ')),
            ],
        ],
        cellStyle: const pw.TextStyle(fontSize: 8),
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        columnWidths: {1: const pw.FlexColumnWidth(3), 5: const pw.FlexColumnWidth(2)},
      ),
      if (r.violations.isNotEmpty || r.warnings.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        pw.Text('Points d\'attention', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        for (final v in r.violations) pw.Bullet(text: _pdfSafe(v.toString()), style: const pw.TextStyle(fontSize: 8)),
        for (final w in r.warnings) pw.Bullet(text: _pdfSafe(w), style: const pw.TextStyle(fontSize: 8)),
      ],
    ],
  ));
  return doc.save();
}

/// Gamme (opérations + postes + ouvriers) en JSON ProblemIn.
Uint8List problemJson(Problem p) =>
    Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())));
