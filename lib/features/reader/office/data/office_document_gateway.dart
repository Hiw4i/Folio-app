import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../library/data/document_entry.dart';

enum OfficeDocumentFailureKind {
  unavailable,
  denied,
  invalidArchive,
  unsafeArchive,
  unreadable,
}

class OfficeDocumentException implements Exception {
  const OfficeDocumentException(this.kind, this.message);

  final OfficeDocumentFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

class OfficeDocumentSession {
  const OfficeDocumentSession({
    required this.id,
    required this.format,
    required this.sizeBytes,
    required this.close,
  });

  final String id;
  final DocumentFormat format;
  final int sizeBytes;
  final Future<void> Function() close;
}

abstract interface class OfficeDocumentGateway {
  Future<OfficeDocumentSession> prepare(DocumentEntry document);
}

class DeviceOfficeDocumentGateway implements OfficeDocumentGateway {
  const DeviceOfficeDocumentGateway({MethodChannel? methodChannel})
    : _methodChannel = methodChannel ?? const MethodChannel('folio/office');

  final MethodChannel _methodChannel;

  @override
  Future<OfficeDocumentSession> prepare(DocumentEntry document) async {
    if (document.format != DocumentFormat.docx &&
        document.format != DocumentFormat.pptx) {
      throw const OfficeDocumentException(
        OfficeDocumentFailureKind.invalidArchive,
        'This is not a supported Office document.',
      );
    }
    try {
      final sourceType = document.source is FileDocumentSource ? 'file' : 'uri';
      final response = await _methodChannel.invokeMapMethod<String, Object?>(
        'prepareDocument',
        <String, Object?>{
          'sourceType': sourceType,
          'source': document.source.value,
          'format': document.format.extension,
          'sizeBytes': document.sizeBytes,
        },
      );
      final rawSessionId = response?['sessionId'];
      final sessionId = rawSessionId is String && rawSessionId.isNotEmpty
          ? rawSessionId
          : null;
      Future<void>? closing;
      Future<void> closeSession() {
        if (sessionId == null) {
          return Future<void>.value();
        }
        return closing ??= _methodChannel.invokeMethod<void>(
          'closeDocument',
          <String, Object?>{'sessionId': sessionId},
        );
      }

      try {
        final format = switch (response?['format']) {
          'docx' => DocumentFormat.docx,
          'pptx' => DocumentFormat.pptx,
          _ => null,
        };
        final rawSize = response?['sizeBytes'];
        final sizeBytes = rawSize is num && rawSize.isFinite
            ? rawSize.toInt()
            : null;
        if (sessionId == null ||
            format != document.format ||
            sizeBytes == null ||
            sizeBytes < 0) {
          throw const OfficeDocumentException(
            OfficeDocumentFailureKind.unreadable,
            'Android returned an invalid Office rendering session.',
          );
        }
        return OfficeDocumentSession(
          id: sessionId,
          format: document.format,
          sizeBytes: sizeBytes,
          close: closeSession,
        );
      } catch (_) {
        try {
          await closeSession();
        } catch (error) {
          debugPrint('Folio invalid Office session cleanup failed: $error');
        }
        rethrow;
      }
    } on PlatformException catch (error) {
      final kind = switch (error.code) {
        'access_denied' => OfficeDocumentFailureKind.denied,
        'not_found' => OfficeDocumentFailureKind.unavailable,
        'invalid_archive' => OfficeDocumentFailureKind.invalidArchive,
        'unsafe_archive' ||
        'archive_too_large' => OfficeDocumentFailureKind.unsafeArchive,
        _ => OfficeDocumentFailureKind.unreadable,
      };
      throw OfficeDocumentException(
        kind,
        error.message ?? 'The Office document could not be prepared.',
      );
    }
  }
}

abstract interface class OfficeViewCommands {
  Future<void> search(String query);
  Future<void> showNextHit();
  Future<void> showPreviousHit();
  Future<void> goToPosition(int zeroBasedIndex);

  /// Instant (non-animated) jump used by the scrubber: unlike
  /// [goToPosition], it never runs the smooth `scrollIntoView` animation,
  /// so dragging the scrub thumb jumps as fast as in other formats.
  Future<void> goToPositionInstant(int zeroBasedIndex);
}
