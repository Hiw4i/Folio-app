import 'package:flutter/gestures.dart';

/// Selects the Flutter touch sampling mode once, before the app handles input.
void configureTouchResampling(
  GestureBinding binding, {
  String mode = const String.fromEnvironment(
    'FOLIO_TOUCH_RESAMPLING',
    defaultValue: 'off',
  ),
}) {
  final offset = switch (mode) {
    '-16' => const Duration(milliseconds: -16),
    '-8' => const Duration(milliseconds: -8),
    _ => null,
  };
  if (offset != null) {
    binding.samplingOffset = offset;
  }
  binding.resamplingEnabled = offset != null;
}
