import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/office_document_gateway.dart';
import '../logic/office_document_renderer_base.dart';
import 'office_selection_overlay.dart';
import 'office_selection_magnifier.dart';

class OfficeDocumentPlatformView extends StatefulWidget {
  const OfficeDocumentPlatformView({
    required this.renderer,
    required this.onContentTap,
    this.onReadingGesture,
    super.key,
  });

  final OfficeDocumentRendererBase renderer;
  final VoidCallback onContentTap;
  final ValueChanged<double>? onReadingGesture;

  @override
  State<OfficeDocumentPlatformView> createState() =>
      _OfficeDocumentPlatformViewState();
}

class _OfficeDocumentPlatformViewState extends State<OfficeDocumentPlatformView>
    with WidgetsBindingObserver {
  _MethodChannelOfficeView? _controller;
  OfficeDocumentRendererBase? _attachedRenderer;
  String? _attachedSessionId;
  OfficeSelectionSnapshot _selection = OfficeSelectionSnapshot.empty;
  bool _selectionCommandRunning = false;
  final ValueNotifier<Offset?> _magnifierSource = ValueNotifier(null);
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) _magnifierSource.value = null;
  }

  @override
  void didUpdateWidget(OfficeDocumentPlatformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      _detach();
    }
  }

  void _platformViewCreated(
    int viewId,
    OfficeDocumentRendererBase renderer,
    String sessionId,
  ) {
    // Android view creation can finish after a route/session was replaced.
    if (!mounted ||
        !identical(renderer, widget.renderer) ||
        renderer.session?.id != sessionId) {
      return;
    }
    _detach();
    late final _MethodChannelOfficeView controller;
    controller = _MethodChannelOfficeView(
      viewId: viewId,
      onEvent: (event) => _handleEvent(controller, event),
    );
    _controller = controller;
    _attachedRenderer = renderer;
    _attachedSessionId = sessionId;
    renderer.attachView(controller, sessionId);
    unawaited(
      controller.start().catchError((Object error) {
        _handleEvent(controller, <Object?, Object?>{
          'type': 'error',
          'message': 'The Android Office view could not be started.',
          'recoverable': true,
        });
      }),
    );
  }

  void _handleEvent(
    _MethodChannelOfficeView controller,
    Map<Object?, Object?> event,
  ) {
    final renderer = _attachedRenderer;
    if (!mounted ||
        !identical(controller, _controller) ||
        renderer == null ||
        !identical(renderer, widget.renderer) ||
        renderer.session?.id != _attachedSessionId) {
      return;
    }
    renderer.handleViewEvent(event);
    switch (event['type']) {
      case 'selectionHandle':
        _magnifierSource.value = _appActive && _selection.active
            ? officeSelectionMagnifierSource(event)
            : null;
      case 'error':
        _magnifierSource.value = null;
      case 'selection':
        final next = OfficeSelectionSnapshot.fromEvent(event);
        if (!next.active) _magnifierSource.value = null;
        if (next != _selection) {
          setState(() => _selection = next);
        }
      case 'tap':
        if (!_selection.active) {
          widget.onContentTap();
        }
      case 'scroll':
        final rawDelta = event['delta'];
        if (!_selection.active &&
            rawDelta is num &&
            rawDelta.isFinite &&
            rawDelta != 0) {
          widget.onReadingGesture?.call(rawDelta.toDouble());
        }
    }
  }

  Future<void> _selectionCommand(String command) async {
    final controller = _controller;
    if (controller == null || _selectionCommandRunning) return;
    _selectionCommandRunning = true;
    try {
      await controller.selectionCommand(command);
    } catch (error) {
      // Preserve the selection on clipboard/channel failure, so Copy can retry.
      debugPrint('Folio Office selection command failed: $error');
    } finally {
      if (identical(controller, _controller)) _selectionCommandRunning = false;
    }
  }

  void _detach() {
    final controller = _controller;
    final renderer = _attachedRenderer;
    _controller = null;
    _attachedRenderer = null;
    _attachedSessionId = null;
    _selection = OfficeSelectionSnapshot.empty;
    _selectionCommandRunning = false;
    _magnifierSource.value = null;
    if (controller != null) {
      // Detach from its actual owner, not the newly supplied widget.renderer.
      renderer?.detachView(controller);
      controller.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach();
    _magnifierSource.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = widget.renderer;
    final session = renderer.session;
    if (!Platform.isAndroid || session == null) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      key: ValueKey<String>('office_document_view_${session.id}'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Office content must participate in Flutter's texture composition:
          // glass blur and adaptive foregrounds need the actual document pixels.
          // Forced HC creates separate cropped overlay surfaces above WebView.
          PlatformViewLink(
            viewType: 'folio/office_view',
            surfaceFactory: (context, controller) => AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers:
                  const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            ),
            onCreatePlatformView: (params) =>
                PlatformViewsService.initSurfaceAndroidView(
                    id: params.id,
                    viewType: 'folio/office_view',
                    layoutDirection: TextDirection.ltr,
                    creationParams: <String, Object?>{'sessionId': session.id},
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  )
                  ..addOnPlatformViewCreatedListener(
                    params.onPlatformViewCreated,
                  )
                  ..addOnPlatformViewCreatedListener(
                    (viewId) =>
                        _platformViewCreated(viewId, renderer, session.id),
                  )
                  ..create(),
          ),
          if (_selection.active && _selection.showMenu)
            OfficeSelectionOverlay(
              selection: _selection,
              onCopy: () => unawaited(_selectionCommand('copySelection')),
              onSelectAll: () => unawaited(_selectionCommand('selectAll')),
            ),
          // Only the loupe rebuilds as its source moves. Native scrolling and
          // DOM handle updates retain the WebView and its platform controller.
          ValueListenableBuilder<Offset?>(
            valueListenable: _magnifierSource,
            builder: (context, source, _) => source == null
                ? const SizedBox.shrink()
                : OfficeSelectionMagnifier(normalizedSource: source),
          ),
        ],
      ),
    );
  }
}

class _MethodChannelOfficeView implements OfficeViewCommands {
  _MethodChannelOfficeView({required int viewId, required this.onEvent})
    : _channel = MethodChannel('folio/office_view/$viewId') {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  final ValueChanged<Map<Object?, Object?>> onEvent;
  bool _disposed = false;

  Future<void> start() => _invoke('start');

  Future<void> selectionCommand(String command) => _invoke(command);

  @override
  Future<void> search(String query) =>
      _invoke('search', <String, Object?>{'query': query});

  @override
  Future<void> showNextHit() => _invoke('nextHit');

  @override
  Future<void> showPreviousHit() => _invoke('previousHit');

  @override
  Future<void> goToPosition(int zeroBasedIndex) =>
      _invoke('goToPosition', <String, Object?>{'index': zeroBasedIndex});

  @override
  Future<void> goToPositionInstant(int zeroBasedIndex) => _invoke(
    'goToPositionInstant',
    <String, Object?>{'index': zeroBasedIndex},
  );

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    if (_disposed) {
      return;
    }
    await _channel.invokeMethod<void>(method, arguments);
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (!_disposed && call.method == 'event' && call.arguments is Map) {
      onEvent((call.arguments as Map).cast<Object?, Object?>());
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
