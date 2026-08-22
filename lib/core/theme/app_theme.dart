import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

abstract final class AppTheme {
  static final light = ShadThemeData(
    brightness: Brightness.light,
    colorScheme: const ShadBlueColorScheme.light(),
  );

  static final dark = ShadThemeData(
    brightness: Brightness.dark,
    colorScheme: const ShadBlueColorScheme.dark(),
  );
}
