import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../shared/glass/liquid_glass.dart';
import '../../../shared/theme/folio_theme.dart';
import '../../../shared/widgets/folio_status_view.dart';
import '../logic/reader_state.dart';

/// Full-bleed status with optional retry action (load failures, empty
/// documents), padded clear of every chrome overlay.
class ReaderStatusView extends StatelessWidget {
  const ReaderStatusView({
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xxxxl,
          AppSpacing.xxxxxl + AppSpacing.xl,
          AppSpacing.xxxxl,
          AppSpacing.xxxxxl + AppSpacing.xl + AppSpacing.lg,
        ),
        child: FolioStatusView(title: title, message: message, action: action),
      ),
    );
  }
}

/// Load-failure surface with the reader's retry affordance.
class ReaderFailureView extends StatelessWidget {
  const ReaderFailureView({required this.failure, required this.onRetry, super.key});

  final ReaderFailure failure;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ReaderStatusView(
      title: failure.title,
      message: failure.message,
      action: failure.canRetry
          ? LiquidGlassButton(
              label: 'Try again',
              width: 132,
              height: 50,
              onTap: () => unawaited(onRetry()),
            )
          : null,
    );
  }
}

/// Vertical document gradient behind the reader content.
class ReaderBackground extends StatelessWidget {
  const ReaderBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            const Color(0xFF121315),
            appColors.background,
            const Color(0xFF08090A),
          ],
          stops: <double>[0, 0.34, 1],
        ),
      ),
    );
  }
}

/// Reading progress pill for the PDF/Office position label or the text
/// scroll percentage.
class ReaderProgressPill extends StatelessWidget {
  const ReaderProgressPill({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassControl(
      size: const Size(62, 38),
      child: Center(
        child: AdaptiveGlassText(label, style: AppTextStyles.smallDim(context)),
      ),
    );
  }
}
