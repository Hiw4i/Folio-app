import pathlib

# ============ 2a. FolioSettings: themeMode with legacy migration ============
p = pathlib.Path('lib/shared/settings/folio_settings.dart')
src = p.read_text(encoding='utf-8')

old = '''  const FolioSettings({
    // Off for new users: plain fixed-contrast foregrounds, no backdrop cost.
    // Turning blur on also enables the adaptive black/white glyph foreground,
    // which samples the backdrop behind glass controls on the GPU.
    this.blurEnabled = false,
    this.liquidMotionEnabled = true,
    this.showNavigationOnScrollUp = true,
    this.lightTheme = false,
  });

  final bool blurEnabled;
  final bool liquidMotionEnabled;

  /// Preserve the existing upward-scroll shortcut for older settings files.
  /// PPTX uses centre taps only and never changes controls during a swipe.
  final bool showNavigationOnScrollUp;

  /// Paper appearance. False (the default) keeps the original dark theme.
  final bool lightTheme;

  FolioSettings copyWith({
    bool? blurEnabled,
    bool? liquidMotionEnabled,
    bool? showNavigationOnScrollUp,
    bool? lightTheme,
  }) => FolioSettings(
    blurEnabled: blurEnabled ?? this.blurEnabled,
    liquidMotionEnabled: liquidMotionEnabled ?? this.liquidMotionEnabled,
    showNavigationOnScrollUp:
        showNavigationOnScrollUp ?? this.showNavigationOnScrollUp,
    lightTheme: lightTheme ?? this.lightTheme,
  );

  factory FolioSettings.fromJson(Map<String, Object?> json) => FolioSettings(
    blurEnabled: json['blurEnabled'] is bool
        ? json['blurEnabled']! as bool
        : false,
    liquidMotionEnabled: json['liquidMotionEnabled'] is bool
        ? json['liquidMotionEnabled']! as bool
        : true,
    showNavigationOnScrollUp: json['showNavigationOnScrollUp'] is bool
        ? json['showNavigationOnScrollUp']! as bool
        : true,
    lightTheme: json['lightTheme'] is bool ? json['lightTheme']! as bool : false,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'blurEnabled': blurEnabled,
    'liquidMotionEnabled': liquidMotionEnabled,
    'showNavigationOnScrollUp': showNavigationOnScrollUp,
    'lightTheme': lightTheme,
  };

  @override
  bool operator ==(Object other) =>
      other is FolioSettings &&
      other.blurEnabled == blurEnabled &&
      other.liquidMotionEnabled == liquidMotionEnabled &&
      other.showNavigationOnScrollUp == showNavigationOnScrollUp &&
      other.lightTheme == lightTheme;

  @override
  int get hashCode =>
      Object.hash(
        blurEnabled,
        liquidMotionEnabled,
        showNavigationOnScrollUp,
        lightTheme,
      );'''

