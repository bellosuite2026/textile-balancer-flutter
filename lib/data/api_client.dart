/// Client de l'API cloud Textile Line Balancer (FastAPI sur Render) + Supabase Auth.
///
/// Routes : voir `api/README.md` du dépôt Python. Authentification :
/// jeton d'accès Supabase transmis en `Authorization: Bearer` ; l'isolation
/// des ateliers est assurée par RLS côté Postgres.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../core/config.dart';
import '../engine/engine.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);

  /// Réseau absent, serveur en veille ou en erreur : l'opération peut être rejouée plus tard.
  bool get isTransient => status == 0 || status == 408 || status == 429 || status >= 500;

  @override
  String toString() => message;
}

enum AuthEvent { passwordRecovery, signedIn, signedOut, other }

/// Message d'erreur Supabase Auth en français clair.
String authErrorMessage(Object e) {
  final code = e is sb.AuthException ? (e.code ?? '') : '';
  final m = (e is sb.AuthException ? e.message : e.toString()).toLowerCase();
  bool has(String s) => code == s || m.contains(s);
  if (has('invalid_credentials') || m.contains('invalid login')) return 'E-mail ou mot de passe incorrect.';
  if (has('email_not_confirmed') || m.contains('email not confirmed')) {
    return 'Adresse e-mail non confirmée : cliquez sur le lien reçu par e-mail (vérifiez les indésirables).';
  }
  if (has('user_already_exists') || has('email_exists') || m.contains('already registered')) {
    return 'Un compte existe déjà avec cette adresse e-mail. Connectez-vous ou utilisez « Mot de passe oublié ».';
  }
  if (has('weak_password') || m.contains('password should be') || m.contains('at least')) {
    return 'Mot de passe trop faible : au moins 8 caractères, avec lettres et chiffres.';
  }
  if (has('same_password') || m.contains('different from the old')) {
    return 'Le nouveau mot de passe doit être différent de l\'ancien.';
  }
  if (has('email_address_invalid') || m.contains('invalid format') || m.contains('is invalid')) {
    return 'Adresse e-mail invalide.';
  }
  if (has('over_email_send_rate_limit') || has('over_request_rate_limit') || m.contains('rate limit') ||
      m.contains('security purposes')) {
    return 'Trop de demandes : patientez une minute avant de réessayer.';
  }
  if (has('signup_disabled') || m.contains('signups not allowed')) {
    return 'Les inscriptions sont fermées pour le moment. Contactez l\'administrateur.';
  }
  if (has('session_not_found') || has('session_expired') || m.contains('session missing') || m.contains('expired')) {
    return 'Lien expiré ou déjà utilisé : refaites une demande « Mot de passe oublié ».';
  }
  return e is sb.AuthException ? e.message : 'Erreur d\'authentification.';
}

class ApiClient {
  ApiClient({http.Client? httpClient, this.base = AppConfig.apiBase}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String base;
  static bool _supabaseReady = false;

  static Future<void> initSupabase() async {
    if (_supabaseReady) return;
    await sb.Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabasePublishableKey);
    _supabaseReady = true;
  }

  sb.GoTrueClient? get _auth => _supabaseReady ? sb.Supabase.instance.client.auth : null;

  String? get accessToken => _auth?.currentSession?.accessToken;
  String? get email => _auth?.currentUser?.email;
  bool get isSignedIn => accessToken != null;

  Future<void> signIn(String email, String password) async {
    final auth = _auth;
    if (auth == null) throw ApiException(0, 'Authentification indisponible.');
    try {
      await auth.signInWithPassword(email: email, password: password);
    } on sb.AuthException catch (e) {
      throw ApiException(_authStatus(e), authErrorMessage(e));
    } catch (e) {
      throw ApiException(0, 'Serveur d\'authentification injoignable. Vérifiez la connexion.');
    }
  }

  /// Adresse vers laquelle renvoient les liens des e-mails (confirmation, mot de passe).
  static String authRedirectUrl() {
    if (kIsWeb) {
      final o = Uri.base;
      if (o.scheme.startsWith('http') && o.host.isNotEmpty) return '${o.origin}/';
    }
    return AppConfig.webAppUrl;
  }

