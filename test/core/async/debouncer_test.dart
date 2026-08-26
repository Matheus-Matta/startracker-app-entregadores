import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/async/debouncer.dart';

void main() {
  testWidgets('executa somente a ultima acao dentro da janela', (tester) async {
    final debouncer = Debouncer(const Duration(milliseconds: 200));
    var value = 0;

    debouncer.run(() => value = 1);
    debouncer.run(() => value = 2);
    await tester.pump(const Duration(milliseconds: 199));
    expect(value, 0);

    await tester.pump(const Duration(milliseconds: 1));
    expect(value, 2);
    debouncer.dispose();
  });
}
