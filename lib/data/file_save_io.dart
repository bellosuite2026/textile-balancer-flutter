import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

Future<String?> saveBytes(String fileName, Uint8List bytes, String mime) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Enregistrer', fileName: fileName, bytes: bytes);
    return path == null ? null : 'Fichier enregistré.';
  }
  String? path;
  try {
    path = await FilePicker.platform.saveFile(dialogTitle: 'Enregistrer sous', fileName: fileName);
  } catch (_) {
    // Linux sans zenity/kdialog : on enregistre dans Téléchargements.
    final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    path = '${dir.path}${Platform.pathSeparator}$fileName';
  }
  if (path == null) return null;
  await File(path).writeAsBytes(bytes, flush: true);
  return 'Enregistré : $path';
}
