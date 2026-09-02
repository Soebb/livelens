import 'package:flutter/material.dart';

import 'tokens.dart';

export 'tokens.dart'
    show PrismColors, PrismMotion, PrismRadii, PrismSpacing, PrismTypography;

// ---------------------------------------------------------------------------
// GlassCard (visual.md §4.5)
// ---------------------------------------------------------------------------

/// Surface.glass fill + hairline stroke + top-edge 1px sheen highlight,
/// corner radius md (20). The sheen is a subtle vertical white gradient
/// confined to the top edge — the "emulated glass" recipe from §3.6.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(PrismSpacing.md),
    this.radius = PrismRadii.md,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// When set, the whole card becomes a single tap target.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: p.surfaceGlassStroke),
    );

    final card = Material(
      color: p.surfaceGlass,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );

    // Top-edge sheen: 1px-ish light gradient band inside the top border.
    final sheen = IgnorePointer(
      child: CustomPaint(
        painter: _TopSheenPainter(stroke: p.surfaceGlassStroke),
      ),
    );

    if (onTap != null) {
      return InkResponse(
        containedInkWell: true,
        customBorder: shape,
        onTap: onTap,
        child: Stack(
          children: [
            card,
            Positioned.fill(child: sheen),
          ],
        ),
      );
    }
    return Stack(
      children: [
        card,
        Positioned.fill(child: sheen),
      ],
    );
  }
}

class _TopSheenPainter extends CustomPainter {
  const _TopSheenPainter({required this.stroke});

  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _TopSheenPainter oldDelegate) =>
      oldDelegate.stroke != stroke;
}

// ---------------------------------------------------------------------------
// PrimaryAction (visual.md §4.5) — filled accent + gradient border + glow
// ---------------------------------------------------------------------------

/// Hero CTA: filled accent, subtle outer glow `0 0 24 primary@25%`,
/// semibold label, and the reserved accent-pair gradient border.
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final enabled = onPressed != null;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: PrismRadii.rounded(PrismRadii.sm),
        // Outer glow: primary @ ~25%, blur 24.
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: p.accentPrimary.withValues(alpha: 0.25),
                  blurRadius: 24,
                ),
              ]
            : const [],
        // Reserved accent-pair gradient border.
        gradient: enabled
            ? const LinearGradient(colors: kAccentGradient)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.5), // border thickness
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: p.accentPrimary,
            // onPrimary resolves to the WCAG-checked label color per theme.
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PrismRadii.sm - 1.5),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20),
                const SizedBox(width: PrismSpacing.sm),
              ],
              Text(
                label,
                style: PrismTypography.body.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LangChip / ModeChip (visual.md §4.5) — pill outline; active = teal tint
// ---------------------------------------------------------------------------

/// Pill-outline chip. Active state uses the teal tint per §4.5.
class LangChip extends StatelessWidget {
  const LangChip({
    super.key,
    required this.label,
    this.active = false,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final chip = Material(
      color: active ? p.accentTeal.withValues(alpha: 0.15) : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(color: active ? p.accentTeal : p.surfaceGlassStroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PrismSpacing.md,
            vertical: PrismSpacing.sm,
          ),
          child: Text(
            label,
            style: PrismTypography.meta.copyWith(
              color: active ? p.accentTeal : p.textSecondary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Alias for mode selection chips ("Translate" / "Transcribe").
typedef ModeChip = LangChip;

// ---------------------------------------------------------------------------
// ProgressRing (visual.md §4.5) — model download & RTF gauge reuse
// ---------------------------------------------------------------------------

/// Determinate ring used for model downloads; when [value] is null it spins
/// indeterminately. [rtfMode] applies the green<0.4 / amber<0.8 / red rule.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    this.value,
    this.size = 28,
    this.strokeWidth = 3,
    this.rtfMode = false,
    this.rtf,
  }) : assert(
         !rtfMode || rtf != null,
         'rtf must be provided when rtfMode is true',
       );

  /// 0..1 progress, or null for indeterminate spin.
  final double? value;

  final double size;
  final double strokeWidth;

  /// Color by RTF thresholds instead of accent (§4.5).
  final bool rtfMode;
  final double? rtf;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final Color track = p.surfaceGlassStroke;
    final Color fill = rtfMode
        ? PrismColors.rtfLevel(rtf!)
        : (value == null ? p.accentTeal : kAccentGradient.first);

    return SizedBox.square(
      dimension: size,
      child: value == null && !rtfMode
          ? CircularProgressIndicator(color: fill, strokeWidth: strokeWidth)
          : CircularProgressIndicator(
              value: rtfMode ? rtf!.clamp(0.0, 1.0) : value!.clamp(0.0, 1.0),
              color: fill,
              backgroundColor: track,
              strokeWidth: strokeWidth,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// SpecSheet row (settings) — icon, title, meta-right value, chevron
// ---------------------------------------------------------------------------

class SpecSheetRow extends StatelessWidget {
  const SpecSheetRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;

  /// Right-aligned meta value (e.g. current setting).
  final String? value;
  final VoidCallback? onTap;

  /// Renders title/value in semantic danger (destructive rows).
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final color = danger ? p.semanticDanger : p.textPrimary;

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: PrismTypography.body.copyWith(color: color)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value!,
              style: PrismTypography.meta.copyWith(color: p.textSecondary),
            ),
          const SizedBox(width: PrismSpacing.xs),
          Icon(
            Icons.chevron_right,
            color: p.textSecondary.withValues(alpha: 0.6),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------------------
// SegmentRow (editor/list) — timestamp mono chip + stacked bilingual text
// ---------------------------------------------------------------------------

/// One transcript segment. Hierarchy via weight, never color-only (a11y).
class SegmentRow extends StatelessWidget {
  const SegmentRow({
    super.key,
    required this.t0Ms,
    required this.sourceText,
    required this.translatedText,
    this.langPair,
    this.onTap,
    this.selected = false,
  });

  final double t0Ms;
  final String sourceText;
  final String translatedText;

  /// e.g. "JA → EN"; rendered in the header meta line when present.
  final String? langPair;
  final VoidCallback? onTap;
  final bool selected;

  /// Formats session-timeline ms as `mm:ss.d` (mono chip).
  static String formatTimestamp(double t0Ms) {
    final totalSeconds = t0Ms / 1000.0;
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).toStringAsFixed(1).padLeft(4, '0');
    return '${minutes.toString().padLeft(2, '0')}:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);

    return GlassCard(
      padding: const EdgeInsets.all(PrismSpacing.md),
      radius: PrismRadii.sm,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: PrismSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? p.accentTeal.withValues(alpha: 0.18)
                      : p.bgCanvas.withValues(alpha: 0.6),
                  borderRadius: PrismRadii.rounded(PrismRadii.xs),
                ),
                child: Text(
                  formatTimestamp(t0Ms),
                  style: PrismTypography.mono.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: selected ? p.accentTeal : p.textSecondary,
                  ),
                ),
              ),
              if (langPair != null) ...[
                const SizedBox(width: PrismSpacing.sm),
                Expanded(
                  child: Text(
                    langPair!,
                    style: PrismTypography.meta.copyWith(
                      color: p.textSecondary,
                      letterSpacing: 0.8,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: PrismSpacing.sm),
          // Source line: heavier weight (hierarchy via weight, not color).
          Text(
            sourceText,
            style: PrismTypography.body.copyWith(
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          // Translation line: regular weight.
          Text(
            translatedText,
            style: PrismTypography.body.copyWith(color: p.textPrimary),
          ),
        ],
      ),
    );
  }
}
