/// Textile Line Balancer — application Flutter (Windows, Linux, Web, Android).
library;

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app.dart';
import 'data/api_client.dart';
import 'data/local_store.dart';
import 'data/repository.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'fr_FR';
  await initializeDateFormatting('fr_FR');
  final store = HiveLocalStore();
  await store.open();
  final api = ApiClient();
  try {
    await ApiClient.initSupabase();
  } catch (_) {
    // Hors ligne au démarrage : le mode local reste disponible.
  }
  final state = AppState(repo: Repository(store), api: api);
  await state.init();
  runApp(TextileBalancerApp(state: state));
}
