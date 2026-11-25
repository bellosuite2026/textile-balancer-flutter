import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Windows : %APPDATA%\...\textile_balancer ; Linux : ~/.local/share/... ; Android : dossier privé de l'app.
Future<String?> localStoragePath() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}tlb_data');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir.path;
}
