# Keep the vendored sherpa-onnx JNI surface intact.
#
# The Kotlin config data classes (OfflineRecognizerConfig, VadModelConfig,
# SileroVadModelConfig, FeatureConfig, ...) and their field NAMES are read
# reflectively from libsherpa-onnx-jni.so via JNI GetFieldID. R8 otherwise
# renames them (observed: OfflineModelConfig -> B.k with fields a,b,c...),
# which makes every model load fail with
# "RuntimeException: Failed to get field ID for decodingMethod" and can
# crash the process inside the VAD constructor (null field ID deref).
# Native methods are already preserved by the default AGP rules; this rule
# additionally preserves the config classes/fields and the result classes
# the JNI layer constructs by name (SpeechSegment, OfflineRecognizerResult).
-keep class com.k2fsa.sherpa.onnx.** { *; }