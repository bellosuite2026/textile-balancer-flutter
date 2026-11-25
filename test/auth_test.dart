// Création de compte, mot de passe oublié, récupération, messages d'erreur réseau / HTTP.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:textile_balancer_flutter/app.dart';
import 'package:textile_balancer_flutter/data/api_client.dart';
import 'package:textile_balancer_flutter/data/local_store.dart';
import 'package:textile_balancer_flutter/data/repository.dart';
import 'package:textile_balancer_flutter/state/app_state.dart';

/// Faux client : aucune requête réelle, aucun secret.
class _FakeAuthApi extends ApiClient {
  _FakeAuthApi({http.Client? c}) : super(httpClient: c ?? MockClient((_) async => http.Response('{"orgs":[]}', 200)), base: 'https://api.test');

  final events = StreamController<AuthEvent>.broadcast();
  final calls = <String>[];
  bool signUpGivesSession = false;
  ApiException? signUpError;
  String? token;

  @override
  Stream<AuthEvent> get authEvents => events.stream;
  @override
  String? get accessToken => token;
  @override
  String? get email => 'atelier@tlb-test.example.com';

  @override
  Future<bool> signUp(String email, String password, {String? name}) async {
    calls.add('signUp $email ${name ?? ''}');
    if (signUpError != null) throw signUpError!;
    if (signUpGivesSession) token = 't';
    return signUpGivesSession;
  }

  @override
  Future<void> resetPassword(String email) async => calls.add('reset $email');

  @override
  Future<void> updatePassword(String password) async {
    calls.add('update');
    token = 't';
  }
}

