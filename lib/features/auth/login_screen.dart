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

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email.text = context.read<AppState>().repo.setting('email') ?? '';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().signIn(_email.text.trim(), _password.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Connexion impossible : $e');
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

  Widget _formCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Connexion', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Brand.navy)),
              const SizedBox(height: 4),
              const Text('Compte de votre atelier (synchronisé, CP-SAT, historique partagé).',
                  style: TextStyle(color: Brand.muted)),
              const SizedBox(height: 18),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.mail_outline)),
                validator: (v) => (v == null || !v.contains('@')) ? 'Adresse e-mail invalide' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _hide,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Mot de passe',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
                onFieldSubmitted: (_) => _login(),
                validator: (v) => (v == null || v.isEmpty) ? 'Mot de passe requis' : null,
              ),
              if (_error != null) ...[const SizedBox(height: 12), Notice(_error!, kind: 'error')],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _login,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.login),
                label: Text(_busy ? 'Connexion…' : 'Se connecter'),
              ),
              const SizedBox(height: 18),
              const Row(children: [
                Expanded(child: Divider()),
                Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('ou', style: TextStyle(color: Brand.muted))),
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
            ]),
          ),
        ),
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
