import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the app's [ThemeData] from Prism tokens.
///
/// Both themes derive from the same token set so light/dark stay in lockstep;
/// components must consume theme slots (never raw tokens) wherever a slot
/// exists, so Material-level widgets inherit automatically.
abstract final class PrismThemes {
  static ThemeData dark() => _build(kPrismDark, Brightness.dark);

  static ThemeData light() => _build(kPrismLight, Brightness.light);

  static ThemeData _build(PrismPalette p, Brightness brightness) {
    // onPrimary is chosen for WCAG AA on the accent fill, NOT blindly synced
    // with textPrimary: dark theme puts DARK labels on the mid-luminance
    // accent (≈5.0:1), light theme puts WHITE labels on the deeper accent
    // (≈5.4:1). Verified by test/design/contrast_test.dart.
    final Color onAccent = switch (brightness) {
      Brightness.dark => p.bgCanvas,
      Brightness.light => Colors.white,
    };

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: p.accentPrimary,
      onPrimary: onAccent,
      secondary: p.accentTeal,
      onSecondary: onAccent,
      error: p.semanticDanger,
      onError: onAccent,
      surface: p.bgCanvas,
      onSurface: p.textPrimary,
      // Glass surfaces map onto surfaceContainerHighest for cards/sheets.
      surfaceContainerHighest: p.surfaceGlass,
      onSurfaceVariant: p.textSecondary,
      outline: p.surfaceGlassStroke,
      outlineVariant: p.surfaceGlassStroke,
    );

    final base = ThemeData(brightness: brightness, useMaterial3: true);

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.bgCanvas,
      canvasColor: p.bgCanvas,
      splashFactory: InkSparkle.splashFactory,
      textTheme: base.textTheme.copyWith(
        displayLarge: PrismTypography.display.copyWith(color: p.textPrimary),
        headlineMedium: PrismTypography.h1.copyWith(color: p.textPrimary),
        titleLarge: PrismTypography.h2.copyWith(color: p.textPrimary),
        bodyMedium: PrismTypography.body.copyWith(color: p.textPrimary),
        bodySmall: PrismTypography.meta.copyWith(color: p.textSecondary),
        labelSmall: PrismTypography.mono.copyWith(color: p.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: p.surfaceGlass,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: PrismRadii.rounded(PrismRadii.md),
          side: BorderSide(color: p.surfaceGlassStroke),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.transparent,
        side: BorderSide(color: p.surfaceGlassStroke),
        shape: const StadiumBorder(),
        labelStyle: PrismTypography.meta.copyWith(color: p.textSecondary),
        selectedColor: p.accentTeal.withValues(alpha: 0.15),
        secondaryLabelStyle: PrismTypography.meta.copyWith(color: p.accentTeal),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accentPrimary,
          foregroundColor: onAccent,
          textStyle: PrismTypography.body.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: PrismRadii.rounded(PrismRadii.sm),
          ),
          minimumSize: const Size(64, 44), // touch-target a11y floor
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.surfaceGlassStroke),
          shape: RoundedRectangleBorder(
            borderRadius: PrismRadii.rounded(PrismRadii.sm),
          ),
          minimumSize: const Size(64, 44),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.accentTeal),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: p.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: PrismTypography.h2.copyWith(color: p.textPrimary),
      ),
      dividerTheme: DividerThemeData(color: p.surfaceGlassStroke),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surfaceGlass,
        modalBackgroundColor: p.surfaceGlass,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(PrismRadii.xl),
          ),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceGlass,
        contentTextStyle: PrismTypography.body.copyWith(color: p.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: PrismRadii.rounded(PrismRadii.sm),
        ),
      ),
    );
  }
}
