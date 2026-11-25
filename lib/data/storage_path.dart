/// Dossier de données local (null sur le Web : Hive utilise IndexedDB).
library;

export 'storage_path_web.dart' if (dart.library.io) 'storage_path_io.dart';
