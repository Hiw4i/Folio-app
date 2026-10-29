import 'package:flutter/widgets.dart';

import '../diagnostics/app_log.dart';
import 'folio_settings.dart';
import 'folio_settings_controller.dart';

/// Above the Navigator so pushed readers, menus and sheets share preferences.
/// Optional for isolated controls/tests: the original visual mode is default.
class FolioSettingsScope extends InheritedNotifier<FolioSettingsController> {
  const FolioSettingsScope({
    required FolioSettingsController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static FolioSettingsController? maybeControllerOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FolioSettingsScope>()
          ?.notifier;

  static FolioSettings settingsOf(BuildContext context) {
    final controller = maybeControllerOf(context);
    if (controller == null) {
      // The documented fallback for isolated controls and tests. Loud in
      // debug so a forgotten scope above a real screen is discoverable
      // instead of silently showing defaults.
      assert(() {
        AppLog.w(
          'FolioSettingsScope is missing above $context; '
          'settings-dependent widgets fall back to defaults.',
        );
        return true;
      }());
    }
    return controller?.settings ?? const FolioSettings();
  }

  static bool blurEnabledOf(BuildContext context) =>
      settingsOf(context).blurEnabled;

  static bool liquidMotionEnabledOf(BuildContext context) =>
      settingsOf(context).liquidMotionEnabled;
}
