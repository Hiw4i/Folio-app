import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/shared/glass/adaptive_glass_gpu_test.dart' as gpu;
import 'office_glass_test.dart' as office;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Flutter backdrop', gpu.main);
  group('Real Office WebView', office.main);
}
