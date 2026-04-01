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

  // ── Opacity color helpers (text.opacity(N)) ────────────────
  static final textOp05 = text.withValues(alpha: 0.05);
  static final textOp06 = text.withValues(alpha: 0.06);
  static final textOp07 = text.withValues(alpha: 0.07);
  static final textOp10 = text.withValues(alpha: 0.10);
  static final textOp15 = text.withValues(alpha: 0.15);
  static final textOp50 = text.withValues(alpha: 0.50);
  static final textOp60 = text.withValues(alpha: 0.60);
  static final textOp70 = text.withValues(alpha: 0.70);
  static final greenOp50 = green.withValues(alpha: 0.50);

  // ── Track colors (slider) ──────────────────────────────────
  static final trackBg = text.withValues(alpha: 0.08);
  static final trackFill = text.withValues(alpha: 0.35);

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

  static BoxDecoration settingsCardDecoration = BoxDecoration(
    color: surface,
    borderRadius: BorderRadius.circular(radiusMedium),
    border: Border.all(color: border, width: 1),
  );

  static BoxDecoration footerButtonDecoration = BoxDecoration(
    color: textOp06,
    borderRadius: BorderRadius.circular(6),
    border: Border.all(color: border, width: 1),
  );

  static BoxDecoration permissionButtonDecoration = BoxDecoration(
    color: textOp06,
    borderRadius: BorderRadius.circular(radiusMedium),
    border: Border.all(color: border, width: 1),
  );

  // ── Typography factories ────────────────────────────────────
  static TextStyle title(double size) => TextStyle(
    fontWeight: FontWeight.w500,
    color: text,
    fontSize: size,
  );

  static TextStyle body(double size) => TextStyle(
    color: text,
    fontSize: size,
  );

  static TextStyle caption(double size) => TextStyle(
    color: textSecondary,
    fontSize: size,
  );

  static TextStyle mono(double size) => TextStyle(
    fontFamily: 'Menlo',
    fontSize: size,
    color: text,
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
