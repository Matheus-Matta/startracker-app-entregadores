import 'package:flutter/material.dart';

import '../network/offline_request_queue.dart';

/// Ações que o servidor recusou. Nada some sozinho: o entregador vê o motivo
/// e decide reenviar (depois de corrigir o que faltava) ou descartar.
class SyncAttentionPage extends StatefulWidget {
  const SyncAttentionPage({required this.queue, super.key});

  final OfflineRequestQueue queue;

  @override
  State<SyncAttentionPage> createState() => _SyncAttentionPageState();
}

class _SyncAttentionPageState extends State<SyncAttentionPage> {
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    widget.queue.status.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.queue.status.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _retry(QueuedRequestInfo item) async {
    setState(() => _busy.add(item.id));
    try {
      await widget.queue.retryRejected(item.id);
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  Future<void> _discard(QueuedRequestInfo item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar esta ação?'),
        content: Text(
          '"${item.description}" será apagada do aparelho e não será enviada. '
          'Use só se você já refez a ação ou se ela não aconteceu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.queue.discardRejected(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.queue.rejectedRequests;
    return Scaffold(
      appBar: AppBar(title: const Text('Precisa de atenção')),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhuma ação recusada. Tudo certo.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                final busy = _busy.contains(item.id);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.description,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Feita em ${_format(item.createdAt)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(item.rejection ?? 'Recusada pelo servidor.'),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: busy ? null : () => _discard(item),
                              child: const Text('Descartar'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: busy ? null : () => _retry(item),
                              child: busy
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Reenviar'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
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
