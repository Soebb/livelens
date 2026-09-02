import 'package:flutter/foundation.dart';

/// Task requested of the Whisper recognizer (contract §2.1).
enum LivelensTask {
  /// Source language → English (Whisper `task=translate`; HT-3: en-only).
  translate('translate'),

  /// Source → source captions (Whisper `task=transcribe`).
  transcribe('transcribe');

  const LivelensTask(this.wireName);
  final String wireName;
}

/// Model capability tier (contract §2.2; PRD E-01).
enum ModelTier {
  fast('fast'),
  balanced('balanced'),
  quality('quality');

  const ModelTier(this.wireName);
  final String wireName;

  static ModelTier? tryFromWire(Object? value) {
    if (value is! String) return null;
    for (final t in values) {
      if (t.wireName == value) return t;
    }
    return null;
  }
}

/// One entry of the curated model registry as reported by native
/// (`getCapabilities` → `availableModels[]`, contract §2.2).
///
/// The first five fields are the frozen §2.2 shape; everything after is
/// additive (Epic 6) and defaults sensibly when an older native omits it.
@immutable
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.label,
    required this.tier,
    required this.sizeBytes,
    required this.installed,
    this.downloadable = true,
    this.tasks = const ['transcribe', 'translate'],
    this.languages = const ['en'],
    this.minRamMb = 0,
    this.downloadState = DownloadPhase.idle,
  });

  /// Stable slug, e.g. `whisper-tiny-int8`.
  final String id;
  final String label;
  final ModelTier tier;

  /// Download size in bytes.
  final int sizeBytes;

  /// Whether the model is installed under `filesDir/models/`.
  final bool installed;

  /// False when the files ship inside the APK (E-02: nothing to download).
  final bool downloadable;

  /// Supported Whisper tasks (subset of {transcribe, translate}).
  final List<String> tasks;

  /// ISO-639-1 source languages the model can transcribe (E-01 matrix).
  final List<String> languages;

  /// Minimum device total RAM (MB) required to load this model.
  final int minRamMb;

  /// Last-reported download lifecycle phase (E-02).
  final DownloadPhase downloadState;

  /// Whether [lang] can be transcribed by this model (F-01 validation).
  bool supportsLanguage(String lang) =>
      lang == 'auto' || languages.contains(lang);

  /// Whether this model can run [task].
  bool supportsTask(String task) => tasks.contains(task);

  factory ModelInfo.fromWire(Object? raw) {
    if (raw is! Map) {
      throw const _WireShapeException('ModelInfo expects a map');
    }
    final id = raw['id'];
    final label = raw['label'];
    final tier = ModelTier.tryFromWire(raw['tier']);
    final sizeBytes = raw['sizeBytes'];
    final installed = raw['installed'];
    if (id is! String ||
        label is! String ||
        tier == null ||
        sizeBytes is! int ||
        installed is! bool) {
      throw const _WireShapeException(
        'ModelInfo requires {id,label:String, tier:fast|balanced|quality, '
        'sizeBytes:int, installed:bool}',
      );
    }
    // Additive extras (Epic 6) — tolerate absence and malformed values.
    final tasks = raw['tasks'];
    final languages = raw['languages'];
    final minRamMb = raw['minRamMb'];
    return ModelInfo(
      id: id,
      label: label,
      tier: tier,
      sizeBytes: sizeBytes,
      installed: installed,
      downloadable: raw['downloadable'] is bool
          ? raw['downloadable'] as bool
          : true,
      tasks: tasks is List && tasks.every((t) => t is String)
          ? List<String>.from(tasks)
          : const ['transcribe', 'translate'],
      languages: languages is List && languages.every((l) => l is String)
          ? List<String>.from(languages)
          : const ['en'],
      minRamMb: minRamMb is int ? minRamMb : 0,
      downloadState: DownloadPhase.tryFromWire(raw['downloadState']),
    );
  }

  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'id': id,
    'label': label,
    'tier': tier.wireName,
    'sizeBytes': sizeBytes,
    'installed': installed,
    'downloadable': downloadable,
    'tasks': tasks,
    'languages': languages,
    'minRamMb': minRamMb,
    'downloadState': downloadState.wireName,
  };

  @override
  bool operator ==(Object other) =>
      other is ModelInfo &&
      id == other.id &&
      label == other.label &&
      tier == other.tier &&
      sizeBytes == other.sizeBytes &&
      installed == other.installed &&
      downloadable == other.downloadable &&
      minRamMb == other.minRamMb &&
      downloadState == other.downloadState;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    tier,
    sizeBytes,
    installed,
    downloadable,
    minRamMb,
    downloadState,
  );

  @override
  String toString() =>
      'ModelInfo($id, $tier, ${installed ? "in" : "not "}stalled)';
}

