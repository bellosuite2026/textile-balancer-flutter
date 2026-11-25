/// Connexion (mode cloud) ou « mode local sans compte ».
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/api_client.dart';
import '../../state/app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum AuthView { login, signup, forgot }

/// Règles locales du mot de passe (Supabase vérifie aussi côté serveur).
String? validateNewPassword(String? v) {
  if (v == null || v.isEmpty) return 'Mot de passe requis';
  if (v.length < 8) return 'Mot de passe trop court : 8 caractères minimum';
  if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
    return 'Utilisez au moins une lettre et un chiffre';
  }
  return null;
}

String? validateEmail(String? v) {
  final t = v?.trim() ?? '';
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t) ? null : 'Adresse e-mail invalide';
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  AuthView _view = AuthView.login;
  bool _busy = false;
  bool _hide = true;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _email.text = context.read<AppState>().repo.setting('email') ?? '';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _name.dispose();
    super.dispose();
  }

  void _go(AuthView v) => setState(() {
        _view = v;
        _error = null;
        _info = null;
        _password.clear();
        _confirm.clear();
        _form.currentState?.reset();
      });

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final s = context.read<AppState>();
    final email = _email.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      switch (_view) {
        case AuthView.login:
          await s.signIn(email, _password.text);
        case AuthView.signup:
          final connected = await s.signUp(email, _password.text, name: _name.text);
          if (!connected && mounted) {
            _go(AuthView.login);
            _info = 'Compte créé. Vérifiez votre e-mail pour confirmer votre adresse ($email), '
                'puis connectez-vous. Pensez à regarder dans les indésirables.';
          }
        case AuthView.forgot:
          await s.resetPassword(email);
          if (mounted) {
            _go(AuthView.login);
            _info = 'Si un compte existe pour $email, un e-mail de réinitialisation vient d\'être envoyé. '
                'Ouvrez le lien qu\'il contient pour choisir un nouveau mot de passe.';
          }
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Opération impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final form = _formCard(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      const Expanded(child: _Pitch()),
                      const SizedBox(width: 40),
                      SizedBox(width: 420, child: form),
                    ])
                  : Column(children: [const _Pitch(compact: true), const SizedBox(height: 20), form]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _passwordField(TextEditingController c, String label, {required String? Function(String?) validator, Key? key}) =>
      TextFormField(
        key: key,
        controller: c,
        obscureText: _hide,
        autofillHints: [_view == AuthView.login ? AutofillHints.password : AutofillHints.newPassword],
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            tooltip: _hide ? 'Afficher' : 'Masquer',
            icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
        onFieldSubmitted: (_) => _submit(),
        validator: validator,
      );

  Widget _formCard(BuildContext context) {
    final (title, subtitle, action, busyLabel, icon) = switch (_view) {
      AuthView.login => (
          'Connexion',
          'Compte de votre atelier (synchronisé, CP-SAT, historique partagé).',
          'Se connecter',
          'Connexion…',
          Icons.login
        ),
      AuthView.signup => (
          'Créer un compte',
          'Gratuit : votre premier atelier démarre avec 30 jours d\'essai.',
          'Créer mon compte',
          'Création…',
          Icons.person_add_alt
        ),
      AuthView.forgot => (
          'Mot de passe oublié',
          'Saisissez votre e-mail : nous vous envoyons un lien pour choisir un nouveau mot de passe.',
          'Envoyer le lien',
          'Envoi…',
          Icons.send
        ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AutofillGroup(
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Brand.navy)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(color: Brand.muted)),
              const SizedBox(height: 18),
              if (_view == AuthView.signup) ...[
                TextFormField(
                  key: const Key('signup-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                      labelText: 'Nom (facultatif)', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const Key('auth-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.mail_outline)),
                onFieldSubmitted: _view == AuthView.forgot ? (_) => _submit() : null,
                validator: validateEmail,
              ),
              if (_view != AuthView.forgot) ...[
                const SizedBox(height: 12),
                _passwordField(_password, 'Mot de passe',
                    key: const Key('auth-password'),
                    validator: _view == AuthView.signup
                        ? validateNewPassword
                        : (v) => (v == null || v.isEmpty) ? 'Mot de passe requis' : null),
              ],
              if (_view == AuthView.signup) ...[
                const SizedBox(height: 12),
                _passwordField(_confirm, 'Confirmer le mot de passe',
                    key: const Key('auth-confirm'),
                    validator: (v) => v != _password.text ? 'Les mots de passe ne correspondent pas' : null),
                const SizedBox(height: 6),
                const Text('8 caractères minimum, avec au moins une lettre et un chiffre.',
                    style: TextStyle(color: Brand.muted, fontSize: 12.5)),
              ],
              if (_view == AuthView.login)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('go-forgot'),
                    onPressed: _busy ? null : () => _go(AuthView.forgot),
                    child: const Text('Mot de passe oublié ?'),
                  ),
                ),
              if (_info != null) ...[const SizedBox(height: 12), Notice(_info!, kind: 'ok')],
              if (_error != null) ...[const SizedBox(height: 12), Notice(_error!, kind: 'error')],
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const Key('auth-submit'),
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(icon),
                label: Text(_busy ? busyLabel : action),
              ),
              const SizedBox(height: 8),
              if (_view == AuthView.login)
                TextButton(
                  key: const Key('go-signup'),
                  onPressed: _busy ? null : () => _go(AuthView.signup),
                  child: const Text('Pas encore de compte ? Créer un compte'),
                )
              else
                TextButton(
                  key: const Key('go-login'),
                  onPressed: _busy ? null : () => _go(AuthView.login),
                  child: const Text('J\'ai déjà un compte : se connecter'),
                ),
              if (_view == AuthView.login) ...[
                const SizedBox(height: 10),
                const Row(children: [
                  Expanded(child: Divider()),
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('ou', style: TextStyle(color: Brand.muted))),
                  Expanded(child: Divider()),
                ]),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  key: const Key('local-mode'),
                  onPressed: _busy ? null : () => context.read<AppState>().startLocalMode(),
                  icon: const Icon(Icons.computer),
                  label: const Text('Mode local sans compte'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tout fonctionne sur cet appareil, sans Internet : gammes, équilibrage RPW, '
                  'résultats, exports, suivi de production. CP-SAT et la simulation détaillée '
                  'demandent un compte en ligne.',
                  style: TextStyle(color: Brand.muted, fontSize: 12.5),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Ouvert par le lien « mot de passe oublié » : choix du nouveau mot de passe.
class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({super.key});

  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    final s = context.read<AppState>();
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider.value(value: s, child: const NewPasswordDialog()),
    );
    if (done != true) await s.cancelPasswordRecovery();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Icon(Icons.lock_reset, size: 48, color: Brand.muted)));
}

