import 'package:flutter/widgets.dart';

import '../logic/tutorial_controller.dart';
import '../tutorial_catalog.dart';

/// Above the Navigator so readers share tutorial progress.
class TutorialScope extends InheritedNotifier<TutorialController> {
  const TutorialScope({
    required TutorialController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static bool shouldShow(BuildContext context, TutorialTour tour) =>
      context
          .dependOnInheritedWidgetOfExactType<TutorialScope>()
          ?.notifier
          ?.shouldShow(tour) ??
      false;

  static void complete(BuildContext context, TutorialTour tour) => context
      .getInheritedWidgetOfExactType<TutorialScope>()
      ?.notifier
      ?.complete(tour);
}