/// Download lifecycle phases streamed on the additive `livelens/model_events`
/// channel (E-02; the §3 event set stays frozen).
enum DownloadPhase {
  idle('idle'),
  downloading('downloading'),
  paused('paused'),
  verifying('verifying'),
  done('done'),
  failed('failed');

  const DownloadPhase(this.wireName);
  final String wireName;

  /// Unrecognized values fall back to [idle] (additive-change rule).
  static DownloadPhase tryFromWire(Object? value) {
    if (value is String) {
      for (final p in values) {
        if (p.wireName == value) return p;
      }
    }
    return idle;
  }
}

/// One `modelDownload` progress message (E-02, additive channel).
@immutable
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.modelId,
    required this.state,
    required this.bytesDone,
    required this.bytesTotal,
    this.error = '',
  });

  final String modelId;
  final DownloadPhase state;
  final int bytesDone;
  final int bytesTotal;

  /// Registry error code string (`MODEL_SPACE`, `MODEL_CHECKSUM`, ...);
  /// empty unless [state] is [DownloadPhase.failed].
  final String error;

  /// 0..1; safe for zero-byte totals.
  double get fraction =>
      bytesTotal <= 0 ? 0 : (bytesDone / bytesTotal).clamp(0.0, 1.0);

  factory ModelDownloadProgress.fromWire(Object? raw) {
    if (raw is! Map) {
      throw const _WireShapeException('modelDownload expects a map');
    }
    final modelId = raw['modelId'];
    final bytesDone = raw['bytesDone'];
    final bytesTotal = raw['bytesTotal'];
    if (modelId is! String || bytesDone is! int || bytesTotal is! int) {
      throw const _WireShapeException(
        'modelDownload requires {modelId:String, bytesDone:int, bytesTotal:int}',
      );
    }
    final error = raw['error'];
    return ModelDownloadProgress(
      modelId: modelId,
      state: DownloadPhase.tryFromWire(raw['state']),
      bytesDone: bytesDone,
      bytesTotal: bytesTotal,
      error: error is String ? error : '',
    );
  }

  /// Serializes back to the additive channel's wire shape (round-trip safe).
  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'type': 'modelDownload',
    'v': 1,
    'modelId': modelId,
    'state': state.wireName,
    'bytesDone': bytesDone,
    'bytesTotal': bytesTotal,
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is ModelDownloadProgress &&
      modelId == other.modelId &&
      state == other.state &&
      bytesDone == other.bytesDone &&
      bytesTotal == other.bytesTotal &&
      error == other.error;

  @override
  int get hashCode =>
      Object.hash(modelId, state, bytesDone, bytesTotal, error);

  @override
  String toString() =>
      'ModelDownloadProgress($modelId, $state, $bytesDone/$bytesTotal)';
}

/// Reply payload of `runBenchmark` (E-03): self-reported on-device stats.
@immutable
class BenchmarkResult {
  const BenchmarkResult({
    required this.rounds,
    required this.chunkSeconds,
    required this.rtf,
    required this.latencyP50Ms,
    required this.latencyP90Ms,
    required this.rssMb,
    required this.batteryPctPerMin,
  });

  final int rounds;

  /// Length of the scripted chunk in seconds (Kotlin doubles, e.g. 5.0).
  final double chunkSeconds;