  /// Création de compte. Renvoie `true` si une session est ouverte tout de suite,
  /// `false` si l'adresse doit d'abord être confirmée par e-mail.
  Future<bool> signUp(String email, String password, {String? name}) async {
    final auth = _auth;
    if (auth == null) throw ApiException(0, 'Authentification indisponible.');
    sb.AuthResponse r;
    try {
      r = await auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: authRedirectUrl(),
        data: (name == null || name.trim().isEmpty) ? null : {'full_name': name.trim()},
      );
    } on sb.AuthException catch (e) {
      throw ApiException(_authStatus(e), authErrorMessage(e));
    } catch (e) {
      throw ApiException(0, 'Serveur d\'authentification injoignable. Vérifiez la connexion.');
    }
    // Supabase ne révèle pas qu'une adresse confirmée existe déjà : il renvoie un
    // utilisateur sans identité.
    final ids = r.user?.identities;
    if (r.session == null && ids != null && ids.isEmpty) {
      throw ApiException(409, 'Un compte existe déjà avec cette adresse e-mail. Connectez-vous ou utilisez « Mot de passe oublié ».');
    }
    return r.session != null;
  }

  Future<void> resetPassword(String email) async {
    final auth = _auth;
    if (auth == null) throw ApiException(0, 'Authentification indisponible.');
    try {
      await auth.resetPasswordForEmail(email, redirectTo: authRedirectUrl());
    } on sb.AuthException catch (e) {
      throw ApiException(_authStatus(e), authErrorMessage(e));
    } catch (e) {
      throw ApiException(0, 'Serveur d\'authentification injoignable. Vérifiez la connexion.');
    }
  }

  /// Nouveau mot de passe (session de récupération ouverte par le lien reçu par e-mail).
  Future<void> updatePassword(String password) async {
    final auth = _auth;
    if (auth == null) throw ApiException(0, 'Authentification indisponible.');
    try {
      await auth.updateUser(sb.UserAttributes(password: password));
    } on sb.AuthException catch (e) {
      throw ApiException(_authStatus(e), authErrorMessage(e));
    } catch (e) {
      throw ApiException(0, 'Serveur d\'authentification injoignable. Vérifiez la connexion.');
    }
  }

  /// Événements d'authentification utiles à l'application (récupération de mot de
  /// passe, connexion après le lien de confirmation).
  Stream<AuthEvent> get authEvents {
    final auth = _auth;
    if (auth == null) return const Stream.empty();
    return auth.onAuthStateChange.map((s) => switch (s.event) {
          sb.AuthChangeEvent.passwordRecovery => AuthEvent.passwordRecovery,
          sb.AuthChangeEvent.signedIn => AuthEvent.signedIn,
          sb.AuthChangeEvent.signedOut => AuthEvent.signedOut,
          _ => AuthEvent.other,
        }).handleError((_) {});
  }

  static int _authStatus(sb.AuthException e) => int.tryParse(e.statusCode ?? '') ?? 400;

  Future<void> signOut() async {
    try {
      await _auth?.signOut();
    } catch (_) {}
  }

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<dynamic> _send(String method, String path, {Object? body, Duration timeout = const Duration(seconds: 70)}) async {
    final uri = Uri.parse('$base$path');
    http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers());
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiException(0, 'Le serveur ne répond pas (il se réveille peut-être : réessayez dans une minute).');
    } catch (e) {
      throw ApiException(0, networkErrorMessage(e));
    }
    if (res.statusCode == 204) return null;
    final text = utf8.decode(res.bodyBytes);
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = {'detail': text.length > 200 ? text.substring(0, 200) : text};
    }
    if (res.statusCode >= 400) {
      final d = data is Map ? data['detail'] : null;
      final msg = d is String
          ? d
          : d is List
              ? d.map((e) => e is Map ? e['msg'] : e.toString()).join(' ; ')
              : null;
      throw ApiException(res.statusCode, httpErrorMessage(res.statusCode, msg));
    }
    return data;
  }

  Future<Uint8List> _bytes(String path) async {
    try {
      final res = await _http.get(Uri.parse('$base$path'), headers: _headers(json: false)).timeout(const Duration(seconds: 90));
      if (res.statusCode >= 400) throw ApiException(res.statusCode, 'Export impossible (${res.statusCode}).');
      return res.bodyBytes;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'Serveur injoignable : export impossible hors ligne.');
    }
  }

  // ------------------------------------------------------------ santé
  /// Ping `/health`. Render (offre gratuite) met jusqu'à ~1 min à sortir de veille :
  /// le premier essai attend [timeout], puis on réessaie [retries] fois.
  Future<bool> health({Duration timeout = const Duration(seconds: 60), int retries = 1}) async {
    for (var i = 0; i <= retries; i++) {
      try {
        final r = await _http.get(Uri.parse('$base/health')).timeout(timeout);
        if (r.statusCode == 200) return true;
      } catch (_) {}
      if (i < retries) await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  // ------------------------------------------------------------ compte
  Future<Map<String, dynamic>> me() async => (await _send('GET', '/v1/me') as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> createOrg(String name, {String country = 'TN'}) async =>
      (await _send('POST', '/v1/orgs', body: {'name': name, 'country': country}) as Map).cast<String, dynamic>();

  Future<List<Map<String, dynamic>>> lines(String org) async =>
      [for (final e in (await _send('GET', '/v1/orgs/$org/lines') as List)) (e as Map).cast<String, dynamic>()];

  // ------------------------------------------------------------ gammes
  Future<List<Map<String, dynamic>>> problems(String org, {int limit = 100}) async => [
        for (final e in (await _send('GET', '/v1/orgs/$org/problems?limit=$limit') as List)) (e as Map).cast<String, dynamic>()
      ];

  Future<Map<String, dynamic>> problem(String org, String id) async =>
      (await _send('GET', '/v1/orgs/$org/problems/$id') as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> saveProblem(String org, Problem p, {String? lineId}) async =>
      (await _send('POST', '/v1/orgs/$org/problems', body: {'problem': apiProblem(p), 'line_id': lineId}) as Map)
          .cast<String, dynamic>();

  // ------------------------------------------------------------ calculs
  Future<Map<String, dynamic>> createRun(
    String org, {
    Problem? problem,
    String? problemId,
    String kind = 'balance',
    String solver = 'rpw',
    int timeLimitSeconds = 20,
    double precision = 0.05,
    String? lineId,
  }) async =>
      (await _send('POST', '/v1/orgs/$org/runs', body: {
        'kind': kind,
        'solver': solver,
        if (problemId != null) 'problem_id': problemId else 'problem': apiProblem(problem!),
        'line_id': lineId,
        'time_limit_seconds': timeLimitSeconds,
        if (kind == 'min_cycle') 'precision': precision,
      }) as Map)
          .cast<String, dynamic>();

  Future<List<Map<String, dynamic>>> runs(String org, {int limit = 100}) async =>
      [for (final e in (await _send('GET', '/v1/orgs/$org/runs?limit=$limit') as List)) (e as Map).cast<String, dynamic>()];

  Future<Map<String, dynamic>> run(String org, String id) async =>
      (await _send('GET', '/v1/orgs/$org/runs/$id') as Map).cast<String, dynamic>();

  /// Export serveur : `json`, `xlsx` ou `pdf`.
  Future<Uint8List> runExport(String org, String id, String ext) => _bytes('/v1/orgs/$org/runs/$id/export.$ext');

  Future<PrecheckResult> precheck(Problem p) async =>
      PrecheckResult.fromJson((await _send('POST', '/v1/precheck', body: apiProblem(p)) as Map).cast<String, dynamic>());

  // ------------------------------------------------------------ production
  String _sessions(String org) => '/v1/orgs/$org/production/sessions';

  Future<Map<String, dynamic>> openSession(String org, Map<String, dynamic> body) async =>
      (await _send('POST', _sessions(org), body: body) as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> patchSession(String org, String id, Map<String, dynamic> body) async =>
      (await _send('PATCH', '${_sessions(org)}/$id', body: body) as Map).cast<String, dynamic>();

  Future<Map<String, dynamic>> session(String org, String id) async =>
      (await _send('GET', '${_sessions(org)}/$id') as Map).cast<String, dynamic>();

  Future<List<Map<String, dynamic>>> sessions(String org) async =>
      [for (final e in (await _send('GET', _sessions(org)) as List)) (e as Map).cast<String, dynamic>()];

  Future<List<Map<String, dynamic>>> entries(String org, String sessionId) async => [
        for (final e in (await _send('GET', '${_sessions(org)}/$sessionId/entries') as List)) (e as Map).cast<String, dynamic>()
      ];

  Future<List<Map<String, dynamic>>> pushEntries(String org, String sessionId, List<Map<String, dynamic>> entries) async {
    final r = await _send('POST', '${_sessions(org)}/$sessionId/entries', body: {'entries': entries}) as Map;
    return [for (final e in (r['entries'] as List? ?? [])) (e as Map).cast<String, dynamic>()];
  }

  Future<Uint8List> sessionExport(String org, String sessionId, String ext) =>
      _bytes('${_sessions(org)}/$sessionId/export.$ext');

  // ------------------------------------------------------------ phase 2 : jumeau, plan, DES, optimiseur
  Map<String, dynamic> _m(dynamic v) => (v as Map).cast<String, dynamic>();
  List<Map<String, dynamic>> _l(dynamic v) => [for (final e in (v as List? ?? const [])) (e as Map).cast<String, dynamic>()];

  /// Plan de ligne, implantation enregistrée, sessions et simulations d'un calcul (`routes_twin.py`).
  Future<Map<String, dynamic>> twin(String org, String runId) async => _m(await _send('GET', '/v1/orgs/$org/runs/$runId/twin'));

  /// Implantation : `{kind, positions}` ou `{plan_id, assignment}`.
  Future<Map<String, dynamic>> putLayout(String org, String runId, Map<String, dynamic> layout) async =>
      _m(await _send('PUT', '/v1/orgs/$org/runs/$runId/layout', body: layout));

  /// Lance 1–3 scénarios du jumeau (tâche de fond) → ligne `twin_simulations` (statut queued).
  Future<Map<String, dynamic>> simulateTwin(String org, String runId, List<Map<String, dynamic>> scenarios,
          {String name = '', Map<String, dynamic>? layout}) async =>
      _m(await _send('POST', '/v1/orgs/$org/runs/$runId/simulate',
          body: {'name': name, 'scenarios': scenarios, 'layout': ?layout}));

  /// Statut + résultats d'une simulation (jumeau, DES, optimisation).
  Future<Map<String, dynamic>> simulation(String org, String simId) async =>
      _m(await _send('GET', '/v1/orgs/$org/simulations/$simId'));

  /// Attend la fin d'une simulation de fond (progression transmise à [onProgress]).
  Future<Map<String, dynamic>> waitSimulation(String org, String simId,
      {Duration every = const Duration(seconds: 2), int maxTries = 200, void Function(Map<String, dynamic>)? onProgress}) async {
    for (var i = 0; i < maxTries; i++) {
      final s = await simulation(org, simId);
      final st = s['status'];
      if (st == 'done') return s;
      if (st == 'failed') throw ApiException(500, 'Simulation en échec : ${s['error'] ?? ''}');
      onProgress?.call(s);
      await Future<void>.delayed(every);
    }
    throw ApiException(0, 'La simulation n\'est pas terminée : réessayez plus tard.');
  }

  /// Réel vs simulé d'une session de production (`/twin/sync`).
  Future<Map<String, dynamic>> twinSync(String org, String runId, String sessionId, {int bundleSize = 10}) async =>
      _m(await _send('GET', '/v1/orgs/$org/runs/$runId/twin/sync?session_id=$sessionId&bundle_size=$bundleSize'));

  Future<Map<String, dynamic>> workshopCatalog(String org) async => _m(await _send('GET', '/v1/orgs/$org/workshop-catalog'));
  Future<List<Map<String, dynamic>>> workshopPlans(String org) async => _l(await _send('GET', '/v1/orgs/$org/workshop-plans'));
  Future<Map<String, dynamic>> workshopPlan(String org, String id) async =>
      _m(await _send('GET', '/v1/orgs/$org/workshop-plans/$id'));
  Future<Map<String, dynamic>> createWorkshopPlan(String org, Map<String, dynamic> body) async =>
      _m(await _send('POST', '/v1/orgs/$org/workshop-plans', body: body));
  Future<Map<String, dynamic>> updateWorkshopPlan(String org, String id, Map<String, dynamic> body) async =>
      _m(await _send('PUT', '/v1/orgs/$org/workshop-plans/$id', body: body));
  Future<void> deleteWorkshopPlan(String org, String id) => _send('DELETE', '/v1/orgs/$org/workshop-plans/$id');

  /// Modèle DES généré pour un calcul + historique (`routes_des.py`).
  Future<Map<String, dynamic>> desModel(String org, String runId) async =>
      _m(await _send('GET', '/v1/orgs/$org/runs/$runId/des/model'));

  /// Simulation détaillée : scénarios `{name, overrides, absent}` × réplications → 202.
  Future<Map<String, dynamic>> runDes(String org, String runId,
          {required List<Map<String, dynamic>> scenarios, int replications = 5, String name = ''}) async =>
      _m(await _send('POST', '/v1/orgs/$org/runs/$runId/des',
          body: {'name': name, 'scenarios': scenarios, 'replications': replications}));

  Future<List<Map<String, dynamic>>> desSimulations(String org, String runId) async =>
      _l(await _send('GET', '/v1/orgs/$org/runs/$runId/des/simulations'));

  /// Optimiseur multi-objectif (NSGA-II, budget borné côté serveur) → 202.
  Future<Map<String, dynamic>> optimize(String org, String runId, Map<String, dynamic> config, {String name = ''}) async =>
      _m(await _send('POST', '/v1/orgs/$org/runs/$runId/optimize', body: {'name': name, 'config': config}));

  Future<List<Map<String, dynamic>>> optimizations(String org, String runId) async =>
      _l(await _send('GET', '/v1/orgs/$org/runs/$runId/optimizations'));

  /// Applique une solution du front de Pareto : simulation DES (+ implantation enregistrée).
  Future<Map<String, dynamic>> applyOptimization(String org, String simId, int solution,
          {bool saveLayout = true, int replications = 5}) async =>
      _m(await _send('POST', '/v1/orgs/$org/optimizations/$simId/apply',
          body: {'solution': solution, 'save_layout': saveLayout, 'replications': replications}));
}

/// Échec avant toute réponse HTTP : réseau coupé, serveur en veille, ou requête
/// bloquée par le navigateur (CORS : le domaine de l'application n'est pas autorisé
/// par l'API). Sur le Web, ces cas sont indiscernables pour le code.
String networkErrorMessage(Object e) {
  final detail = e.toString().replaceFirst('ClientException: ', '');
  final web = kIsWeb || detail.contains('XMLHttpRequest') || detail.contains('Failed to fetch');
  return web
      ? 'Serveur injoignable (réseau coupé, serveur en veille ou accès refusé par le navigateur — CORS). '
          'Réessayez dans une minute ; si le problème persiste, contactez le support.'
      : 'Serveur injoignable : vérifiez la connexion Internet ($detail).';
}

/// Réponse HTTP en erreur : code + détail renvoyé par l'API.
String httpErrorMessage(int status, String? detail) {
  final label = switch (status) {
    400 || 422 => 'Requête refusée',
    401 => 'Session expirée, reconnectez-vous',
    403 => 'Accès refusé',
    404 => 'Introuvable',
    409 => 'Conflit',
    429 => 'Trop de requêtes',
    _ when status >= 500 => 'Erreur du serveur',
    _ => 'Erreur',
  };
  return (detail == null || detail.isEmpty) ? '$label (HTTP $status).' : '$label (HTTP $status) : $detail';
}

/// JSON `ProblemIn` accepté par l'API (sans champ inconnu).
Map<String, dynamic> apiProblem(Problem p) {
  final j = p.toJson();
  j['operations'] = [
    for (final o in p.operations) {...o.toJson(), 'name': o.name.isEmpty ? o.id : o.name},
  ];
  if (p.maxStations == null) j.remove('max_stations');
  return j;
}
