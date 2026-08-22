import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/theme/app_theme.dart';
import '../features/auth/view/auth_gate.dart';

class StarTrackerApp extends StatelessWidget {
  const StarTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadApp.custom(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      appBuilder: (context) {
        const ink = Color(0xFF171713);
        final textTheme = ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        );
        final materialTheme = ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: Colors.white,
          colorScheme:
              ColorScheme.fromSeed(
                seedColor: const Color(0xFFF8E94E),
                brightness: Brightness.light,
              ).copyWith(
                primary: ink,
                onPrimary: Colors.white,
                surface: Colors.white,
                onSurface: ink,
                onSurfaceVariant: const Color(0xFF5F5D57),
              ),
          textTheme: textTheme,
          primaryTextTheme: textTheme,
          iconTheme: const IconThemeData(color: ink),
        );

        return MaterialApp(
          title: 'Star Tracker Entregas',
          debugShowCheckedModeBanner: false,
          theme: materialTheme,
          darkTheme: materialTheme,
          themeMode: ThemeMode.light,
          localizationsDelegates: const [
            GlobalShadLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('pt', 'BR'), Locale('en', 'US')],
          builder: (context, child) => ShadAppBuilder(child: child!),
          home: const AuthGate(),
        );
      },
    );
  }
}
