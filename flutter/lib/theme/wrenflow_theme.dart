import 'package:flutter/material.dart';

/// Wrenflow design system — matches the original Swift app.
class WrenflowStyle {
  WrenflowStyle._();

  // ── Colors ──────────────────────────────────────────────────
  static const bg = Color.fromRGBO(245, 245, 245, 1.0);           // white(0.96)
  static const surface = Color.fromRGBO(252, 252, 252, 1.0);      // white(0.99)
  static const text = Color.fromRGBO(38, 38, 38, 1.0);            // white(0.15)
  static const textSecondary = Color.fromRGBO(115, 115, 115, 1.0); // white(0.45)
  static const textTertiary = Color.fromRGBO(153, 153, 153, 1.0); // white(0.60)
  static const border = Color.fromRGBO(0, 0, 0, 0.08);
  static const green = Color.fromRGBO(51, 179, 102, 1.0);         // rgb(0.2,0.7,0.4)
  static const red = Color.fromRGBO(217, 64, 51, 1.0);            // rgb(0.85,0.25,0.2)

  // ── Corner Radii ────────────────────────────────────────────
  static const double radiusSmall = 5.0;
  static const double radiusMedium = 8.0;
  static const double radiusLarge = 12.0;

  // ── Shadows ─────────────────────────────────────────────────
  static final cardShadow = BoxShadow(
    color: Colors.black.withValues(alpha: 0.08),
    blurRadius: 24,
    offset: const Offset(0, 8),
  );

  // ── Decorations ─────────────────────────────────────────────
  static BoxDecoration cardDecoration = BoxDecoration(
    color: surface,
    borderRadius: BorderRadius.circular(radiusLarge),
    border: Border.all(color: border, width: 0.5),
    boxShadow: [cardShadow],
  );

  // ── ThemeData ───────────────────────────────────────────────
  static ThemeData get themeData => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: text,
      brightness: Brightness.light,
      surface: surface,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.w500, color: text, fontSize: 16),
      titleMedium: TextStyle(fontWeight: FontWeight.w500, color: text, fontSize: 13),
      bodyMedium: TextStyle(color: text, fontSize: 14),
      bodySmall: TextStyle(color: textSecondary, fontSize: 12),
      labelSmall: TextStyle(color: textTertiary, fontSize: 11),
    ),
  );
}
