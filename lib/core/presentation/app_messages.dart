import 'package:flutter/material.dart';

/// Quanto tempo um aviso transitorio fica na tela.
const appMessageDuration = Duration(seconds: 3);

/// Mostra um aviso curto, sempre substituindo o anterior.
///
/// Sem esconder o atual o Flutter enfileira as SnackBars: cada aviso novo so
/// aparece depois que o anterior termina, e a fila da a impressao de que os
/// avisos nao somem da tela.
void showAppMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: appMessageDuration),
    );
}
