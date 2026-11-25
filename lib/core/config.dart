/// Configuration de l'application.
///
/// La clé Supabase ci-dessous est la clé *publishable* (publique, prévue pour
/// les clients : l'isolation des ateliers est assurée par RLS côté Postgres).
/// Ne JAMAIS ajouter ici une clé service / secrète.
/// Surchargeable à la compilation : `--dart-define=TLB_API_URL=...`.
library;

class AppConfig {
  static const apiBase = String.fromEnvironment('TLB_API_URL', defaultValue: 'https://tlb-api.onrender.com');
  static const supabaseUrl =
      String.fromEnvironment('TLB_SUPABASE_URL', defaultValue: 'https://lkdlqijhlszyfkmunzyt.supabase.co');
  static const supabasePublishableKey =
      String.fromEnvironment('TLB_SUPABASE_KEY', defaultValue: 'sb_publishable_MFaWSChslfBhcg37fi_RuA_ZEKrzNX1');
  /// Application Web publique (liens des e-mails hors navigateur).
  static const webAppUrl = String.fromEnvironment('TLB_WEB_URL', defaultValue: 'https://textile-line-balancer.pages.dev/');
  static const appName = 'Textile Line Balancer';
  static const version = '1.1.0';

  /// Rendement de ligne attendu par défaut pour passer du takt à la cadence (manuel §3.2).
  static const defaultExpectedEfficiency = 0.85;
}
