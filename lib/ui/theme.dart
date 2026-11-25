import 'package:flutter/material.dart';

/// Couleurs et thème (source unique des constantes visuelles).
abstract class Brand {
  static const navy = Color(0xFF1E3A5F);
  static const bg = Color(0xFFF5F6F8);
  static const border = Color(0xFFE3E7ED);
  static const muted = Color(0xFF667085);
  static const ok = Color(0xFF16A34A);
  static const warn = Color(0xFFD97706);
  static const danger = Color(0xFFDC2626);
  static const good = Color(0xFF22A06B);
  static const mid = Color(0xFF3B82F6);
  static const low = Color(0xFF94A3B8);
  static const orange = Color(0xFFEA580C);
}

/// Seuils d'écran.
abstract class Breakpoints {
  static const phone = 600.0;
  static const desktop = 1100.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Brand.navy, brightness: Brightness.light);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: Color(0xFFD0D5DD)),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.bg,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Brand.navy,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(color: Brand.navy, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Brand.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: const BorderSide(color: Brand.navy, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: const TextStyle(color: Brand.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.navy,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Brand.border, thickness: 1, space: 1),
    navigationRailTheme: const NavigationRailThemeData(backgroundColor: Colors.white),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(fontWeight: FontWeight.w600, color: Brand.navy, fontSize: 13),
      dataTextStyle: TextStyle(fontSize: 13, color: Color(0xFF1F2937)),
    ),
  );
}