Future<(AppState, _FakeAuthApi)> _app(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _FakeAuthApi();
  final s = AppState(repo: Repository(MemoryLocalStore()), api: api, enableNetwork: false);
  await s.init();
  await tester.pumpWidget(TextileBalancerApp(state: s));
  await tester.pumpAndSettle();
  return (s, api);
}

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  group('écran de connexion', () {
    testWidgets('création de compte : validations puis « vérifiez votre e-mail »', (tester) async {
      final (s, api) = await _app(tester);
      expect(find.text('Pas encore de compte ? Créer un compte'), findsOneWidget);
      await tester.tap(find.byKey(const Key('go-signup')));
      await tester.pumpAndSettle();
      expect(find.text('Créer un compte'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('signup-name')), 'Karim');
      await tester.enterText(find.byKey(const Key('auth-email')), 'nouveau@tlb-test.example.com');
      await tester.enterText(find.byKey(const Key('auth-password')), 'court1');
      await tester.enterText(find.byKey(const Key('auth-confirm')), 'autre');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Mot de passe trop court : 8 caractères minimum'), findsOneWidget);
      expect(find.text('Les mots de passe ne correspondent pas'), findsOneWidget);
      expect(api.calls, isEmpty);

      await tester.enterText(find.byKey(const Key('auth-password')), 'Atelier2026');
      await tester.enterText(find.byKey(const Key('auth-confirm')), 'Atelier2026');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, ['signUp nouveau@tlb-test.example.com Karim']);
      expect(find.textContaining('Vérifiez votre e-mail pour confirmer'), findsOneWidget);
      expect(find.text('Se connecter'), findsOneWidget);
      expect(s.mode, AppMode.none);
    });

    testWidgets('création de compte avec session immédiate : mode cloud', (tester) async {
      final (s, api) = await _app(tester);
      api.signUpGivesSession = true;
      await tester.tap(find.byKey(const Key('go-signup')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('auth-email')), 'direct@tlb-test.example.com');
      await tester.enterText(find.byKey(const Key('auth-password')), 'Atelier2026');
      await tester.enterText(find.byKey(const Key('auth-confirm')), 'Atelier2026');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(s.mode, AppMode.cloud);
      expect(find.text('Choisir un atelier'), findsOneWidget);
    });

    testWidgets('e-mail déjà utilisé : message clair', (tester) async {
      final (_, api) = await _app(tester);
      api.signUpError = ApiException(409, authErrorMessage(const sb.AuthException('User already registered', code: 'user_already_exists')));
      await tester.tap(find.byKey(const Key('go-signup')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('auth-email')), 'pris@tlb-test.example.com');
      await tester.enterText(find.byKey(const Key('auth-password')), 'Atelier2026');
      await tester.enterText(find.byKey(const Key('auth-confirm')), 'Atelier2026');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Un compte existe déjà avec cette adresse e-mail'), findsOneWidget);
    });

    testWidgets('mot de passe oublié : envoi du lien', (tester) async {
      final (_, api) = await _app(tester);
      await tester.tap(find.byKey(const Key('go-forgot')));
      await tester.pumpAndSettle();
      expect(find.text('Mot de passe oublié'), findsOneWidget);
      expect(find.byKey(const Key('auth-password')), findsNothing);
      await tester.enterText(find.byKey(const Key('auth-email')), 'pas-une-adresse');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Adresse e-mail invalide'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('auth-email')), 'oubli@tlb-test.example.com');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, ['reset oubli@tlb-test.example.com']);
      expect(find.textContaining('e-mail de réinitialisation'), findsOneWidget);
    });

    testWidgets('lien de récupération : dialogue nouveau mot de passe', (tester) async {
      final (s, api) = await _app(tester);
      api.events.add(AuthEvent.passwordRecovery);
      await tester.pumpAndSettle();
      expect(find.text('Nouveau mot de passe'), findsWidgets);
      await tester.enterText(find.byKey(const Key('recovery-password')), 'abc');
      await tester.tap(find.byKey(const Key('recovery-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Mot de passe trop court : 8 caractères minimum'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('recovery-password')), 'Nouveau2026');
      await tester.enterText(find.byKey(const Key('recovery-confirm')), 'Nouveau2026');
      await tester.tap(find.byKey(const Key('recovery-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, ['update']);
      expect(s.passwordRecovery, isFalse);
      expect(s.mode, AppMode.cloud);
    });
  });

  group('messages d\'erreur', () {
    test('Supabase Auth en français', () {
      expect(authErrorMessage(const sb.AuthException('Password should be at least 6 characters', code: 'weak_password')),
          contains('trop faible'));
      expect(authErrorMessage(const sb.AuthException('Invalid login credentials')), 'E-mail ou mot de passe incorrect.');
      expect(authErrorMessage(const sb.AuthException('Email not confirmed')), contains('non confirmée'));
      expect(authErrorMessage(const sb.AuthException('x', code: 'over_email_send_rate_limit')), contains('Trop de demandes'));
    });

    test('erreur HTTP : code et détail de l\'API', () async {
      final api = _FakeAuthApi(c: MockClient((_) async => http.Response(jsonEncode({'detail': 'Nombre maximal d\'ateliers atteint'}), 400)));
      api.token = 't';
      await expectLater(
        api.createOrg('Atelier'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 400)
            .having((e) => e.message, 'message', 'Requête refusée (HTTP 400) : Nombre maximal d\'ateliers atteint')),
      );
    });

    test('échec réseau : statut 0 et message « injoignable »', () async {
      final api = _FakeAuthApi(c: MockClient((_) async => throw const SocketException('coupé')));
      await expectLater(
        api.me(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 0).having((e) => e.message, 'm', contains('injoignable'))),
      );
    });

    test('création d\'atelier : chemin, corps et en-têtes attendus par l\'API', () async {
      late http.Request seen;
      final api = _FakeAuthApi(c: MockClient((req) async {
        seen = req;
        return http.Response('{"id":"o-1","name":"E2E","country":"TN"}', 201);
      }));
      api.token = 'jeton';
      final o = await api.createOrg('E2E');
      expect(o['id'], 'o-1');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://api.test/v1/orgs');
      expect(jsonDecode(seen.body), {'name': 'E2E', 'country': 'TN'});
      expect(seen.headers['Authorization'], 'Bearer jeton');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
    });

    test('health réessaie après un échec (réveil Render)', () async {
      var n = 0;
      final api = _FakeAuthApi(c: MockClient((_) async => ++n == 1 ? http.Response('', 502) : http.Response('{"ok":true}', 200)));
      expect(await api.health(timeout: const Duration(seconds: 1), retries: 1), isTrue);
      expect(n, 2);
    });
  });
}
