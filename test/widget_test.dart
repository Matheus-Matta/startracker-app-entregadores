import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/auth/view/login_page.dart';

void main() {
  testWidgets('avança o status da entrega', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.text('Acesse sua conta'), findsOneWidget);
    await tester.ensureVisible(find.text('Entrar na plataforma'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar na plataforma'));
    await tester.pumpAndSettle();

    expect(find.text('Informe seu usuário'), findsOneWidget);
    expect(find.text('Informe sua senha'), findsOneWidget);
  });
}
