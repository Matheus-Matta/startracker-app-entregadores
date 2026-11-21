import 'dart:async';

import 'package:flutter/material.dart';

import '../network/offline_request_queue.dart';
import '../storage/session_storage.dart';
import 'offline_queue_banner.dart';
import 'sync_attention_page.dart';

const _ink = Color(0xFF171713);
const _muted = Color(0xFF858279);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _danger = Color(0xFFB3261E);

/// Fila de envio (Configurações): o que está salvo no aparelho aguardando o
/// servidor. O envio é sempre em segundo plano; aqui o entregador só confere,
/// força uma tentativa ou liga a faixa no topo do app.
class SendQueuePage extends StatefulWidget {
  const SendQueuePage({required this.queue, required this.storage, super.key});

  final OfflineRequestQueue queue;
  final SessionStorage storage;

  @override
  State<SendQueuePage> createState() => _SendQueuePageState();
}

class _SendQueuePageState extends State<SendQueuePage> {
  /// Com centenas de ações na fila, montar todas travaria a tela.
  static const _shownLimit = 100;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.queue.status.addListener(_refresh);
    OfflineQueueBanner.showPending.addListener(_refresh);
    // Contagem regressiva da próxima tentativa.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    widget.queue.status.removeListener(_refresh);
    OfflineQueueBanner.showPending.removeListener(_refresh);
    _ticker?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _setShowOnTop(bool value) async {
    OfflineQueueBanner.showPending.value = value;
    await widget.storage.saveShowSendQueue(value);
  }

  void _openAttention() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SyncAttentionPage(queue: widget.queue),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = widget.queue.status.value;
    final pending = widget.queue.pendingRequests;
    final rejected = status.rejectedCount;
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        title: const Text(
          'Fila de envio',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        children: [
          _StatusCard(
            status: status,
            onRetry: status.hasPending && !status.sending && !status.needsLogin
                ? () => unawaited(widget.queue.retryNow(manual: true))
                : null,
          ),
          if (rejected > 0) ...[
            const SizedBox(height: 12),
            Material(
              color: _danger,
              borderRadius: BorderRadius.circular(18),
              child: ListTile(
                onTap: _openAttention,
                leading: const Icon(
                  Icons.error_outline_rounded,
                  color: _yellow,
                ),
                title: Text(
                  rejected == 1
                      ? '1 ação precisa de atenção'
                      : '$rejected ações precisam de atenção',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: const Text(
                  'O servidor recusou. Toque para ver o motivo.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text(
                'Mostrar fila de envio no topo',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Exibe "Sem conexão" e "Enviando…" no topo do app. Ações '
                'recusadas aparecem sempre.',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
              value: OfflineQueueBanner.showPending.value,
              activeThumbColor: Colors.black,
              activeTrackColor: _yellow,
              onChanged: (value) => unawaited(_setShowOnTop(value)),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Aguardando envio',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                '${pending.length}',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Nada aguardando. Tudo o que você fez já chegou ao servidor.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted),
              ),
            )
          else ...[
            for (final item in pending.take(_shownLimit))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.schedule_rounded, color: _ink),
                    title: Text(
                      item.description,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text('Feita em ${_format(item.createdAt)}'),
                  ),
                ),
              ),
            if (pending.length > _shownLimit)
              Text(
                '+ ${pending.length - _shownLimit} ações mais recentes',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _muted),
              ),
          ],
        ],
      ),
    );
  }

  static String _format(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.onRetry});

  final OfflineQueueStatus status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final count = status.pendingCount;
    final (IconData icon, String title, String detail) = switch (status) {
      _ when !status.hasPending => (
        Icons.cloud_done_outlined,
        'Tudo enviado',
        'Nenhuma ação aguardando o servidor.',
      ),
      _ when status.sending => (
        Icons.cloud_upload_outlined,
        'Enviando…',
        _saved(count),
      ),
      _ when status.needsLogin => (
        Icons.lock_clock_outlined,
        'Sessão expirada',
        '${_saved(count)}. Entre novamente para enviar.',
      ),
      _ => (Icons.cloud_off_rounded, 'Sem conexão', _retryText(count)),
    };
    return Material(
      color: _ink,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
        child: Row(
          children: [
            Icon(icon, color: _yellow),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (onRetry != null)
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
    );
  }

  static String _saved(int count) => count == 1
      ? '1 ação salva no aparelho'
      : '$count ações salvas no aparelho';

  String _retryText(int count) {
    final next = status.nextRetryAt;
    if (next == null) return '${_saved(count)}. Envia assim que houver sinal.';
    final seconds = next.difference(DateTime.now()).inSeconds.clamp(0, 3600);
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '${_saved(count)}. Nova tentativa em ${seconds ~/ 60}:$rest.';
  }
}
