import 'package:flutter/material.dart';
import 'package:livelens/bridge.dart';
import 'package:livelens/design.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'screens/editor_screen.dart';

// ---------------------------------------------------------------------------
// Dashboard (Live)
// ---------------------------------------------------------------------------

/// Live-capture screen: phase state, live captions, controls (visual.md §4.3).
/// Carries the G-02 pre-flight strip (overlay permission, battery exemption,
/// app-compat summary) that refreshes once on entry.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    // Passive probes only (battery + compat rows); the overlay-permission
    // check deep-links when ungranted, so it stays user-initiated.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.runPreflight();
      // E-01: model registry + active model for the session setup card.
      widget.controller.refreshCapabilities();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final p = PrismColors.of(Theme.of(context).brightness);
        final capturing = controller.phase == LivePhase.capturing;
        final paused = controller.phase == LivePhase.paused;

        return ListView(
          padding: const EdgeInsets.all(PrismSpacing.md),
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(switch (controller.phase) {
                    LivePhase.idle => 'Ready',
                    LivePhase.starting => 'Starting…',
                    LivePhase.capturing => 'Capturing',
                    LivePhase.paused => 'Paused',
                    LivePhase.stopped => 'Stopped',
                    LivePhase.error => 'Error',
                  }, style: PrismTypography.h2),
                  if (controller.phaseDetail.isNotEmpty)
                    Text(
                      controller.phaseDetail,
                      style: PrismTypography.meta.copyWith(
                        color: p.semanticDanger,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: PrismSpacing.md),
            PreflightStrip(controller: controller),
            const SizedBox(height: PrismSpacing.md),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.liveSrc.isEmpty ? '…' : controller.liveSrc,
                    style: PrismTypography.body,
                  ),
                  const SizedBox(height: PrismSpacing.sm),
                  Text(
                    controller.liveEn.isEmpty ? '—' : controller.liveEn,
                    style: PrismTypography.body.copyWith(
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: PrismSpacing.md),
            SessionSetupCard(controller: controller),
            const SizedBox(height: PrismSpacing.md),
            if (!capturing && !paused)
              PrimaryAction(
                label: controller.taskMode == 'transcribe'
                    ? 'START TRANSCRIPTION'
                    : 'START TRANSLATION',
                icon: Icons.play_arrow_rounded,
                onPressed: controller.phase == LivePhase.starting
                    ? null
                    : () => controller.start(),
              )
            else ...[
              PrimaryAction(
                label: paused ? 'RESUME' : 'PAUSE',
                icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                onPressed: paused ? controller.resume : controller.pause,
              ),
              const SizedBox(height: PrismSpacing.sm),
              PrimaryAction(
                label: 'STOP',
                icon: Icons.stop_rounded,
                onPressed: controller.stop,
              ),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Session setup (F-01/F-02)
// ---------------------------------------------------------------------------

/// Task-mode + source-language selection shown before a session starts.
/// Languages are validated against the installed-model capability matrix
/// (F-01): unsupported choices are visibly disabled, `auto` is always valid.
class SessionSetupCard extends StatelessWidget {
  const SessionSetupCard({super.key, required this.controller});

  final AppController controller;

  static const _languages = [
    'auto',
    'en',
    'ja',
    'ko',
    'zh',
    'es',
    'fr',
    'de',
    'tr',
    'ru',
    'pt',
    'it',
    'ar',
    'hi',
    'id',
    'vi',
    'th',
    'nl',
    'pl',
  ];

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final active = controller.activeModel;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'translate',
                label: Text('Translate'),
                icon: Icon(Icons.translate_rounded),
              ),
              ButtonSegment(
                value: 'transcribe',
                label: Text('Transcribe'),
                icon: Icon(Icons.graphic_eq_rounded),
              ),
            ],
            selected: {controller.taskMode},
            onSelectionChanged: (selection) =>
                controller.setTaskMode(selection.first),
          ),
          const SizedBox(height: PrismSpacing.sm),
          DropdownButtonFormField<String>(
            value: controller.defaultSrcLang,
            decoration: const InputDecoration(labelText: 'Source language'),
            items: _languages.map((lang) {
              final supported = controller.langSupported(lang);
              return DropdownMenuItem(
                value: lang,
                enabled: supported,
                child: Text(
                  lang == 'auto' ? 'Auto-detect' : lang,
                  style: PrismTypography.body.copyWith(
                    color: supported ? null : p.textSecondary,
                  ),
                ),
              );
            }).toList(),
            onChanged: (lang) {
              if (lang != null) controller.setDefaultSrcLang(lang);
            },
          ),
          // F-01 validation banner: warn when the preselected language is
          // not covered by any installed model.
          if (!controller.langSupported(controller.defaultSrcLang))
            Padding(
              padding: const EdgeInsets.only(top: PrismSpacing.xs),
              child: Text(
                'No installed model transcribes this language; install one '
                'on the Models tab.',
                style: PrismTypography.meta.copyWith(color: p.semanticDanger),
              ),
            ),
          if (active != null)
            Padding(
              padding: const EdgeInsets.only(top: PrismSpacing.xs),
              child: Text(
                'Model: ${active.label} (${active.tier})',
                style: PrismTypography.meta.copyWith(color: p.textSecondary),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: PrismSpacing.xs),
              child: Text(
                'No model loaded; native will fall back to a no-op engine. '
                'Load one on the Models tab.',
                style: PrismTypography.meta.copyWith(color: p.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preflight strip (G-02)
// ---------------------------------------------------------------------------

/// Permission pre-flight strip: overlay permission, battery exemption and an
/// app-compatibility summary. Passive probes auto-run on dashboard entry;
/// the overlay check is user-initiated because the native call deep-links
/// into system Settings when the permission is missing (contract §2.2).
class PreflightStrip extends StatelessWidget {
  const PreflightStrip({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);

    Widget? compatLine;
    if (controller.preflightChecking) {
      compatLine = Text(
        'Checking device…',
        style: PrismTypography.meta.copyWith(color: p.textSecondary),
      );
    } else if (controller.preflightError != null) {
      compatLine = Text(
        'Preflight unavailable on this platform',
        style: PrismTypography.meta.copyWith(color: p.textSecondary),
      );
    } else if (controller.compatRows.isNotEmpty) {
      final ok = controller.compatRows.where((r) => r.capturableLikely).length;
      compatLine = Text(
        '$ok of ${controller.compatRows.length} tested apps likely capturable',
        style: PrismTypography.meta.copyWith(color: p.textSecondary),
      );
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preflight', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          _PreflightRow(
            icon: Icons.layers_rounded,
            label: 'Overlay permission',
            state: controller.overlayPermissionGranted,
            actionLabel: controller.overlayPermissionGranted == true
                ? null
                : 'Check',
            onAction: controller.checkOverlayPermission,
          ),
          _PreflightRow(
            icon: Icons.battery_saver_rounded,
            label: 'Battery exemption',
            state: controller.batteryExemptionGranted,
            actionLabel: controller.batteryExemptionGranted == false
                ? 'Exempt'
                : null,
            onAction: controller.openBatteryExemptionSettings,
          ),
          if (compatLine != null)
            Padding(
              padding: const EdgeInsets.only(top: PrismSpacing.xs),
              child: compatLine,
            ),
        ],
      ),
    );
  }
}

class _PreflightRow extends StatelessWidget {
  const _PreflightRow({
    required this.icon,
    required this.label,
    required this.state,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String label;

  /// null = unchecked, true = ok, false = needs attention.
  final bool? state;
  final String? actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    return Row(
      children: [
        Icon(
          state == true
              ? Icons.check_circle_rounded
              : state == false
              ? Icons.error_outline_rounded
              : Icons.help_outline_rounded,
          size: 20,
          color: state == true
              ? p
                    .accentTeal // teal doubles as healthy green (§4.2 restraint)
              : state == false
              ? p.semanticDanger
              : p.textSecondary,
        ),
        const SizedBox(width: PrismSpacing.sm),
        Expanded(child: Text(label, style: PrismTypography.body)),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sessions list
// ---------------------------------------------------------------------------

/// Session browser (visual.md §4.4): newest-first cards, favorite + duplicate
/// + confirmed delete, with All/Favorites filter chips (D-04).
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  bool _favoritesOnly = false;

  AppController get controller => widget.controller;

  Future<void> _confirmDelete(Session s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          '"${s.title}" and all of its transcript segments will be '
          'permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) controller.deleteSession(s.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final all = controller.sessions.all();
        final list = _favoritesOnly
            ? all.where((s) => s.favorite).toList()
            : all;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PrismSpacing.md,
                vertical: PrismSpacing.sm,
              ),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('All')),
                  ButtonSegment(value: true, label: Text('Favorites')),
                ],
                selected: {_favoritesOnly},
                onSelectionChanged: (s) =>
                    setState(() => _favoritesOnly = s.first),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text(
                        _favoritesOnly ? 'No favorites yet' : 'No sessions yet',
                        style: PrismTypography.body.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                    )
                  : _buildList(list, p),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList(List<Session> list, PrismPalette p) {
    return ListView.builder(
      padding: const EdgeInsets.all(PrismSpacing.md),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final s = list[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: PrismSpacing.sm),
          child: GlassCard(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    EditorScreen(controller: controller, sessionId: s.id),
              ),
            ),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconButton(
                icon: Icon(
                  s.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: s.favorite ? p.accentTeal : p.textSecondary,
                ),
                onPressed: () => controller.toggleFavorite(s.id),
              ),
              title: Text(s.title, style: PrismTypography.body),
              subtitle: Text(
                '${controller.segments.forSession(s.id).length} segments',
                style: PrismTypography.meta.copyWith(color: p.textSecondary),
              ),
              trailing: PopupMenuButton<String>(
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
                onSelected: (action) {
                  if (action == 'duplicate') {
                    controller.duplicateSession(s.id);
                  } else if (action == 'delete') {
                    _confirmDelete(s);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/// Global transcript search (D-06): prefix search across source+translated.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Segment> _hits = const [];

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(PrismSpacing.md),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search transcripts…',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (q) =>
                setState(() => _hits = widget.controller.segments.search(q)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: PrismSpacing.md),
            itemCount: _hits.length,
            itemBuilder: (context, i) {
              final seg = _hits[i];
              final session = widget.controller.sessions.byId(seg.sessionId);
              return Padding(
                padding: const EdgeInsets.only(bottom: PrismSpacing.sm),
                child: GlassCard(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditorScreen(
                        controller: widget.controller,
                        sessionId: seg.sessionId,
                      ),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(seg.sourceText, style: PrismTypography.body),
                    subtitle: Text(
                      session?.title ?? 'Unknown session',
                      style: PrismTypography.meta.copyWith(
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Settings (visual.md §4.7): appearance, overlay behaviour, languages,
/// governor bindings (live-pushed to native) + privacy info.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(PrismSpacing.md),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Appearance', style: PrismTypography.h2),
                const SizedBox(height: PrismSpacing.sm),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {controller.themeMode},
                  onSelectionChanged: (s) => controller.setThemeMode(s.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: PrismSpacing.md),
          _OverlaySettingsCard(controller: controller),
          const SizedBox(height: PrismSpacing.md),
          _GovernorSettingsCard(controller: controller),
          const SizedBox(height: PrismSpacing.md),
          _LangsSettingsCard(controller: controller),
          const SizedBox(height: PrismSpacing.md),
          const _DiagnosticsCard(),
          const SizedBox(height: PrismSpacing.md),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Privacy', style: PrismTypography.h2),
                const SizedBox(height: PrismSpacing.sm),
                Text(
                  'Everything runs on-device. No cloud, no telemetry. '
                  'The only network access is the one-time model download.',
                  style: PrismTypography.body,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings — overlay / governor / langs bindings (live-push to native)
// ---------------------------------------------------------------------------

/// Overlay behaviour bindings (§2.4): every change persists in Dart prefs AND
/// fires `setOverlayStyle` so a running overlay restyles itself live (C-04).
class _OverlaySettingsCard extends StatelessWidget {
  const _OverlaySettingsCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.overlayStyle;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overlay', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          _SettingsSlider(
            label: 'Font size',
            value: s.fontSizeSp,
            min: 12,
            max: 28,
            divisions: 16,
            format: (v) => '${v.toStringAsFixed(0)} sp',
            onChanged: (v) =>
                controller.updateOverlayStyle(s.copyWith(fontSizeSp: v)),
          ),
          _SettingsSlider(
            label: 'Background opacity',
            value: s.backgroundOpacity,
            min: 0,
            max: 1,
            divisions: 20,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) =>
                controller.updateOverlayStyle(s.copyWith(backgroundOpacity: v)),
          ),
          _SettingsSlider(
            label: 'Idle collapse',
            value: s.idleCollapseSeconds.toDouble(),
            min: 0,
            max: 10,
            divisions: 10,
            format: (v) => v == 0 ? 'Off' : '${v.toStringAsFixed(0)} s',
            onChanged: (v) => controller.updateOverlayStyle(
              s.copyWith(idleCollapseSeconds: v.round()),
            ),
          ),
          const SizedBox(height: PrismSpacing.xs),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('1 line')),
              ButtonSegment(value: 2, label: Text('2 lines')),
              ButtonSegment(value: 3, label: Text('3 lines')),
            ],
            selected: {s.maxLines},
            onSelectionChanged: (sel) =>
                controller.updateOverlayStyle(s.copyWith(maxLines: sel.first)),
          ),
          const SizedBox(height: PrismSpacing.sm),
          SegmentedButton<OverlayTheme>(
            segments: const [
              ButtonSegment(value: OverlayTheme.glass, label: Text('Glass')),
              ButtonSegment(value: OverlayTheme.solid, label: Text('Solid')),
            ],
            selected: {s.theme},
            onSelectionChanged: (sel) =>
                controller.updateOverlayStyle(s.copyWith(theme: sel.first)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Bilingual source line'),
            subtitle: const Text('Show original text above the translation'),
            value: s.showBilingual,
            onChanged: (v) =>
                controller.updateOverlayStyle(s.copyWith(showBilingual: v)),
          ),
        ],
      ),
    );
  }
}

/// Governor bindings (§2.2 `setGovernorPrefs`, PRD B-07): pushed to native on
/// every change; native persists and applies them to the governor matrix.
class _GovernorSettingsCard extends StatelessWidget {
  const _GovernorSettingsCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final g = controller.governorPrefs;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Power & thermal', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pause when screen turns off'),
            value: g.screenOffAutoPause,
            onChanged: (v) => controller.updateGovernorPrefs(
              GovernorPrefs(
                screenOffAutoPause: v,
                batteryLowThresholdPct: g.batteryLowThresholdPct,
                thermalHysteresisMs: g.thermalHysteresisMs,
                inferenceQueueDepth: g.inferenceQueueDepth,
              ),
            ),
          ),
          _SettingsSlider(
            label: 'Low-battery auto-pause',
            value: g.batteryLowThresholdPct.toDouble(),
            min: 0,
            max: 50,
            divisions: 10,
            format: (v) => v == 0 ? 'Off' : '${v.toStringAsFixed(0)}%',
            onChanged: (v) => controller.updateGovernorPrefs(
              GovernorPrefs(
                screenOffAutoPause: g.screenOffAutoPause,
                batteryLowThresholdPct: v.round(),
                thermalHysteresisMs: g.thermalHysteresisMs,
                inferenceQueueDepth: g.inferenceQueueDepth,
              ),
            ),
          ),
          _SettingsSlider(
            label: 'Inference queue depth',
            value: g.inferenceQueueDepth.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) => controller.updateGovernorPrefs(
              GovernorPrefs(
                screenOffAutoPause: g.screenOffAutoPause,
                batteryLowThresholdPct: g.batteryLowThresholdPct,
                thermalHysteresisMs: g.thermalHysteresisMs,
                inferenceQueueDepth: v.round(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Source-language preselection (F-01 v1): persisted and used as the default
/// for the Dashboard start action; respects HT-3 (target is always English).
class _LangsSettingsCard extends StatelessWidget {
  const _LangsSettingsCard({required this.controller});

  static const _langs = <String, String>{
    'auto': 'Auto-detect',
    'ja': 'Japanese',
    'ko': 'Korean',
    'tr': 'Turkish',
    'en': 'English',
  };

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Languages', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          DropdownButtonFormField<String>(
            value: controller.defaultSrcLang,
            decoration: const InputDecoration(
              labelText: 'Source language',
              border: OutlineInputBorder(),
            ),
            items: _langs.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (lang) {
              if (lang != null) controller.setDefaultSrcLang(lang);
            },
          ),
        ],
      ),
    );
  }
}

/// Shared labeled slider row for the settings cards.
class _SettingsSlider extends StatelessWidget {
  const _SettingsSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: PrismTypography.body),
            Text(
              format(value.clamp(min, max)),
              style: PrismTypography.meta.copyWith(color: p.textSecondary),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
// ---------------------------------------------------------------------------
// Models (Epic 6: E-01 registry, E-02 downloads, E-03 benchmark, E-04 swap)
// ---------------------------------------------------------------------------

/// Model management screen: the curated registry with per-model install /
/// download state, download controls with live progress, hot load/unload,
/// and the self-reported on-device benchmark (Results section, E-03).
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshCapabilities();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final p = PrismColors.of(Theme.of(context).brightness);

        return ListView(
          padding: const EdgeInsets.all(PrismSpacing.md),
          children: [
            Text('Models', style: PrismTypography.h1),
            const SizedBox(height: PrismSpacing.sm),
            if (controller.capabilitiesError != null)
              Text(
                'Registry unavailable: ${controller.capabilitiesError}',
                style: PrismTypography.meta.copyWith(color: p.semanticDanger),
              ),
            if (controller.lastModelError != null)
              Text(
                'Load failed: ${controller.lastModelError}',
                style: PrismTypography.meta.copyWith(color: p.semanticDanger),
              ),
            if (controller.loadingCapabilities)
              Text(
                'Reading registry...',
                style: PrismTypography.meta.copyWith(color: p.textSecondary),
              ),
            const SizedBox(height: PrismSpacing.sm),
            for (final model in controller.models)
              Padding(
                padding: const EdgeInsets.only(bottom: PrismSpacing.md),
                child: _ModelCard(model: model, controller: controller),
              ),
            _BenchmarkCard(controller: controller),
          ],
        );
      },
    );
  }
}

