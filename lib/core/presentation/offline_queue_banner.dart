import 'dart:async';

import 'package:flutter/material.dart';

import '../network/offline_request_queue.dart';

const _ink = Color(0xFF171713);
const _yellow = Color(0xFFF8E94E);
const _danger = Color(0xFFB3261E);

/// Faixa no topo do app com o que ainda não chegou ao servidor.
///
/// Tudo que o entregador faz é salvo no aparelho primeiro e enviado em
/// segundo plano. Por padrão a faixa só aparece quando há algo que depende
/// dele: ação recusada pelo servidor ou sessão expirada. "Sem conexão" e
/// "Enviando…" ficam escondidos, a não ser que ele ligue "Mostrar fila de
/// envio no topo" nas Configurações (onde a fila também pode ser vista).
class OfflineQueueBanner extends StatefulWidget {
  const OfflineQueueBanner({
    required this.queue,
    required this.child,
    this.onOpenAttention,
    this.onLogin,
    super.key,
  });

  final OfflineRequestQueue queue;
  final Widget child;

  /// Abre a lista de ações recusadas.
  final VoidCallback? onOpenAttention;

  /// Sessão encerrada pelo servidor: leva ao login (antes o texto pedia
  /// "entre novamente" sem caminho até lá, fora das Configurações).
  final VoidCallback? onLogin;

  /// Preferência "Mostrar fila de envio no topo" (Configurações).
  static final showPending = ValueNotifier<bool>(false);

  /// Faixa visível para este estado da fila com a preferência atual.
  static bool shows(OfflineQueueStatus status, {required bool showPending}) {
    if (status.needsAttention && !status.sending) return true;
    if (status.hasPending && status.needsLogin) return true;
    return showPending && status.isVisible;
  }

  @override
  State<OfflineQueueBanner> createState() => _OfflineQueueBannerState();
}

class _OfflineQueueBannerState extends State<OfflineQueueBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.queue.status.addListener(_onStatus);
    OfflineQueueBanner.showPending.addListener(_onStatus);
    _onStatus();
  }

  @override
  void dispose() {
    widget.queue.status.removeListener(_onStatus);
    OfflineQueueBanner.showPending.removeListener(_onStatus);
    _ticker?.cancel();
    super.dispose();
  }

  void _onStatus() {
    final status = widget.queue.status.value;
    final needsTicker =
        OfflineQueueBanner.showPending.value &&
        status.hasPending &&
        status.nextRetryAt != null;
    if (needsTicker && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needsTicker) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.queue.status.value;
    if (!OfflineQueueBanner.shows(
      status,
      showPending: OfflineQueueBanner.showPending.value,
    )) {
      return widget.child;
    }
    return Column(
      children: [
        _Banner(
          status: status,
          onRetry: () => unawaited(widget.queue.retryNow(manual: true)),
          onOpenAttention: widget.onOpenAttention,
          onLogin: widget.onLogin,
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.status,
    required this.onRetry,
    required this.onOpenAttention,
    required this.onLogin,
  });

  final OfflineQueueStatus status;
  final VoidCallback onRetry;
  final VoidCallback? onOpenAttention;
  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) {
    final count = status.pendingCount;
    final saved = count == 1
        ? '1 ação salva no aparelho'
        : '$count ações salvas no aparelho';
    final rejected = status.rejectedCount;
    final String title;
    final String detail;
    final bool attention;
    if (status.needsAttention && !status.sending) {
      attention = true;
      title = rejected == 1
          ? '1 ação precisa de atenção'
          : '$rejected ações precisam de atenção';
      detail = count > 0
          ? 'O servidor recusou. $saved aguardando envio.'
          : 'O servidor recusou. Toque para ver o motivo.';
    } else if (status.sending) {
      attention = false;
      title = 'Enviando…';
      detail = saved;
    } else if (status.needsLogin) {
      attention = false;
      title = 'Sessão expirada · $saved';
      detail = 'Entre novamente para enviar. Nada foi perdido.';
    } else {
      attention = false;
      title = 'Sem conexão · $saved';
      final next = status.nextRetryAt;
      final seconds = next?.difference(DateTime.now()).inSeconds.clamp(0, 3600);
      detail = seconds == null
          ? 'Será enviado assim que houver sinal.'
          : 'Nova tentativa em ${_format(seconds)}. Pode continuar trabalhando.';
    }
    return Material(
      color: attention ? _danger : _ink,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(
                attention
                    ? Icons.error_outline_rounded
                    : status.sending
                    ? Icons.cloud_upload_outlined
                    : Icons.cloud_off_rounded,
                color: _yellow,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (attention && onOpenAttention != null)
                TextButton(
                  onPressed: onOpenAttention,
                  style: TextButton.styleFrom(foregroundColor: _yellow),
                  child: const Text(
                    'Ver',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              else if (status.sending)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _yellow,
                    ),
                  ),
                )
              else if (status.needsLogin && onLogin != null)
                TextButton(
                  onPressed: onLogin,
                  style: TextButton.styleFrom(foregroundColor: _yellow),
                  child: const Text(
                    'Entrar',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              else if (!status.needsLogin)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: _yellow),
                  child: const Text(
                    'Enviar agora',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _format(int seconds) {
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }
}
