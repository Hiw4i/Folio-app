/// Liquid glass mini-library: one substance for every glass surface.
///
/// Layout of this folder:
/// - `core/` — shared math and physics foundation (no widgets except tokens):
///   motion driver, shape/geometry math, tokens.
/// - `motion/` — interaction controllers (search/morph driver, segmented
///   lens driver).
/// - `surface/` — painting: deformed shell, static case/panel, search frame.
/// - `widgets/` — ready controls plus the interaction primitives they share
///   ([GlassTouchShield], [GlassHitBlocker], [LiquidContent]) and the
///   universal [LiquidGlass] container.
///
/// Feature code should import only this barrel.
library;

export 'core/glass_geometry.dart';
export 'core/glass_tokens.dart';
export 'core/liquid_motion_controller.dart';
export 'core/liquid_shape.dart';
export 'motion/glass_motion_controller.dart';
export 'motion/liquid_segmented_controller.dart';
export 'surface/glass_panel.dart';
export 'surface/glass_shell.dart';
export 'surface/glass_surface.dart';
export 'surface/liquid_surface.dart';
export 'widgets/glass_touch_shield.dart';
export 'widgets/adaptive_glass_foreground.dart';
export 'widgets/adaptive_glass_effects.dart';
export 'widgets/liquid_container.dart';
export 'widgets/liquid_content.dart';
export 'widgets/liquid_glass_button.dart';
export 'widgets/liquid_glass_control.dart';
export 'widgets/liquid_glass_toggle.dart';
export 'widgets/liquid_morphing_control.dart';
export 'widgets/liquid_search_control.dart';
export 'widgets/liquid_search_morph.dart';
export 'widgets/liquid_segmented_control.dart';
