import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter/material.dart'
    show
        DefaultMaterialLocalizations,
        DefaultSelectionStyle,
        TextSelectionTheme,
        TextSelectionThemeData;

import 'features/library/data/file_library_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/logic/library_controller.dart';
import 'features/library/widgets/library_screen.dart';
import 'features/reader/data/document_content_source.dart';
import 'shared/android/android_storage_gateway.dart';
import 'shared/glass/widgets/adaptive_glass_foreground.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(precacheAdaptiveGlassForeground());
    _settingsController = FolioSettingsController(
      store: widget.settingsStore ?? FileFolioSettingsStore(),
    );
    unawaited(_settingsController.load());
    _libraryController = LibraryController(
      repository:
          widget.libraryRepository ??
          FileLibraryRepository(storageGateway: AndroidStorageGateway()),
    );
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
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          );
        },
        home: LibraryScreen(
          controller: _libraryController,
          documentContentSource:
              widget.documentContentSource ??
              const DeviceDocumentContentSource(),
        ),
      ),
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