  /// Real-time factor: decode seconds per second of audio.
  final double rtf;
  final double latencyP50Ms;
  final double latencyP90Ms;
  final double rssMb;

  /// Honest estimate: % of battery per minute of captured audio.
  final double batteryPctPerMin;

  factory BenchmarkResult.fromWire(Object? raw) {
    if (raw is! Map) {
      throw const _WireShapeException('runBenchmark expects a map');
    }
    final rounds = raw['rounds'];
    final chunkSeconds = raw['chunkSeconds'];
    final rtf = raw['rtf'];
    final p50 = raw['latencyP50Ms'];
    final p90 = raw['latencyP90Ms'];
    final rssMb = raw['rssMb'];
    final battery = raw['batteryPctPerMin'];
    if (rounds is! int ||
        chunkSeconds is! num ||
        rtf is! num ||
        p50 is! num ||
        p90 is! num ||
        rssMb is! num ||
        battery is! num) {
      throw const _WireShapeException(
        'runBenchmark requires {rounds:int, chunkSeconds:num, rtf:number, '
        'latencyP50Ms:number, latencyP90Ms:number, rssMb:number, '
        'batteryPctPerMin:number}',
      );
    }
    return BenchmarkResult(
      rounds: rounds,
      chunkSeconds: chunkSeconds.toDouble(),
      rtf: rtf.toDouble(),
      latencyP50Ms: p50.toDouble(),
      latencyP90Ms: p90.toDouble(),
      rssMb: rssMb.toDouble(),
      batteryPctPerMin: battery.toDouble(),
    );
  }

  @override
  String toString() =>
      'BenchmarkResult(rtf=${rtf.toStringAsFixed(3)}, '
      'p50=${latencyP50Ms.toStringAsFixed(0)}ms, '
      'p90=${latencyP90Ms.toStringAsFixed(0)}ms)';
}

/// Reply payload of `getCapabilities` (contract §2.2).
@immutable
class Capabilities {
  const Capabilities({
    required this.activeModelId,
    required this.downloadPath,
    required this.availableModels,
  });

  /// Currently hot-loaded model, or `null` when none.
  final String? activeModelId;

  /// Absolute path of `filesDir/models/` on device.
  final String downloadPath;
  final List<ModelInfo> availableModels;

  factory Capabilities.fromWire(Object? raw) {
    if (raw is! Map) {
      throw const _WireShapeException('Capabilities expects a map');
    }
    final active = raw['activeModelId'];
    final path = raw['downloadPath'];
    final models = raw['availableModels'];
    if (path is! String || models is! List) {
      throw const _WireShapeException(
        'Capabilities requires {downloadPath:String, availableModels:List}',
      );
    }
    if (active != null && active is! String) {
      throw const _WireShapeException('activeModelId must be String|null');
    }
    return Capabilities(
      activeModelId: active as String?,
      downloadPath: path,
      availableModels: models.map(ModelInfo.fromWire).toList(growable: false),
    );
  }

  @override
  String toString() =>
      'Capabilities(active=$activeModelId, models=${availableModels.length})';
}

/// One row of `performCompatCheck` output (contract §2.3; PRD A-06).
@immutable
class CompatEntry {
  const CompatEntry({
    required this.pkg,
    required this.label,
    required this.capturableLikely,
  });

  final String pkg;
  final String label;
  final bool capturableLikely;

  factory CompatEntry.fromWire(Object? raw) {
    if (raw is! Map) {
      throw const _WireShapeException('CompatEntry expects a map');
    }
    final pkg = raw['pkg'];
    final label = raw['label'];
    final capturable = raw['capturableLikely'];
    if (pkg is! String || label is! String || capturable is! bool) {
      throw const _WireShapeException(
        'CompatEntry requires {pkg,label:String, capturableLikely:bool}',
      );
    }
    return CompatEntry(pkg: pkg, label: label, capturableLikely: capturable);
  }

  @override
  String toString() =>
      'CompatEntry($pkg "$label" capturable=$capturableLikely)';
}

