import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/star_tracker_app.dart';
import 'core/network/api_failure.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Erro inesperado (fora das requisições) também vai para o histórico de
  // falhas da tela de diagnóstico: antes só aparecia no console, e no
  // celular do entregador ninguém via.
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    _recordUnexpected(details.exception);
    presentError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _recordUnexpected(error);
    // `false`: o Flutter continua relatando o erro como antes.
    return false;
  };
  runApp(const StarTrackerApp());
}

void _recordUnexpected(Object error) {
  final text = error.toString();
  // Fora do quadro em construção: o histórico avisa telas que o exibem.
  Timer.run(
    () => ApiFailureLog.instance.record(
      ApiFailure(
        stage: 'Erro inesperado no app',
        kind: ApiFailureKind.unknown,
        detail: text.length > 300 ? '${text.substring(0, 300)}…' : text,
      ),
    ),
  );
}
