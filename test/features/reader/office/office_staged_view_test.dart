import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/office/widgets/office_staged_view.dart';
import 'package:folio/features/reader/widgets/reader_loading_view.dart';

import '../../../support/reader_stubs.dart';

/// Counts State initializations so the test can prove the surface is never
/// remounted across the staged reveal.
class _MountProbe extends StatefulWidget {
  const _MountProbe(this.created);

  final ValueNotifier<int> created;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.created.value += 1;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late OfficeRendererStub renderer;

  setUp(() {
    renderer = OfficeRendererStub(document: stubEntry('doc.docx'));
  });

  tearDown(() => renderer.dispose());

  testWidgets('the surface mounts before ready and survives the reveal', (
    tester,
  ) async {
    final creations = ValueNotifier<int>(0);
    addTearDown(creations.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OfficeStagedView(
          renderer: renderer,
          view: _MountProbe(creations),
        ),
      ),
    );
    await tester.pump();

    // Staged loading: the real surface is already mounted (warming under the
    // loader) while the loader overlay is still visible.
    expect(creations.value, 1);
    expect(find.byType(_MountProbe), findsOneWidget);
    expect(find.byType(ReaderLoadingView), findsOneWidget);

    // Ready: the loader crossfades out; the surface element must survive.
    renderer.loadState = ReaderLoadState.ready;
    renderer.notifyListeners();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(creations.value, 1);
    expect(find.byType(ReaderLoadingView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a renderer swapped mid-reveal resets the overlay', (tester) async {
    final first = OfficeRendererStub(document: stubEntry('doc.docx'));
    await first.open();
    addTearDown(first.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OfficeStagedView(
          renderer: first,
          view: const SizedBox.expand(),
        ),
      ),
    );
    // The ready event both flips the load state and cancels the open
    // watchdog, the way the real native flow does.
    first.handleViewEvent(<Object?, Object?>{
      'type': 'ready',
      'count': 4,
      'hasText': true,
    });
    await tester.pumpAndSettle();
    expect(find.byType(ReaderLoadingView), findsNothing);

    // A fresh renderer (reload path) brings the loader back.
    final second = OfficeRendererStub(document: stubEntry('doc.docx'));
    addTearDown(second.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OfficeStagedView(
          renderer: second,
          view: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ReaderLoadingView), findsOneWidget);
  });
}
