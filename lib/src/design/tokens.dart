/// Prism design-system tokens — single source of truth for visual.md Part 4.
///
/// Nothing in the app may hard-code a color/radius/duration; everything
/// reads from [PrismColors], [PrismRadii], [PrismSpacing], [PrismMotion],
/// or the typography scale in [PrismTypography].
library;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Color tokens (visual.md §4.2)
// ---------------------------------------------------------------------------

/// Raw palette values, split by brightness. Use via [PrismColors.of].
class PrismPalette {
  const PrismPalette({
    required this.bgCanvas,
    required this.surfaceGlass,
    required this.surfaceGlassStroke,
    required this.accentPrimary,
    required this.accentTeal,
    required this.textPrimary,
    required this.textSecondary,
    required this.semanticWarn,
    required this.semanticDanger,
    required this.overlayScrim,
  });

  final Color bgCanvas;
  final Color surfaceGlass;
  final Color surfaceGlassStroke;
  final Color accentPrimary;
  final Color accentTeal;
  final Color textPrimary;
  final Color textSecondary;
  final Color semanticWarn;
  final Color semanticDanger;
  final Color overlayScrim;
}

/// Dark-first palette (visual.md §4.2 "Dark" column).
const PrismPalette kPrismDark = PrismPalette(
  bgCanvas: Color(0xFF0B0C10),
  // #16181F @ 82%
  surfaceGlass: Color(0xD216181F),
  // #FFFFFF @ 10%
  surfaceGlassStroke: Color(0x1AFFFFFF),
  accentPrimary: Color(0xFF7C6BFF),
  accentTeal: Color(0xFF38E1D4),
  textPrimary: Color(0xFFF2F4F8),
  textSecondary: Color(0xFFA6ADBB),
  semanticWarn: Color(0xFFFFB65C),
  semanticDanger: Color(0xFFFF5C77),
  // #000000 @ 55%
  overlayScrim: Color(0x8C000000),
);

/// Derived light palette (visual.md §4.2 "Light" column).
const PrismPalette kPrismLight = PrismPalette(
  bgCanvas: Color(0xFFF7F8FA),
  // #FFFFFF @ 88%
  surfaceGlass: Color(0xE0FFFFFF),
  // #000000 @ 6%
  surfaceGlassStroke: Color(0x0F000000),
  accentPrimary: Color(0xFF5B48F5),
  accentTeal: Color(0xFF0FA396),
  textPrimary: Color(0xFF101216),
  textSecondary: Color(0xFF55607A),
  semanticWarn: Color(0xFFB25E00),
  semanticDanger: Color(0xFFC21833),
  overlayScrim: Color(0x8C000000), // dark-only token; light uses same scrim
);

/// Accent gradient pair — reserved EXCLUSIVELY for: primary CTA border,
/// onboarding hero, model-progress rings (visual.md §4.2 restraint rule).
const List<Color> kAccentGradient = [Color(0xFF7C6BFF), Color(0xFF38E1D4)];

/// Semantic aliases resolved against brightness.
abstract final class PrismColors {
  static PrismPalette of(Brightness brightness) => switch (brightness) {
    Brightness.dark => kPrismDark,
    Brightness.light => kPrismLight,
  };

  /// RTF gauge coloring (visual.md §4.5 ProgressRing):
  /// green < 0.4 · amber < 0.8 · red otherwise.
  static Color rtfLevel(double rtf) => switch (rtf) {
    < 0.4 => const Color(0xFF38E1D4), // teal doubles as healthy green
    < 0.8 => const Color(0xFFFFB65C),
    _ => const Color(0xFFFF5C77),
  };
}

// ---------------------------------------------------------------------------
// Shape & spacing (visual.md §4.4)
// ---------------------------------------------------------------------------

abstract final class PrismRadii {
  static const double xs = 8;
  static const double sm = 14;
  static const double md = 20;
  static const double xl = 28;
  static const double pill = 999;

  static BorderRadius rounded(double r) => BorderRadius.circular(r);
}

/// 4-pt grid.
abstract final class PrismSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

// ---------------------------------------------------------------------------
// Motion (visual.md §4.4)
// ---------------------------------------------------------------------------

abstract final class PrismMotion {
  /// Chips / controls.
  static const Duration fast = Duration(milliseconds: 150);

  /// Emphasized transitions (sheets).
  static const Duration emphasized = Duration(milliseconds: 260);

  /// Overlay idle-collapse: 300 ms fade + scale .98 (architecture §3.6).
  static const Duration overlayCollapse = Duration(milliseconds: 300);

  static const Curve easeOut = Curves.easeOut;

  /// Collapse end-scale for the overlay widget.
  static const double overlayCollapseScale = 0.98;
}

// ---------------------------------------------------------------------------
// Typography (visual.md §4.3)
// ---------------------------------------------------------------------------

/// Font-family contract. Bundling note (Epic 1 remainder): drop Manrope /
/// NotoSansJP / JetBrainsMono TTFs into `assets/fonts/` and register them in
/// pubspec.yaml under these exact family names. Until then Flutter falls back
/// to platform defaults — layout must never depend on the specific face.
abstract final class PrismFontFamilies {
  static const String latin = 'Manrope';
  static const String cjkFallback = 'NotoSansJP';
  static const String mono = 'JetBrainsMono';

  /// Stack used for body/UI text: latin first, CJK fallback for ja/ko glyphs.
  static const List<String> textStack = [latin, cjkFallback];

  /// Timestamps only (visual.md §4.3).
  static const List<String> monoStack = [mono];
}

/// Type scale (size/height pairs from visual.md §4.3).
abstract final class PrismTypography {
  static const TextStyle display = TextStyle(
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w700,
    fontFamilyFallback: PrismFontFamilies.textStack,
  );

  static const TextStyle h1 = TextStyle(
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w700,
    fontFamilyFallback: PrismFontFamilies.textStack,
  );

  static const TextStyle h2 = TextStyle(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: PrismFontFamilies.textStack,
  );

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: PrismFontFamilies.textStack,
  );

  /// Meta 12/16 Medium caps — apply `letterSpacing` via style copy where used.
  static const TextStyle meta = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.8,
    fontFamilyFallback: PrismFontFamilies.textStack,
  );

  /// Timestamps / numeric chips (JetBrains Mono slot).
  static const TextStyle mono = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    fontFamilyFallback: PrismFontFamilies.monoStack,
  );
}
