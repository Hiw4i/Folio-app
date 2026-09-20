import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import 'package:lucide_flutter/lucide_flutter.dart';

import '../../selection/folio_selection_toolbar.dart';
import '../../theme/folio_theme.dart';
import '../core/glass_geometry.dart';
import '../core/liquid_shape.dart';
import '../motion/glass_motion_controller.dart';
import '../surface/glass_surface.dart';
import '../surface/liquid_surface.dart';
import 'adaptive_glass_foreground.dart';
import 'glass_touch_shield.dart';
import 'liquid_content.dart';

class LiquidSearchMorph extends StatelessWidget {
  const LiquidSearchMorph({
    required this.frame,
    required this.motion,
    required this.searchController,
    required this.editableKey,
    required this.searchFocus,
    required this.mainFocus,
    required this.cancelFocus,
    required this.reducedMotion,
    required this.hintText,
    required this.semanticsLabel,
    required this.onTapInput,
    this.onSubmitted,
    super.key,
  });

  final GlassGeometryFrame frame;
  final GlassMotionController motion;
  final TextEditingController searchController;
  final GlobalKey<EditableTextState> editableKey;
  final FocusNode searchFocus;
  final FocusNode mainFocus;
  final FocusNode cancelFocus;
  final bool reducedMotion;
  final String hintText;
  final String semanticsLabel;
  final VoidCallback onTapInput;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final contentOpacity = ((frame.morph - 0.52) / 0.30).clamp(0.0, 1.0);
    final cancelOpacity = ((frame.separation - 0.45) / 0.42).clamp(0.0, 1.0);
    final transitionOpacity = LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;
    final selfBlur = LiquidContent.blurSigma(
      morphVelocity: motion.morphVelocity,
      separationVelocity: motion.separationVelocity,
      reducedMotion: reducedMotion,
    );
    final mainContentOffset = LiquidContent.offset(
      displacement: frame.mainDeformation,
      velocity: frame.deformationVelocity,
      press: frame.deformCancel ? 0 : frame.press,
    );
    final cancelContentOffset = LiquidContent.offset(
      displacement: frame.cancelDeformation,
      velocity: frame.deformationVelocity,
      press: frame.deformCancel ? frame.press : 0,
    );

    Widget soften(Widget child) => AdaptiveGlassEffects(
      blurSigma: FolioSettingsScope.blurEnabledOf(context) ? selfBlur : 0,
      child: child,
    );

