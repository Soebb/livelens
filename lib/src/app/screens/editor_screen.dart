import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livelens/design.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models.dart';
import '../../export/exporters.dart';
import '../app_controller.dart';

/// Transcript editor (D-05, visual.md §4.5): editable bilingual lines +
/// rename/favorite/export entry point. Segments are saved on change.
class EditorScreen extends StatelessWidget {
  const EditorScreen({
    super.key,
    required this.controller,
    required this.sessionId,
  });

  final AppController controller;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final session = controller.sessions.byId(sessionId);
    if (session == null) {
      return const Scaffold(body: Center(child: Text('Session not found')));
    }

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () async {
            final name = await _promptRename(context, session.title);
            if (name != null && name.isNotEmpty) {
              controller.renameSession(sessionId, name);
            }
          },
          child: Text(session.title, style: PrismTypography.h2),
        ),
        actions: [
          IconButton(
            icon: Icon(
              session.favorite
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
            ),
            onPressed: () => controller.toggleFavorite(sessionId),
          ),
          IconButton(
            tooltip: 'Export / share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => _showExportSheet(context, session),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final segs = controller.segments.forSession(sessionId);
          final p = PrismColors.of(Theme.of(context).brightness);

          if (segs.isEmpty) {
            return Center(
              child: Text(
                'No segments yet',
                style: PrismTypography.body.copyWith(color: p.textSecondary),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(PrismSpacing.md),
            itemCount: segs.length,
            itemBuilder: (context, i) =>
                _SegmentTile(controller: controller, segment: segs[i]),
          );
        },
      ),
    );
  }

  /// Export sheet (visual.md §4.6): format tabs + include-timestamps toggle,
  /// then Share (OS share intent, D-09) or Copy to clipboard.
  Future<void> _showExportSheet(BuildContext context, Session session) {
    var format = ExportFormat.txt;
    var withTimestamps = true;

    String render() => SessionExporter.render(
      format,
      session,
      controller.segments.forSession(sessionId),
      includeTimestamps: withTimestamps,
    );

    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(
            PrismSpacing.lg,
            0,
            PrismSpacing.lg,
            PrismSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Export transcript', style: PrismTypography.h2),
              const SizedBox(height: PrismSpacing.md),
              SegmentedButton<ExportFormat>(
                segments: ExportFormat.values
                    .map(
                      (f) => ButtonSegment(
                        value: f,
                        // Single-line, non-wrapping labels: the checkmark
                        // otherwise squeezes short labels into vertical wrap
                        // ("MD" → "M"/"D") once a segment is selected.
                        label: Text(
                          f.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    )
                    .toList(),
                selected: {format},
                // No per-segment check icon: it steals width from the labels
                // and is the cause of the horizontal→vertical label flip.
                showSelectedIcon: false,
                onSelectionChanged: (s) => setSheetState(() => format = s.first),
              ),
              SwitchListTile(
                title: const Text('Include timestamps'),
                value: withTimestamps,
                onChanged: (v) => setSheetState(() => withTimestamps = v),
              ),
              const SizedBox(height: PrismSpacing.sm),
              FilledButton.icon(
                icon: const Icon(Icons.share_rounded),
                label: const Text('SHARE'),
                onPressed: () {
                  final text = render();
                  Navigator.pop(sheetContext);
                  SharePlus.instance.share(
                    ShareParams(text: text, subject: session.title),
                  );
                },
              ),
              const SizedBox(height: PrismSpacing.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy_rounded),
                label: const Text('COPY TO CLIPBOARD'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: render()));
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(
                      content: Text('Transcript copied to clipboard'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _promptRename(BuildContext context, String current) {
    final field = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(controller: field, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({required this.controller, required this.segment});

  final AppController controller;
  final Segment segment;

  @override
  Widget build(BuildContext context) {
    final p = PrismColors.of(Theme.of(context).brightness);

    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: PrismSpacing.md,
        vertical: PrismSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _fmtClock(segment.t0Ms),
                  style: PrismTypography.meta.copyWith(
                    color: p.textSecondary,
                  ),
                ),
              ),
              _SegmentMenu(controller: controller, segment: segment),
            ],
          ),
          _EditableLine(
            initial: segment.sourceText,
            onSave: (v) =>
                controller.segments.updateText(segment.id, sourceText: v),
          ),
          const Divider(height: PrismSpacing.sm),
          _EditableLine(
            initial: segment.translatedText,
            onSave: (v) =>
                controller.segments.updateText(segment.id, translatedText: v),
          ),
        ],
      ),
    );
  }
}

/// Overflow menu per segment: merge with next / split at caret-free midpoint.
class _SegmentMenu extends StatelessWidget {
  const _SegmentMenu({required this.controller, required this.segment});

  final AppController controller;
  final Segment segment;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'merge', child: Text('Merge with next')),
        PopupMenuItem(value: 'split', child: Text('Split')),
      ],
      onSelected: (action) {
        switch (action) {
          case 'merge':
            controller.segments.mergeWithNext(segment.id);
          case 'split':
            // Split at the midpoint of the source line.
            final mid = (segment.sourceText.length / 2).round();
            controller.segments.split(segment.id, sourceCharIndex: mid);
        }
      },
    );
  }
}

class _EditableLine extends StatelessWidget {
  const _EditableLine({required this.initial, required this.onSave});

  final String initial;
  final ValueChanged<String> onSave;

  @override
  Widget build(BuildContext context) {
    final field = TextEditingController(text: initial);
    return TextField(
      controller: field,
      style: PrismTypography.body,
      maxLines: null,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
      ),
      onSubmitted: onSave,
    );
  }
}

String _fmtClock(double ms) {
  final total = (ms / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