/// Overlay appearance tokens pushed live to the native overlay
/// (`setOverlayStyle`, contract §2.4; visual.md Part 4 defaults).
@immutable
class OverlayStyle {
  const OverlayStyle({
    this.fontSizeSp = 18.0,
    this.backgroundOpacity = 0.82,
    this.maxLines = 2,
    this.textAlign = OverlayTextAlign.center,
    this.cornerRadiusPx = 20.0,
    this.textShadowArgb = 0xFF000000,
    this.theme = OverlayTheme.glass,
    this.showBilingual = false,
    this.idleCollapseSeconds = 3,
    this.maxWidthFraction = 0.78,
  }) : assert(
         backgroundOpacity >= 0 && backgroundOpacity <= 1,
         'backgroundOpacity must be within 0..1',
       ),
       assert(maxLines >= 1 && maxLines <= 5, 'maxLines must be 1..5'),
       assert(
         idleCollapseSeconds >= 0 && idleCollapseSeconds <= 10,
         'idleCollapseSeconds must be 0..10',
       ),
       assert(
         maxWidthFraction > 0 && maxWidthFraction <= 1,
         'maxWidthFraction must be within (0..1]',
       );

  final double fontSizeSp;
  final double backgroundOpacity;
  final int maxLines;
  final OverlayTextAlign textAlign;
  final double cornerRadiusPx;
  final int textShadowArgb;
  final OverlayTheme theme;

  /// Bilingual display toggle (C-05). Data is always stored regardless.
  final bool showBilingual;

  /// Idle auto-collapse delay; 0 disables collapsing.
  final int idleCollapseSeconds;

  /// Fraction of display width the overlay may occupy (wireframe: 78%).
  final double maxWidthFraction;

  /// Parses a (possibly partial) wire map, filling missing or malformed keys
  /// with the contract §2.4 defaults — mirrors the native `OverlayStyle.fromWire`
  /// so persisted/hand-written maps round-trip safely.
  factory OverlayStyle.fromWire(Object? raw) {
    if (raw is! Map) return const OverlayStyle();
    double d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
    int i(Object? v, int fallback) => v is int ? v : fallback;

    final align = OverlayTextAlign.values
        .where((a) => a.wireName == raw['textAlign'])
        .firstOrNull;
    final theme = OverlayTheme.values
        .where((t) => t.wireName == raw['theme'])
        .firstOrNull;

    return OverlayStyle(
      fontSizeSp: d(raw['fontSizeSp'], 18.0),
      backgroundOpacity: d(raw['backgroundOpacity'], 0.82),
      maxLines: i(raw['maxLines'], 2),
      textAlign: align ?? OverlayTextAlign.center,
      cornerRadiusPx: d(raw['cornerRadiusPx'], 20.0),
      textShadowArgb: i(raw['textShadowArgb'], 0xFF000000),
      theme: theme ?? OverlayTheme.glass,
      showBilingual: raw['showBilingual'] is bool
          ? raw['showBilingual'] as bool
          : false,
      idleCollapseSeconds: i(raw['idleCollapseSeconds'], 3),
      maxWidthFraction: d(raw['maxWidthFraction'], 0.78),
    );
  }

