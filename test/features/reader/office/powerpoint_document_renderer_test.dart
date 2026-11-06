import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/powerpoint/logic/powerpoint_document_renderer.dart';

import '../../../support/reader_stubs.dart';

void main() {
  test('overview events mirror the panel state with change-only notifications',
      () async {
    final renderer = PowerPointDocumentRenderer(
      document: stubEntry('deck.pptx'),
      gateway: const PreparedSessionGateway(),
    );
    addTearDown(renderer.dispose);
    await renderer.open();

    var notifications = 0;
    renderer.addListener(() => notifications++);

    renderer.handleViewEvent(<Object?, Object?>{'type': 'overview', 'open': true});
    expect(renderer.slideOverviewOpen, isTrue);
    expect(notifications, 1);

    // A repeated event (double delivery, refresh) must not renotify: the
    // shell's chrome sync and rebuilds ride these notifications.
    renderer.handleViewEvent(<Object?, Object?>{'type': 'overview', 'open': true});
    expect(notifications, 1);

    renderer.handleViewEvent(<Object?, Object?>{'type': 'overview', 'open': false});
    expect(renderer.slideOverviewOpen, isFalse);
    expect(notifications, 2);
  });

  test('ready and error handshakes clear a stale overview flag', () async {
    final renderer = PowerPointDocumentRenderer(
      document: stubEntry('deck.pptx'),
      gateway: const PreparedSessionGateway(),
    );
    addTearDown(renderer.dispose);
    await renderer.open();

    // A fresh page boot can never have the overview open.
    renderer.handleViewEvent(<Object?, Object?>{'type': 'overview', 'open': true});
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready', 'count': 3, 'hasText': true,
    });
    expect(renderer.slideOverviewOpen, isFalse);

    // A renderer failure tears down the surface the panel lived on.
    renderer.handleViewEvent(<Object?, Object?>{'type': 'overview', 'open': true});
    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'error', 'message': 'renderer crashed',
    });
    expect(renderer.slideOverviewOpen, isFalse);
    expect(renderer.loadState, ReaderLoadState.failed);
  });

  test('closeOverview reaches the view only once it is ready', () async {
    final renderer = PowerPointDocumentRenderer(
      document: stubEntry('deck.pptx'),
      gateway: const PreparedSessionGateway(),
    );
    addTearDown(renderer.dispose);
    await renderer.open();
    final view = RecordingOfficeView();
    renderer.attachView(view, renderer.session!.id);

    renderer.closeOverview();
    await Future<void>.delayed(Duration.zero);
    expect(view.calls, isEmpty);

    renderer.handleViewEvent(<Object?, Object?>{
      'type': 'ready', 'count': 3, 'hasText': true,
    });
    renderer.closeOverview();
    await Future<void>.delayed(Duration.zero);
    expect(view.calls, contains('closeOverview'));
  });
}
