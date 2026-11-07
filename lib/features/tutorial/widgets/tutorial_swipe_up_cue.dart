import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../shared/glass/widgets/adaptive_glass_foreground.dart';
import '../../../shared/theme/folio_theme.dart';

/// The decorative swipe cue over the slide deck.
class TutorialSwipeUpCue extends StatefulWidget {
  const TutorialSwipeUpCue({super.key});

  @override
  State<TutorialSwipeUpCue> createState() => _TutorialSwipeUpCueState();
}

class _TutorialSwipeUpCueState extends State<TutorialSwipeUpCue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = AppMotion.resolve(context, AppDurations.medium * 2);
    if (duration == Duration.zero) {
      _motion.stop();
      _motion.value = 0.5;
    } else if (!_motion.isAnimating) {
      _motion.repeat(period: duration);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: Center(
            child: AnimatedBuilder(
              animation: _motion,
              child: const Icon(
                LucideIcons.chevronUp,
                size: AppSpacing.xxxxl,
                color: Color(0xFFFFFFFF),
                shadows: kAdaptiveOutlineShadows,
              ),
              builder: (context, child) {
                final t = _motion.value;
                return Opacity(
                  opacity: math.sin(math.pi * t).clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(
                      0,
                      (0.5 - t) * (AppSpacing.xxxl + AppSpacing.xxl),
                    ),
                    child: child,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