class NewPasswordDialog extends StatefulWidget {
  const NewPasswordDialog({super.key});

  @override
  State<NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<NewPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().completePasswordRecovery(_pw.text);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Opération impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nouveau mot de passe'),
        content: SizedBox(
          width: 380,
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Choisissez le nouveau mot de passe de votre compte.'),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('recovery-password'),
                controller: _pw,
                obscureText: _hide,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Nouveau mot de passe',
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
                validator: validateNewPassword,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('recovery-confirm'),
                controller: _confirm,
                obscureText: _hide,
                decoration: const InputDecoration(labelText: 'Confirmer le mot de passe'),
                onFieldSubmitted: (_) => _save(),
                validator: (v) => v != _pw.text ? 'Les mots de passe ne correspondent pas' : null,
              ),
              if (_error != null) ...[const SizedBox(height: 12), Notice(_error!, kind: 'error')],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            key: const Key('recovery-submit'),
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Enregistrement…' : 'Enregistrer'),
          ),
        ],
      );
}

class _Pitch extends StatelessWidget {
  const _Pitch({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.linear_scale, color: Brand.navy, size: 34),
          const SizedBox(width: 10),
          Flexible(
            child: Text('Textile Line Balancer',
                style: TextStyle(fontSize: compact ? 22 : 28, fontWeight: FontWeight.w800, color: Brand.navy)),
          ),
        ]),
        const SizedBox(height: 14),
        Text('Équilibrez vos lignes de confection en quelques secondes.',
            style: TextStyle(fontSize: compact ? 16 : 22, fontWeight: FontWeight.w600)),
        if (!compact) ...[
          const SizedBox(height: 16),
          for (final t in const [
            'Gamme SAM, postes multi-machines, compétences et rendements des ouvrières',
            'Équilibrage RPW hors ligne, CP-SAT optimal en ligne',
            'Yamazumi, rendement, goulot, perte d\'équilibrage, exports Excel / PDF',
            'Suivi de production sur tablette, même sans Wi-Fi',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Brand.ok, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(t)),
              ]),
            ),
        ],
      ]);
}