new = '''  const FolioSettings({
    // Off for new users: plain fixed-contrast foregrounds, no backdrop cost.
    // Turning blur on also enables the adaptive black/white glyph foreground,
    // which samples the backdrop behind glass controls on the GPU.
    this.blurEnabled = false,
    this.liquidMotionEnabled = true,
    this.showNavigationOnScrollUp = true,
    this.themeMode = FolioThemeMode.dark,
  });

  final bool blurEnabled;
  final bool liquidMotionEnabled;

  /// Preserve the existing upward-scroll shortcut for older settings files.
  /// PPTX uses centre taps only and never changes controls during a swipe.
  final bool showNavigationOnScrollUp;

  final FolioThemeMode themeMode;

  FolioSettings copyWith({
    bool? blurEnabled,
    bool? liquidMotionEnabled,
    bool? showNavigationOnScrollUp,
    FolioThemeMode? themeMode,
  }) => FolioSettings(
    blurEnabled: blurEnabled ?? this.blurEnabled,
    liquidMotionEnabled: liquidMotionEnabled ?? this.liquidMotionEnabled,
    showNavigationOnScrollUp:
        showNavigationOnScrollUp ?? this.showNavigationOnScrollUp,
    themeMode: themeMode ?? this.themeMode,
  );

  factory FolioSettings.fromJson(Map<String, Object?> json) {
    FolioThemeMode readThemeMode() => switch (json['themeMode']) {
      'light' => FolioThemeMode.light,
      'system' => FolioThemeMode.system,
      'dark' => FolioThemeMode.dark,
      // Settings written before the three-way selector existed: the old
      // boolean migrates once, then the field is dropped on the next save.
      _ => json['lightTheme'] == true
          ? FolioThemeMode.light
          : FolioThemeMode.dark,
    };
    return FolioSettings(
      blurEnabled: json['blurEnabled'] is bool
          ? json['blurEnabled']! as bool
          : false,
      liquidMotionEnabled: json['liquidMotionEnabled'] is bool
          ? json['liquidMotionEnabled']! as bool
          : true,
      showNavigationOnScrollUp: json['showNavigationOnScrollUp'] is bool
          ? json['showNavigationOnScrollUp']! as bool
          : true,
      themeMode: readThemeMode(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'blurEnabled': blurEnabled,
    'liquidMotionEnabled': liquidMotionEnabled,
    'showNavigationOnScrollUp': showNavigationOnScrollUp,
    'themeMode': themeMode.name,
  };

  @override
  bool operator ==(Object other) =>
      other is FolioSettings &&
      other.blurEnabled == blurEnabled &&
      other.liquidMotionEnabled == liquidMotionEnabled &&
      other.showNavigationOnScrollUp == showNavigationOnScrollUp &&
      other.themeMode == themeMode;

  @override
  int get hashCode =>
      Object.hash(
        blurEnabled,
        liquidMotionEnabled,
        showNavigationOnScrollUp,
        themeMode,
      );'''

assert old in src, 'settings block not found'
enum_block = '''enum FolioThemeMode { dark, light, system }

/// Persisted appearance and reading preferences. Navigation and document
/// rendering remain independent of the optional liquid-glass motion effect.'''
old_doc = '''/// Persisted appearance and reading preferences. Navigation and document
/// rendering remain independent of the optional liquid-glass motion effect.'''
assert old_doc in src
src = src.replace(old_doc, enum_block)
src = src.replace(old, new)
p.write_text(src, encoding='utf-8')
print('2a ok')

# ============ 2b. Controller ============
p2 = pathlib.Path('lib/shared/settings/folio_settings_controller.dart')
src2 = p2.read_text(encoding='utf-8')
old_a = '        lightTheme: _themeChanged ? _settings.lightTheme : null,'
assert old_a in src2
src2 = src2.replace(old_a, '        themeMode: _themeChanged ? _settings.themeMode : null,')
old_b = '''  void setLightTheme(bool enabled) {
    if (_disposed || enabled == _settings.lightTheme) {
      return;
    }
    _themeChanged = true;
    _settings = _settings.copyWith(lightTheme: enabled);
    _changed();
  }'''
assert old_b in src2
src2 = src2.replace(old_b, '''  void setThemeMode(FolioThemeMode mode) {
    if (_disposed || mode == _settings.themeMode) {
      return;
    }
    _themeChanged = true;
    _settings = _settings.copyWith(themeMode: mode);
    _changed();
  }''')
p2.write_text(src2, encoding='utf-8')
print('2b ok')

# ============ 2c. Scope helper ============
p3 = pathlib.Path('lib/shared/settings/folio_settings_scope.dart')
src3 = p3.read_text(encoding='utf-8')
old_c = '''  static bool lightThemeOf(BuildContext context) =>
      settingsOf(context).lightTheme;'''
assert old_c in src3
new_c = '''  /// The resolved appearance: [FolioThemeMode.system] reads the OS brightness
  /// through MediaQuery, so callers rebuild when it changes.
  static bool isLightThemeOf(BuildContext context) =>
      switch (settingsOf(context).themeMode) {
        FolioThemeMode.light => true,
        FolioThemeMode.dark => false,
        FolioThemeMode.system =>
          MediaQuery.platformBrightnessOf(context) == Brightness.light,
      };'''
src3 = src3.replace(old_c, new_c)
p3.write_text(src3, encoding='utf-8')
print('2c ok')
