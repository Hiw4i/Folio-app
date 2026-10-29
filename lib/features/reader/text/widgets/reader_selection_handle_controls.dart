import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps platform handle geometry while letting the reader own handle drags.
///
/// Flutter's outer handle recognizer emits a haptic for every endpoint movement,
/// including changes caused by scrolling. Winning its gesture arena here keeps
/// feedback under the reader's character/line policy instead.
class ReaderSelectionHandleControls extends TextSelectionControls
    with TextSelectionHandleControls {
  ReaderSelectionHandleControls({
    required this.delegate,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.canStartDrag,
  });

  final TextSelectionControls delegate;
  final void Function(
    TextSelectionHandleType type,
    double lineHeight,
    Offset globalPosition,
  )
  onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final bool Function()? canStartDrag;

  @override
  Size getHandleSize(double textLineHeight) =>
      delegate.getHandleSize(textLineHeight);

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) =>
      delegate.getHandleAnchor(type, textLineHeight);

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) => _ReaderSelectionHandle(
    type: type,
    lineHeight: textLineHeight,
    onDragStart: onDragStart,
    onDragUpdate: onDragUpdate,
    onDragEnd: onDragEnd,
    canStartDrag: canStartDrag,
    child: delegate.buildHandle(context, type, textLineHeight, onTap),
  );
}

class _ReaderSelectionHandle extends StatefulWidget {
  const _ReaderSelectionHandle({
    required this.type,
    required this.lineHeight,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.canStartDrag,
    required this.child,
  });

  final TextSelectionHandleType type;
  final double lineHeight;
  final void Function(TextSelectionHandleType, double, Offset) onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final bool Function()? canStartDrag;
  final Widget child;

  @override
  State<_ReaderSelectionHandle> createState() => _ReaderSelectionHandleState();
}

class _ReaderSelectionHandleState extends State<_ReaderSelectionHandle> {
  late final PanGestureRecognizer _pan;
  final _additionalPointer = EagerGestureRecognizer();
  int? _pointer;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _pan =
        PanGestureRecognizer(
            debugOwner: this,
            supportedDevices: <PointerDeviceKind>{
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.unknown,
            },
          )
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = (details) {
            if (!(widget.canStartDrag?.call() ?? true)) return;
            _dragging = true;
            widget.onDragStart(
              widget.type,
              widget.lineHeight,
              details.globalPosition,
            );
          }
          ..onUpdate = (details) {
            if (_dragging) widget.onDragUpdate(details.globalPosition);
          }
          ..onEnd = (_) {
            _finishDrag();
          }
          ..onCancel = _finishDrag;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pan.gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
  }

  void _finishDrag() {
    _pointer = null;
    if (!_dragging) return;
    _dragging = false;
    widget.onDragEnd();
  }

  @override
  void dispose() {
    _pan.dispose();
    _additionalPointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _HandleHitTarget(
    key: const ValueKey<String>('reader_selection_handle'),
    onPointerDown: (event) {
      if (_pointer != null) {
        // Consume extra touches so neither this pan nor Flutter's surrounding
        // native handle recognizer can transfer ownership to another finger.
        _additionalPointer.addPointer(event);
        return;
      }
      _pointer = event.pointer;
      _pan.addPointer(event);
    },
    child: widget.child,
  );
}

class _HandleHitTarget extends SingleChildRenderObjectWidget {
  const _HandleHitTarget({
    required this.onPointerDown,
    required super.child,
    super.key,
  });

  final PointerDownEventListener onPointerDown;

  @override
  _RenderHandleHitTarget createRenderObject(BuildContext context) =>
      _RenderHandleHitTarget(onPointerDown);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHandleHitTarget renderObject,
  ) {
    renderObject.onPointerDown = onPointerDown;
  }
}

class _RenderHandleHitTarget extends RenderProxyBox {
  _RenderHandleHitTarget(this.onPointerDown);

  PointerDownEventListener onPointerDown;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // The framework pads its handle to this same touch target. Include that
    // padding in our hit test without changing the platform handle's layout.
    final bounds = (Offset.zero & size).expandToInclude(
      Rect.fromCircle(center: size.center(Offset.zero), radius: 24),
    );
    if (!bounds.contains(position)) return false;
    hitTestChildren(result, position: position);
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent) onPointerDown(event);
  }
}
