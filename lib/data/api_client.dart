/// Client de l'API cloud Textile Line Balancer (FastAPI sur Render) + Supabase Auth.
///
/// Routes : voir `api/README.md` du dépôt Python. Authentification :
/// jeton d'accès Supabase transmis en `Authorization: Bearer` ; l'isolation
/// des ateliers est assurée par RLS côté Postgres.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
      final m = e.message.toLowerCase();
      if (m.contains('invalid login') || m.contains('invalid_credentials')) {
        throw ApiException(401, 'E-mail ou mot de passe incorrect.');
      }
      if (m.contains('email not confirmed')) throw ApiException(401, 'Adresse e-mail non confirmée.');
      throw ApiException(401, e.message);
    } catch (e) {
      throw ApiException(0, 'Serveur d\'authentification injoignable. Vérifiez la connexion.');
    }
  }

  Future<void> signOut() async {
    try {
      await _auth?.signOut();
    } catch (_) {}
  }

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<dynamic> _send(String method, String path, {Object? body, Duration timeout = const Duration(seconds: 45)}) async {
    final uri = Uri.parse('$base$path');
    http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers());
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiException(0, 'Le serveur ne répond pas (il se réveille peut-être : réessayez dans une minute).');
    } catch (_) {
      throw ApiException(0, 'Serveur injoignable : vérifiez la connexion.');
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
              : 'Erreur ${res.statusCode}';
      throw ApiException(res.statusCode, msg);
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
  Future<bool> health({Duration timeout = const Duration(seconds: 12)}) async {
    try {
      final r = await _http.get(Uri.parse('$base/health')).timeout(timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
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
