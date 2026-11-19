import 'dart:async';

import 'package:dio/dio.dart';

import 'offline_request_queue.dart';

/// Quanto uma leitura espera a rede antes de usar a cópia do aparelho.
///
/// Com o celular "conectado" mas sem tráfego (4G sem dados, antena fraca),
/// cada leitura esperava até 30 s para conectar e 45 s pela resposta, e ainda
/// era repetida: minutos parado diante de uma tela que já tinha a cópia
/// local. Telas que funcionam offline usam este prazo e seguem com a cópia.
abstract final class OfflineDeadline {
  /// Leituras com cópia local (conferência, detalhe, listas, pedido).
  static Duration read = const Duration(seconds: 8);

  /// Política de comprovante antes de abrir a baixa (tem cópia sempre).
  static Duration policy = const Duration(seconds: 4);
}

/// Sem rede: falha de transporte ou prazo estourado.
bool isOfflineError(Object error) =>
    error is TimeoutException ||
    (error is DioException && OfflineRequestQueue.isNetworkFailure(error));