    return AdaptiveGlassForegroundGroup(
      samplePoint: adaptiveGlassSamplePoint(frame.mainRect),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          LiquidGlassSurface(
            frame: frame,
            motion: motion,
            focused:
                searchFocus.hasFocus ||
                cancelFocus.hasFocus ||
                mainFocus.hasFocus,
          ),
          Positioned.fromRect(
            rect: frame.mainRect.inflate(8),
            child: const GlassTouchShield(),
          ),
          if (frame.cancelVisible)
            Positioned.fromRect(
              rect: frame.cancelRect.inflate(6),
              child: const GlassTouchShield(),
            ),
          Positioned(
            // [iconCenter] already contains the content follow offset. Keep
            // the render layer at its stable layout position and apply that
            // offset as a transform so the shader mask travels with the icon.
            left: frame.iconCenter.dx - mainContentOffset.dx - 10,
            top: frame.iconCenter.dy - mainContentOffset.dy - 10,
            width: 20,
            height: 20,
            child: IgnorePointer(
              child: soften(
                Transform.translate(
                  offset: mainContentOffset,
                  child: Transform.scale(
                    scale: LiquidShape.contentScale(
                      frame.deformCancel ? 0 : frame.press,
                    ),
                    child: AdaptiveGlassEffects(
                      opacity:
                          (0.88 + motion.submitEnergy * 0.12) *
                          transitionOpacity,
                      child: const AdaptiveGlassIcon(
                        LucideIcons.search,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: Rect.fromLTRB(
              frame.mainRect.left + 48,
              frame.mainRect.center.dy - 15,
              frame.mainRect.right - 16,
              frame.mainRect.center.dy + 15,
            ),
            child: IgnorePointer(
              ignoring: frame.morph < 0.76 || !motion.wantsOpen,
              child: MouseRegion(
                cursor: SystemMouseCursors.text,
                opaque: false,
                child: ExcludeSemantics(
                  excluding: frame.morph < 0.76 || !motion.wantsOpen,
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (_) => onTapInput(),
                    child: soften(
                      AdaptiveGlassEffects(
                        opacity: contentOpacity * transitionOpacity,
                        child: Transform.translate(
                          offset: mainContentOffset,
                          child: Stack(
                            alignment: Alignment.centerLeft,
                            children: <Widget>[
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: searchController,
                                builder: (context, value, child) {
                                  return Offstage(
                                    offstage: value.text.isNotEmpty,
                                    child: AdaptiveGlassText(
                                      hintText,
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                      style: const TextStyle(
                                        fontFamily: 'Inter',
                                        color: Color(0xFFFFFFFF),
                                        fontSize: 16,
                                        letterSpacing: 0.1,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              // Typed query mirrored through the same GPU
                              // black/white pipeline as the hint (shared sample
                              // point, same luminance band). A static mask cannot
                              // follow the caret/selection scroll, but queries
                              // are short and the hint already fades the same
                              // way — far more readable on light backdrops than
                              // the former fixed-white glyphs.
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: searchController,
                                builder: (context, value, child) {
                                  if (value.text.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return ExcludeSemantics(
                                    child: IgnorePointer(
                                      child: AdaptiveGlassText(
                                        value.text,
                                        maxLines: 1,
                                        overflow: TextOverflow.fade,
                                        softWrap: false,
                                        style: const TextStyle(
                                          fontFamily: 'Inter',
                                          color: Color(0xFFFFFFFF),
                                          fontSize: 16,
                                          height: 1.2,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              AdaptiveGlassDecoration(
                                child: Semantics(
                                  key: const ValueKey<String>(
                                    'search_editable',
                                  ),
                                  label: semanticsLabel,
                                  textField: true,
                                  child: EditableText(
                                    key: editableKey,
                                    controller: searchController,
                                    focusNode: searchFocus,
                                    contextMenuBuilder:
                                        folioEditableTextContextMenuBuilder,
                                    // Glyphs are transparent: the visible text is
                                    // the adaptive mirror above (same metrics, so
                                    // caret/selection stay aligned). No shadows —
                                    // even a transparent glyph would cast them.
style: const TextStyle(
                                       fontFamily: 'Inter',
                                       color: Color(0x00FFFFFF),
                                       fontSize: 16,
                                       height: 1.2,
                                     ),
                                     cursorColor: appColors.cursor,
                                     backgroundCursorColor:
                                         appColors.cursorBackground,
                                     selectionColor: appColors.selection,
                                    maxLines: 1,
                                    keyboardType: TextInputType.text,
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: (value) {
                                      motion.submit();
                                      onSubmitted?.call(value);
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (frame.cancelVisible)
            Positioned.fromRect(
              rect: frame.cancelRect,
              child: AdaptiveGlassForegroundGroup(
                samplePoint: adaptiveGlassSamplePoint(
                  Offset.zero & frame.cancelRect.size,
                ),
                child: IgnorePointer(
                  child: soften(
                    AdaptiveGlassEffects(
                      opacity: cancelOpacity * transitionOpacity,
                      child: Transform.translate(
                        offset: cancelContentOffset,
                        child: Transform.scale(
                          scale: LiquidShape.contentScale(
                            frame.deformCancel ? frame.press : 0,
                          ),
                          child: const Center(
                            child: AdaptiveGlassText(
                              'Cancel',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: Color(0xFFFFFFFF),
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (frame.morph < 0.68)
            Positioned.fromRect(
              rect: frame.mainRect.inflate(8),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                opaque: false,
                child: Semantics(
                  button: true,
                  label: semanticsLabel,
                  onTap: () {
                    mainFocus.requestFocus();
                    motion.requestOpen();
                  },
                  child: Focus(
                    key: const ValueKey<String>('search_button_hit'),
                    focusNode: mainFocus,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          (event.logicalKey == LogicalKeyboardKey.enter ||
                              event.logicalKey == LogicalKeyboardKey.space)) {
                        motion.requestOpen();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          if (frame.cancelInteractive)
            Positioned.fromRect(
              rect: frame.cancelRect.inflate(6),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                opaque: false,
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  button: true,
                  label: 'Cancel',
                  onTap: motion.requestClose,
                  child: Focus(
                    key: const ValueKey<String>('cancel_button_hit'),
                    focusNode: cancelFocus,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          (event.logicalKey == LogicalKeyboardKey.enter ||
                              event.logicalKey == LogicalKeyboardKey.space)) {
                        motion.requestClose();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
