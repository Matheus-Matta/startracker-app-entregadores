import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../network/api_failure.dart';
import 'app_messages.dart';

/// Últimas falhas de comunicação da sessão, com etapa, código e referência.
///
/// O entregador copia o relatório e manda ao suporte; cada linha traz o
/// `ref` que aparece no log do servidor para a mesma requisição.
class FailureLogPanel extends StatelessWidget {
  const FailureLogPanel({super.key, this.log, this.visibleEntries = 6});

  final ApiFailureLog? log;
  final int visibleEntries;

  @override
  Widget build(BuildContext context) {
    final source = log ?? ApiFailureLog.instance;
    return ValueListenableBuilder<List<ApiFailureLogEntry>>(
      valueListenable: source.entries,
      builder: (context, entries, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Diagnóstico de conexão',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            entries.isEmpty
                ? 'Nenhuma falha de comunicação nesta sessão.'
                : '${entries.length} falha(s) nesta sessão. Copie o '
                      'relatório para enviar ao suporte.',
            style: const TextStyle(color: Color(0xFF858279), fontSize: 11),
          ),
          for (final entry in entries.take(visibleEntries)) ...[
            const SizedBox(height: 10),
            _FailureRow(entry: entry),
          ],
          if (entries.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: source.export()),
                    );
                    if (context.mounted) {
                      showAppMessage(context, 'Relatório copiado.');
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copiar relatório'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: source.clear,
                  child: const Text('Limpar'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FailureRow extends StatelessWidget {
  const _FailureRow({required this.entry});

  final ApiFailureLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final failure = entry.failure;
    final time = TimeOfDay.fromDateTime(entry.at).format(context);
    final server = failure.serverMessages.isEmpty
        ? failure.reason
        : failure.serverMessages.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          failure.isTransient
              ? Icons.signal_cellular_connected_no_internet_4_bar_rounded
              : Icons.error_outline_rounded,
          size: 18,
          color: failure.isTransient
              ? const Color(0xFFB54708)
              : const Color(0xFFB42318),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$time · ${failure.stage}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                server,
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                [
                  failure.code,
                  if (failure.requestId.isNotEmpty) 'ref ${failure.requestId}',
                ].join(' · '),
                style: const TextStyle(
                  color: Color(0xFF858279),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
