import 'package:flutter_test/flutter_test.dart';
import 'package:folio/app/touch_resampling.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  for (final (mode, offset) in <(String, int?)>[
    ('off', null),
    ('-16', -16),
    ('-8', -8),
    ('invalid', null),
  ]) {
    test('touch resampling mode $mode configures the gesture binding', () {
      final previousEnabled = binding.resamplingEnabled;
      final previousOffset = binding.samplingOffset;
      addTearDown(() {
        binding.resamplingEnabled = previousEnabled;
        binding.samplingOffset = previousOffset;
      });

      binding.resamplingEnabled = offset == null;
      configureTouchResampling(binding, mode: mode);

      expect(binding.resamplingEnabled, offset != null);
      if (offset != null) {
        expect(binding.samplingOffset, Duration(milliseconds: offset));
      }
    });
  }
}