/// One registry entry: identity, capability matrix line, and the state-driven
/// action row (download/pause/cancel/resume/retry + load/unload).
class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model, required this.controller});

  final ModelInfo model;
  final AppController controller;

  String get _sizeLabel {
    final mb = model.sizeBytes / (1024 * 1024);
    return mb >= 1 ? '${mb.round()} MB' : '${model.sizeBytes} B';
  }

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final isActive = controller.activeModel?.id == model.id;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(model.label, style: PrismTypography.h2)),
              if (isActive)
                Icon(Icons.check_circle_rounded, size: 20, color: p.accentTeal),
            ],
          ),
          const SizedBox(height: PrismSpacing.xs),
          Text(
            '${model.tier} - $_sizeLabel - '
            '${model.installed ? "installed" : "not installed"}'
            '${model.downloadable ? "" : " (bundled)"}',
            style: PrismTypography.meta.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: PrismSpacing.xs),
          Text(
            'RAM ${model.minRamMb}MB+ - langs: '
            '${model.languages.length} - tasks: ${model.tasks.join(", ")}',
            style: PrismTypography.meta.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: PrismSpacing.sm),
          _actionRow(context, p),
        ],
      ),
    );
  }

  Widget _actionRow(BuildContext context, PrismPalette p) {
    final progress = controller.downloadProgressFor(model.id);
    final isActive = controller.activeModel?.id == model.id;

    // Live download state wins over the static registry snapshot: a
    // ModelDownloadProgress event with an active phase must drive the card
    // immediately, before any capabilities refresh lands. Only when the
    // live event is terminal/absent do we fall back to model.downloadState.
    final phase =
        (progress == null ||
            progress.state == DownloadPhase.idle ||
            progress.state == DownloadPhase.done)
        ? model.downloadState
        : progress.state;

    switch (phase) {
      case DownloadPhase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: PrismSpacing.xs),
            Text(
              '${_mb(progress?.bytesDone)} / ${_mb(progress?.bytesTotal)} MB'
              ' - downloading',
              style: PrismTypography.meta.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: PrismSpacing.sm),
            Row(
              children: [
                TextButton(
                  onPressed: () => controller.pauseDownload(model.id),
                  child: const Text('Pause'),
                ),
                const SizedBox(width: PrismSpacing.sm),
                TextButton(
                  onPressed: () => controller.cancelDownload(model.id),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      case DownloadPhase.paused:
        return Row(
          children: [
            TextButton(
              onPressed: () => controller.downloadModel(model.id),
              child: const Text('Resume'),
            ),
            const SizedBox(width: PrismSpacing.sm),
            TextButton(
              onPressed: () => controller.cancelDownload(model.id),
              child: const Text('Cancel'),
            ),
          ],
        );
      case DownloadPhase.verifying:
        return const LinearProgressIndicator(); // indeterminate
      case DownloadPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download failed: '
              '${controller.downloadError ?? 'unknown error'}',
              style: PrismTypography.meta.copyWith(color: p.semanticDanger),
            ),
            const SizedBox(height: PrismSpacing.sm),
            Row(
              children: [
                TextButton(
                  onPressed: () => controller.downloadModel(model.id),
                  child: const Text('Retry'),
                ),
                const SizedBox(width: PrismSpacing.sm),
                TextButton(
                  onPressed: () => controller.cancelDownload(model.id),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      case DownloadPhase.idle:
      case DownloadPhase.done:
        // E-04: hot load / hot-swap for installed models; download for the
        // rest. Bundled + not installed should not happen (materialized on
        // first load), but keep the Download affordance safe anyway.
        if (model.installed) {
          return TextButton(
            onPressed: isActive ? null : () => controller.loadModel(model.id),
            child: Text(isActive ? 'Active' : 'Load'),
          );
        }
        return model.downloadable
            ? TextButton(
                onPressed: () => controller.downloadModel(model.id),
                child: Text('Download ($_sizeLabel)'),
              )
            : Text(
                'Bundled model not materialized; load once to install.',
                style: PrismTypography.meta.copyWith(color: p.textSecondary),
              );
    }
  }

  static String _mb(int? bytes) =>
      ((bytes ?? 0) / (1024 * 1024)).toStringAsFixed(1);
}

/// E-03 results card: run button + self-reported metrics table. Disabled
/// while a session runs (the native harness refuses; the error surfaces).
class _BenchmarkCard extends StatelessWidget {
  const _BenchmarkCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);
    final result = controller.lastBenchmark;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Benchmark', style: PrismTypography.h2),
          const SizedBox(height: PrismSpacing.sm),
          if (controller.benchmarkError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: PrismSpacing.sm),
              child: Text(
                controller.benchmarkError!,
                style: PrismTypography.meta.copyWith(color: p.semanticDanger),
              ),
            ),
          if (result != null) ...[
            _metric('RTF', result.rtf.toStringAsFixed(3)),
            _metric('Latency p50', '${result.latencyP50Ms.round()} ms'),
            _metric('Latency p90', '${result.latencyP90Ms.round()} ms'),
            _metric('RAM (PSS)', '${result.rssMb.round()} MB'),
            _metric(
              'Battery est.',
              '${result.batteryPctPerMin.toStringAsFixed(3)} %/min audio',
            ),
            _metric('Rounds', '${result.rounds}'),
            const SizedBox(height: PrismSpacing.sm),
          ] else
            Text(
              controller.benchmarking
                  ? 'Running scripted harness...'
                  : 'Run the on-device harness to measure this model.',
              style: PrismTypography.meta.copyWith(color: p.textSecondary),
            ),
          const SizedBox(height: PrismSpacing.sm),
          PrimaryAction(
            label: controller.benchmarking
                ? 'BENCHMARKING...'
                : 'RUN BENCHMARK',
            icon: Icons.speed_rounded,
            onPressed: controller.benchmarking ? null : controller.runBenchmark,
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: PrismSpacing.xs),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: PrismTypography.body),
        Text(value, style: PrismTypography.body),
      ],
    ),
  );
}

/// Crash forensics (Settings → Diagnostics): shows the on-device crash log
/// captured by the native `LivelensApplication` handler, so a field crash
/// can be read back without adb. Empty state = no crash recorded.
class _DiagnosticsCard extends StatefulWidget {
  const _DiagnosticsCard();

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  bool _loading = false;

  Future<void> _show() async {
    setState(() => _loading = true);
    String log;
    try {
      log = await LivelensControl().crashLog();
    } catch (_) {
      log = 'Could not read the crash log.';
    }
    if (!mounted) return;
    setState(() => _loading = false);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.all(PrismSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Crash log', style: PrismTypography.h2),
                const SizedBox(height: PrismSpacing.sm),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      log.isEmpty ? 'No crash recorded on this device.' : log,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Diagnostics'),
        subtitle: const Text('View the on-device crash log'),
        trailing: _loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right),
        onTap: _loading ? null : _show,
      ),
    );
  }
}
