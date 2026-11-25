/// Ouverture et enregistrement de fichiers sur toutes les plateformes.
/// - Web : téléchargement via le navigateur ;
/// - Windows / Linux : boîte « Enregistrer sous », sinon dossier Téléchargements ;
/// - Android : sélecteur de documents du système.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'file_save_stub.dart' if (dart.library.js_interop) 'file_save_web.dart' if (dart.library.io) 'file_save_io.dart'
    as impl;

class PickedFile {
  final String name;
  final Uint8List bytes;
  PickedFile(this.name, this.bytes);
  String get extension => name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

Future<PickedFile?> pickFile({List<String> extensions = const ['csv', 'xlsx', 'json', 'txt']}) async {
  final r = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: extensions,
    withData: true,
  );
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.first;
  final bytes = f.bytes;
  if (bytes == null) return null;
  return PickedFile(f.name, bytes);
}

/// Enregistre [bytes] ; renvoie un message lisible (chemin ou « téléchargé »), null si annulé.
Future<String?> saveBytes(String fileName, Uint8List bytes, {String mime = 'application/octet-stream'}) =>
    impl.saveBytes(fileName, bytes, mime);
