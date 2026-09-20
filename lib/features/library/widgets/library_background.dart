import 'package:flutter/widgets.dart';

import '../../../shared/theme/folio_theme.dart';

class LibraryBackground extends StatelessWidget {
  const LibraryBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: appColors.background,
          gradient: RadialGradient(
            center: Alignment(0.75, -0.65),
            radius: 1.05,
            colors: <Color>[
              const Color(0xFF292824),
              const Color(0xFF131416),
              appColors.background,
            ],
            stops: const <double>[0, 0.42, 1],
          ),
        ),
        child: const SizedBox.shrink(),
      ),
    );
  }
}
