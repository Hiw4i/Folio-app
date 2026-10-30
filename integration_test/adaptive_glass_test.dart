import 'package:integration_test/integration_test.dart';

import '../test/shared/glass/adaptive_glass_gpu_test.dart' as gpu;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  gpu.main();
}
