import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/features/library/data/document_entry.dart';
import 'package:folio/features/reader/data/document_content_source.dart';
import 'package:folio/features/reader/logic/reader_state.dart';
import 'package:folio/features/reader/office/data/office_document_gateway.dart';
import 'package:folio/features/reader/word/logic/word_document_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pdfChannel = MethodChannel('folio/regression/pdf');
  const officeChannel = MethodChannel('folio/regression/office');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final document = DocumentEntry(
    id: 'office',
    source: const UriDocumentSource('content://test/document'),
    name: 'Guide.docx',
    format: DocumentFormat.docx,
    sizeBytes: 2048,
    modifiedAt: DateTime.utc(2026, 9, 18),
  );
  tearDown(() {
    messenger.setMockMethodCallHandler(pdfChannel, null);
    messenger.setMockMethodCallHandler(officeChannel, null);
  });

  test(
    'malformed PDF metadata releases the allocated native session',
    () async {
      var closes = 0;
      messenger.setMockMethodCallHandler(pdfChannel, (call) async {
        if (call.method == 'preparePdfSource') {
          return <String, Object?>{
            'kind': 'range',
            'sessionId': 'pdf-1',
            'length': -1,
          };
        }
        if (call.method == 'closePdfSource') closes++;
        return null;
      });
      final source = DeviceDocumentContentSource(methodChannel: pdfChannel);
      await expectLater(
        source.preparePdf(document.source),
        throwsA(isA<DocumentReadException>()),
      );
      expect(closes, 1);
    },
  );

  test('PDF range bounds and concurrent closes are safe', () async {
    var closes = 0;
    var reads = 0;
    messenger.setMockMethodCallHandler(pdfChannel, (call) async {
      switch (call.method) {
        case 'preparePdfSource':
          return <String, Object?>{
            'kind': 'range',
            'sessionId': 'pdf-1',
            'length': 10,
          };
        case 'readPdfRange':
          reads++;
          expect((call.arguments as Map)['size'], 2);
          return Uint8List.fromList(<int>[1, 2]);
        case 'closePdfSource':
          closes++;
      }
      return null;
    });
    final source = DeviceDocumentContentSource(methodChannel: pdfChannel);
    final prepared =
        await source.preparePdf(document.source) as PreparedPdfRandomAccess;
    expect(await prepared.readRange(8, 100), <int>[1, 2]);
    expect(await prepared.readRange(10, 100), isEmpty);
    expect(reads, 1);
    expect(() => prepared.readRange(-1, 2), throwsRangeError);
    await Future.wait(<Future<void>>[prepared.close(), prepared.close()]);
    expect(closes, 1);
    expect(
      () => prepared.readRange(0, 1),
      throwsA(isA<DocumentReadException>()),
    );
  });

  test(
    'mismatched Office format releases native session before rejecting',
    () async {
      var closes = 0;
      messenger.setMockMethodCallHandler(officeChannel, (call) async {
        if (call.method == 'prepareDocument') {
          return <String, Object?>{
            'sessionId': 'office-1',
            'format': 'pptx',
            'sizeBytes': 10,
          };
        }
        if (call.method == 'closeDocument') closes++;
        return null;
      });
      final gateway = DeviceOfficeDocumentGateway(methodChannel: officeChannel);
      await expectLater(
        gateway.prepare(document),
        throwsA(isA<OfficeDocumentException>()),
      );
      expect(closes, 1);
    },
  );

  test('Office session close is idempotent', () async {
    var closes = 0;
    messenger.setMockMethodCallHandler(officeChannel, (call) async {
      if (call.method == 'prepareDocument') {
        return <String, Object?>{
          'sessionId': 'office-1',
          'format': 'docx',
          'sizeBytes': 10,
        };
      }
      if (call.method == 'closeDocument') closes++;
      return null;
    });
    final gateway = DeviceOfficeDocumentGateway(methodChannel: officeChannel);
    final session = await gateway.prepare(document);
    await Future.wait(<Future<void>>[session.close(), session.close()]);
    expect(closes, 1);
  });

  test('failed cleanup does not prevent a replacement Office open', () async {
    final gateway = _Gateway()..failClose = true;
    final renderer = WordDocumentRenderer(document: document, gateway: gateway);
    addTearDown(renderer.dispose);
    await renderer.open();
    await renderer.open();
    expect(gateway.prepares, 2);
    expect(renderer.sourceReady, isTrue);
    expect(renderer.failure, isNull);
  });

  test('late Office preparation is released after renderer disposal', () async {
    final gateway = _Gateway()..gate = Completer<void>();
    final renderer = WordDocumentRenderer(document: document, gateway: gateway);
    final opening = renderer.open();
    renderer.dispose();
    gateway.gate!.complete();
    await opening;
    expect(gateway.closes, 1);
    expect(renderer.sourceReady, isFalse);
  });

  test(
    'Office search command failure does not leave a spinner or hide content',
    () async {
      final renderer = WordDocumentRenderer(
        document: document,
        gateway: _Gateway(),
      );
      addTearDown(renderer.dispose);
      await renderer.open();
      renderer.attachView(_FailingView(), renderer.session!.id);
      renderer.handleViewEvent(<Object?, Object?>{'type': 'ready', 'count': 2});
      await renderer.search('needle');
      expect(renderer.isSearching, isFalse);
      expect(renderer.loadState, ReaderLoadState.ready);
      expect(renderer.failure, isNull);
    },
  );
}

class _Gateway implements OfficeDocumentGateway {
  int prepares = 0;
  int closes = 0;
  bool failClose = false;
  Completer<void>? gate;

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async {
    final id = ++prepares;
    await gate?.future;
    return OfficeDocumentSession(
      id: '$id',
      format: document.format,
      sizeBytes: document.sizeBytes,
      close: () async {
        closes++;
        if (failClose) throw PlatformException(code: 'already_closed');
      },
    );
  }
}

class _FailingView implements OfficeViewCommands {
  @override
  Future<void> search(String query) async =>
      throw PlatformException(code: 'view_disposed');
  @override
  Future<void> showNextHit() async {}
  @override
  Future<void> showPreviousHit() async {}
  @override
  Future<void> goToPosition(int zeroBasedIndex) async {}
  @override
  Future<void> goToPositionInstant(int zeroBasedIndex) async {}
}
