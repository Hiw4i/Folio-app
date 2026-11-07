import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart'
    show
        DefaultMaterialLocalizations,
        DefaultSelectionStyle,
        TextSelectionTheme,
        TextSelectionThemeData;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app/folio_root.dart';
import 'features/library/data/document_entry.dart';
import 'features/library/data/file_library_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/logic/library_controller.dart';
import 'features/reader/data/document_content_source.dart';
import 'features/tutorial/data/tutorial_progress_store.dart';
import 'features/tutorial/logic/tutorial_controller.dart';
import 'features/tutorial/widgets/tutorial_scope.dart';
import 'shared/android/android_storage_gateway.dart';
import 'shared/diagnostics/app_log.dart';
import 'shared/glass/widgets/adaptive_glass_foreground.dart';
import 'shared/selection/folio_selection_toolbar.dart';
import 'shared/settings/folio_settings_controller.dart';
import 'shared/settings/folio_settings_scope.dart';
import 'shared/settings/folio_settings_store.dart';
import 'shared/theme/folio_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Overlay icon brightness is theme-dependent and rides the widget tree via
  // an AnnotatedRegion in [FolioApp]; no static style is pinned here.
  runApp(const FolioApp());
}

/// Errors escaping a zone used to vanish in release builds: the app kept
/// running with whatever state the failing callback left behind, invisible to
/// both the user and any future crash reporting. Presenting framework errors
/// keeps dev tooling unchanged; platform errors are reported and surfaced to
/// the dispatcher.
void _installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.e('Uncaught framework error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.e('Uncaught platform error', error, stack);
    return false;
  };
}

class FolioApp extends StatefulWidget {
  const FolioApp({
    this.libraryRepository,
    this.documentContentSource,
    this.settingsStore,
    this.tutorialStore,
    super.key,
  });

  final LibraryRepository? libraryRepository;
  final DocumentContentSource? documentContentSource;
  final FolioSettingsStore? settingsStore;

  /// Injectable tutorial progress for tests: seed it with every tour as
  /// seen so the looping gesture cues never enter test pump loops.
  final TutorialProgressStore? tutorialStore;

  @override
  State<FolioApp> createState() => _FolioAppState();
}

class _FolioAppState extends State<FolioApp> {
  late final LibraryController _libraryController;
  late final FolioSettingsController _settingsController;
  late final TutorialController _tutorialController;
  late final DocumentContentSource _documentContentSource;
  bool _launchResolved = false;
  DocumentEntry? _initialExternalDocument;

  @override
  void initState() {
    super.initState();
    unawaited(precacheAdaptiveGlassForeground());
    _settingsController = FolioSettingsController(
      store: widget.settingsStore ?? FileFolioSettingsStore(),
    );
    unawaited(_settingsController.load());
    _tutorialController = TutorialController(
      store: widget.tutorialStore ?? FileTutorialProgressStore(),
    );
    unawaited(_tutorialController.load());
    _documentContentSource =
        widget.documentContentSource ?? const DeviceDocumentContentSource();
    _libraryController = LibraryController(
      repository:
          widget.libraryRepository ??
          FileLibraryRepository(storageGateway: AndroidStorageGateway()),
    );
    unawaited(_resolveLaunchDocument());
  }

  Future<void> _resolveLaunchDocument() async {
    try {
      await _libraryController.probeLaunchDocument();
    } catch (error, stack) {
      // A malformed launch intent must never block the library.
      AppLog.e('Folio launch probe failed', error, stack);
    }
    if (!mounted) {
      return;
    }
    final external = _libraryController.pendingDocumentIsExternal;
    final document = external ? _libraryController.takePendingDocument() : null;
    setState(() {
      _initialExternalDocument = document;
      _launchResolved = true;
    });
  }

  @override
  void dispose() {
    _libraryController.dispose();
    _settingsController.dispose();
    _tutorialController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FolioSettingsScope(
      controller: _settingsController,
      child: TutorialScope(
        controller: _tutorialController,
        child: WidgetsApp(
          color: darkAppColors.background,
          debugShowCheckedModeBanner: false,
          title: 'Folio',
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            DefaultMaterialLocalizations.delegate,
          ],
          supportedLocales: const <Locale>[Locale('en')],
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
            return PageRouteBuilder<T>(
              settings: settings,
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (context, primaryAnimation, secondaryAnimation) =>
                  builder(context),
            );
          },
          builder: (context, child) {
            return ListenableBuilder(
              listenable: _settingsController,
              child: child ?? const SizedBox.shrink(),
              builder: (context, child) {
                // Resolved here so a system-brightness change rebuilds the
                // palette through this context's MediaQuery dependency.
                final light = FolioSettingsScope.isLightThemeOf(context);
                return ThemeColors(
                  colors: appColorsFor(light: light),
                  glass: glassColorsFor(light: light),
                  // Reduced motion switches the palette with no transition.
                  duration: AppMotion.resolve(context, AppDurations.medium),
                  child: AnnotatedRegion<SystemUiOverlayStyle>(
                    value: SystemUiOverlayStyle(
                      statusBarColor: const Color(0x00000000),
                      statusBarIconBrightness: light
                          ? Brightness.dark
                          : Brightness.light,
                      systemNavigationBarColor: const Color(0x00000000),
                      systemNavigationBarIconBrightness: light
                          ? Brightness.dark
                          : Brightness.light,
                      systemNavigationBarDividerColor: const Color(0x00000000),
                    ),
                    child: TextSelectionTheme(
                      data: TextSelectionThemeData(
                        cursorColor: context.colors.cursor,
                        selectionColor: context.colors.selection,
                        selectionHandleColor: context.colors.selectionHandle,
                      ),
                      child: ScrollConfiguration(
                        behavior: const FolioScrollBehavior(),
                        child: DefaultSelectionStyle(
                          cursorColor: context.colors.cursor,
                          selectionColor: context.colors.selection,
                          child: DefaultTextStyle(
                            style: AppTextStyles.body(context),
                            child: FolioSelectionToolbarHost(child: child!),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
          home: _launchResolved
              ? FolioRoot(
                  controller: _libraryController,
                  documentContentSource: _documentContentSource,
                  initialExternalDocument: _initialExternalDocument,
                )
              : const _LaunchCover(),
        ),
      ),
    );
  }
}

class _LaunchCover extends StatelessWidget {
  const _LaunchCover();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey<String>('folio_launch_cover'),
      color: context.colors.background,
    );
  }
}

class FolioScrollBehavior extends ScrollBehavior {
  const FolioScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      decelerationRate: ScrollDecelerationRate.fast,
    );
  }
}