  /// Copy with the given fields replaced; unchanged fields keep their value.
  OverlayStyle copyWith({
    double? fontSizeSp,
    double? backgroundOpacity,
    int? maxLines,
    OverlayTextAlign? textAlign,
    double? cornerRadiusPx,
    int? textShadowArgb,
    OverlayTheme? theme,
    bool? showBilingual,
    int? idleCollapseSeconds,
    double? maxWidthFraction,
  }) => OverlayStyle(
    fontSizeSp: fontSizeSp ?? this.fontSizeSp,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    maxLines: maxLines ?? this.maxLines,
    textAlign: textAlign ?? this.textAlign,
    cornerRadiusPx: cornerRadiusPx ?? this.cornerRadiusPx,
    textShadowArgb: textShadowArgb ?? this.textShadowArgb,
    theme: theme ?? this.theme,
    showBilingual: showBilingual ?? this.showBilingual,
    idleCollapseSeconds: idleCollapseSeconds ?? this.idleCollapseSeconds,
    maxWidthFraction: maxWidthFraction ?? this.maxWidthFraction,
  );

  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'fontSizeSp': fontSizeSp,
    'backgroundOpacity': backgroundOpacity,
    'maxLines': maxLines,
    'textAlign': textAlign.wireName,
    'cornerRadiusPx': cornerRadiusPx,
    'textShadowArgb': textShadowArgb,
    'theme': theme.wireName,
    'showBilingual': showBilingual,
    'idleCollapseSeconds': idleCollapseSeconds,
    'maxWidthFraction': maxWidthFraction,
  };

  @override
  bool operator ==(Object other) =>
      other is OverlayStyle &&
      fontSizeSp == other.fontSizeSp &&
      backgroundOpacity == other.backgroundOpacity &&
      maxLines == other.maxLines &&
      textAlign == other.textAlign &&
      cornerRadiusPx == other.cornerRadiusPx &&
      textShadowArgb == other.textShadowArgb &&
      theme == other.theme &&
      showBilingual == other.showBilingual &&
      idleCollapseSeconds == other.idleCollapseSeconds &&
      maxWidthFraction == other.maxWidthFraction;

  @override
  int get hashCode => Object.hash(
    fontSizeSp,
    backgroundOpacity,
    maxLines,
    textAlign,
    cornerRadiusPx,
    textShadowArgb,
    theme,
    showBilingual,
    idleCollapseSeconds,
    maxWidthFraction,
  );
}

enum OverlayTextAlign {
  left('left'),
  center('center'),
  right('right');

  const OverlayTextAlign(this.wireName);
  final String wireName;
}

enum OverlayTheme {
  /// Emulated glassmorphism (default).
  glass('glass'),

  /// High-contrast solid backing — accessibility option (C-04).
  solid('solid');

  const OverlayTheme(this.wireName);
  final String wireName;
}

/// Governor preferences (`setGovernorPrefs`, contract §2.2; PRD B-07).
///
/// Unknown keys are ignored by native for forward compatibility; unknown
/// fields added later on the Dart side must keep wire names additive.
@immutable
class GovernorPrefs {
  const GovernorPrefs({
    this.screenOffAutoPause = false,
    this.batteryLowThresholdPct = 15,
    this.thermalHysteresisMs = 60000,
    this.inferenceQueueDepth = 3,
  }) : assert(batteryLowThresholdPct >= 0 && batteryLowThresholdPct <= 100),
       assert(thermalHysteresisMs >= 0),
       assert(inferenceQueueDepth >= 1 && inferenceQueueDepth <= 10);

  final bool screenOffAutoPause;
  final int batteryLowThresholdPct;
  final int thermalHysteresisMs;

  /// Bounded inference queue depth (architecture §3.2); default 3.
  final int inferenceQueueDepth;

  Map<Object?, Object?> toWire() => <Object?, Object?>{
    'screenOffAutoPause': screenOffAutoPause,
    'batteryLowThresholdPct': batteryLowThresholdPct,
    'thermalHysteresisMs': thermalHysteresisMs,
    'inferenceQueueDepth': inferenceQueueDepth,
  };

  @override
  bool operator ==(Object other) =>
      other is GovernorPrefs &&
      screenOffAutoPause == other.screenOffAutoPause &&
      batteryLowThresholdPct == other.batteryLowThresholdPct &&
      thermalHysteresisMs == other.thermalHysteresisMs &&
      inferenceQueueDepth == other.inferenceQueueDepth;

  @override
  int get hashCode => Object.hash(
    screenOffAutoPause,
    batteryLowThresholdPct,
    thermalHysteresisMs,
    inferenceQueueDepth,
  );
}

/// Thrown when a native reply violates its documented shape.
class _WireShapeException implements Exception {
  const _WireShapeException(this.message);
  final String message;

  @override
  String toString() => '_WireShapeException: $message';
}
