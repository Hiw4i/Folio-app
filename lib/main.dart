import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter/material.dart'
    show
        DefaultMaterialLocalizations,
        DefaultSelectionStyle,
        TextSelectionTheme,
        TextSelectionThemeData;

import 'app/folio_root.dart';
import 'features/library/data/document_entry.dart';
import 'features/library/data/file_library_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/logic/library_controller.dart';
import 'features/reader/data/document_content_source.dart';
import 'shared/android/android_storage_gateway.dart';
import 'shared/glass/widgets/adaptive_glass_foreground.dart';
import 'shared/selection/folio_selection_toolbar.dart';
import 'shared/settings/folio_settings_controller.dart';
import 'shared/settings/folio_settings_scope.dart';
import 'shared/settings/folio_settings_store.dart';
import 'shared/theme/folio_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0x00000000),
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Color(0x00000000),
    ),
  );
  runApp(const FolioApp());
}

class FolioApp extends StatefulWidget {
  const FolioApp({
    this.libraryRepository,
    this.documentContentSource,
    this.settingsStore,
    super.key,
  });

  final LibraryRepository? libraryRepository;
  final DocumentContentSource? documentContentSource;
  final FolioSettingsStore? settingsStore;

  @override
  State<FolioApp> createState() => _FolioAppState();
}

class _FolioAppState extends State<FolioApp> {
  late final LibraryController _libraryController;
  late final FolioSettingsController _settingsController;
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
    } catch (error) {
      // A malformed launch intent must never block the library.
      debugPrint('Folio launch probe failed: $error');
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FolioSettingsScope(
      controller: _settingsController,
      child: WidgetsApp(
        color: appColors.background,
        debugShowCheckedModeBanner: false,
        title: 'Folio',
        textStyle: AppTextStyles.body(context),
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
          return TextSelectionTheme(
            data: TextSelectionThemeData(
              cursorColor: appColors.cursor,
              selectionColor: appColors.selection,
              selectionHandleColor: appColors.selectionHandle,
            ),
            child: ScrollConfiguration(
              behavior: const FolioScrollBehavior(),
              child: DefaultSelectionStyle(
                cursorColor: appColors.cursor,
                selectionColor: appColors.selection,
                child: DefaultTextStyle(
                  style: AppTextStyles.body(context),
                  child: FolioSelectionToolbarHost(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
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
    );
  }
}

class _LaunchCover extends StatelessWidget {
  const _LaunchCover();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey<String>('folio_launch_cover'),
      color: appColors.background,
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
