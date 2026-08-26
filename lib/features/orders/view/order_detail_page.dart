import 'package:flutter/material.dart';

import '../../../app/app_dependencies.dart';
import '../data/order_service.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF858279);

class OrderDetailPage extends StatefulWidget {
  const OrderDetailPage({
    required this.orderId,
    required this.initialNumber,
    super.key,
  });

  final int orderId;
  final String initialNumber;

  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  late final OrderService _service;
  late Future<OrderDetails> _details;

  @override
  void initState() {
    super.initState();
    _service = AppDependencies.instance.orders;
    _details = _service.getOrderDetails(widget.orderId);
  }

  Future<void> _refresh() async {
    final nextDetails = _service.getOrderDetails(widget.orderId);
    setState(() {
      _details = nextDetails;
    });
    try {
      await nextDetails;
    } catch (_) {
      // O FutureBuilder mantém o erro visível e oferece uma nova tentativa.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: Column(
          children: [
            _OrderHeader(
              number: widget.initialNumber,
              onBack: () => Navigator.of(context).pop(false),
              onHome: () => Navigator.of(context).pop(true),
            ),
            Expanded(
              child: FutureBuilder<OrderDetails>(
                future: _details,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorState(onRetry: _refresh);
                  }
                  return _OrderBody(order: snapshot.data!, onRefresh: _refresh);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderHeader extends StatelessWidget {
  const _OrderHeader({
    required this.number,
    required this.onBack,
    required this.onHome,
  });

  final String number;
  final VoidCallback onBack;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 60,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 52),
            child: Text(
              number,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _HeaderButton(
              tooltip: 'Voltar',
              icon: Icons.arrow_back_rounded,
              onPressed: onBack,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _HeaderButton(
              tooltip: 'Ir para o início',
              icon: Icons.home_rounded,
              onPressed: onHome,
            ),
          ),
        ],
      ),
    ),
  );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: _yellow,
      minimumSize: const Size(38, 38),
      maximumSize: const Size(38, 38),
      padding: EdgeInsets.zero,
    ),
    icon: Icon(icon, size: 23, color: _ink),
  );
}

class _OrderBody extends StatelessWidget {
  const _OrderBody({required this.order, required this.onRefresh});

  final OrderDetails order;
  final Future<void> Function() onRefresh;

  static const _statusLabels = <String, String>{
    'created': 'Criado',
    'awaiting_geocode': 'Aguardando geocodificação',
    'outside_delivery_area': 'Fora da área',
    'waiting_wave': 'Aguardando carga',
    'ready_for_routing': 'Pronto para roteirização',
    'routing': 'Roteirizando',
    'awaiting_pickup': 'Aguardando retirada',
    'routed': 'Roteirizado',
    'released': 'Liberado',
    'out_for_delivery': 'Em entrega',
    'delivered': 'Entregue',
    'partially_delivered': 'Parcialmente entregue',
    'delivery_failed': 'Falha na entrega',
    'routing_failed': 'Falha na roteirização',
    'returned': 'Devolvido',
    'cancelled': 'Cancelado',
    'manual_assignment': 'Roteirização manual',
  };

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _SummaryCard(
          order: order,
          statusLabel: _statusLabels[order.status] ?? order.status,
        ),
        const SizedBox(height: 14),
        _SectionCard(
          title: 'Cliente',
          icon: Icons.person_outline_rounded,
          children: [
            _DetailRow(label: 'Nome', value: order.customerName),
            if (order.customerPhone.isNotEmpty)
              _DetailRow(label: 'Telefone', value: order.customerPhone),
          ],
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Endereço de entrega',
          icon: Icons.location_on_outlined,
          children: [
            _DetailRow(
              label: 'Destino',
              value: order.fullAddress.isEmpty
                  ? 'Endereço não informado'
                  : order.fullAddress,
            ),
            if (order.latitude != null && order.longitude != null)
              _DetailRow(
                label: 'Coordenadas',
                value:
                    '${order.latitude!.toStringAsFixed(6)}, '
                    '${order.longitude!.toStringAsFixed(6)}',
              ),
          ],
        ),
        if (order.hasPayment) ...[
          const SizedBox(height: 12),
          _PaymentCard(order: order),
        ],
        if (order.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _NotesCard(notes: order.notes),
        ],
        const SizedBox(height: 12),
        _PlanningCard(order: order),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Itens e volumes',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              '${order.items.length} itens',
              style: const TextStyle(
                color: _muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        if (order.items.isEmpty)
          const _NoItemsCard()
        else
          ...order.items.indexed.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ItemCard(index: entry.$1 + 1, item: entry.$2),
            ),
          ),
        if (_hasOperationalDetails(order)) ...[
          const SizedBox(height: 4),
          _OperationalCard(order: order),
        ],
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Identificação',
          icon: Icons.badge_outlined,
          children: [
            _DetailRow(label: 'ID interno', value: '#${order.id}'),
            if (order.externalSource.isNotEmpty)
              _DetailRow(label: 'Origem', value: order.externalSource),
            if (order.externalId.isNotEmpty)
              _DetailRow(label: 'ID externo', value: order.externalId),
            if (order.warehouseId != null)
              _DetailRow(label: 'Armazém', value: '#${order.warehouseId}'),
            if (order.splitFromId != null)
              _DetailRow(
                label: 'Desmembrado de',
                value: 'Pedido #${order.splitFromId}',
              ),
            if (order.createdAt != null)
              _DetailRow(
                label: 'Criado em',
                value: _formatDate(order.createdAt!),
              ),
            if (order.updatedAt != null)
              _DetailRow(
                label: 'Atualizado em',
                value: _formatDate(order.updatedAt!),
              ),
          ],
        ),
      ],
    ),
  );

  bool _hasOperationalDetails(OrderDetails order) =>
      order.unassignedReason.isNotEmpty ||
      order.skills.isNotEmpty ||
      order.proofOverrides.isNotEmpty;

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.order, required this.statusLabel});

  final OrderDetails order;
  final String statusLabel;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: _yellow,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14171713),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.inventory_2_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.number,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    statusLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _SummaryMetric(
                icon: Icons.widgets_outlined,
                label: 'Volumes',
                value: '${order.units}',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.monitor_weight_outlined,
                label: 'Peso',
                value: _formatWeight(order.weightGrams),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SummaryMetric(
                icon: Icons.view_in_ar_outlined,
                label: 'Cubagem',
                value: _formatVolume(order.volumeCubicCentimeters),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: _muted, fontSize: 9)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE8E5DC)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
            ),
          ],
        ),
        const SizedBox(height: 13),
        ...children,
      ],
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(color: _muted, fontSize: 10),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _PlanningCard extends StatelessWidget {
  const _PlanningCard({required this.order});

  final OrderDetails order;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: 'Planejamento',
    icon: Icons.event_note_outlined,
    children: [
      _DetailRow(
        label: 'Prioridade',
        value:
            '${order.effectivePriority} efetiva (${order.priority} original)',
      ),
      _DetailRow(
        label: 'Atendimento',
        value: _formatDuration(order.serviceDurationSeconds),
      ),
      if (order.deliveryWindowStart != null || order.deliveryWindowEnd != null)
        _DetailRow(
          label: 'Janela',
          value: _dateRange(order.deliveryWindowStart, order.deliveryWindowEnd),
        ),
      if (order.promisedAt != null)
        _DetailRow(label: 'Prometido', value: _formatDate(order.promisedAt!)),
      if (order.readyAt != null)
        _DetailRow(label: 'Liberado', value: _formatDate(order.readyAt!)),
    ],
  );

  String _dateRange(DateTime? start, DateTime? end) => [
    if (start != null) _formatDate(start),
    if (end != null) _formatDate(end),
  ].join(' até ');
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.order});

  final OrderDetails order;

  static const _methodLabels = <String, String>{
    'cash': 'Dinheiro',
    'card': 'Cartão',
    'pix': 'Pix',
    'to_arrange': 'A combinar',
  };

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: 'Pagamento',
    icon: Icons.payments_outlined,
    children: [
      _DetailRow(
        label: 'Forma',
        value: order.paymentMethod.isEmpty
            ? 'Não informada'
            : _methodLabels[order.paymentMethod] ?? order.paymentMethod,
      ),
      if (order.paymentValue != null)
        _DetailRow(label: 'Valor', value: _formatCurrency(order.paymentValue!)),
      if (order.paymentMethod == 'cash' && order.paymentValue != null)
        const _DetailRow(
          label: 'Atenção',
          value: 'Receber o valor na entrega.',
        ),
    ],
  );
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: 'Observação',
    icon: Icons.sticky_note_2_outlined,
    children: [
      Text(
        notes,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.index, required this.item});

  final int index;
  final OrderItemDetails item;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE8E5DC)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _yellow,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Text(
                '$index',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.volumes.length} volumes',
                    style: const TextStyle(color: _muted, fontSize: 10),
                  ),
                ],
              ),
            ),
            _ItemStatusBadge(status: item.status),
          ],
        ),
        if (item.status == 'failed' &&
            (item.failureReason.isNotEmpty ||
                item.failureNotes.isNotEmpty)) ...[
          const SizedBox(height: 11),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEEEC),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.failureReason.isNotEmpty)
                  Text(
                    item.failureReason,
                    style: const TextStyle(
                      color: Color(0xFF9F2017),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                if (item.failureNotes.isNotEmpty) ...[
                  if (item.failureReason.isNotEmpty) const SizedBox(height: 3),
                  Text(
                    item.failureNotes,
                    style: const TextStyle(fontSize: 10, color: _muted),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (item.volumes.isNotEmpty) ...[
          const SizedBox(height: 13),
          ...item.volumes.indexed.map(
            (entry) => _VolumeRow(index: entry.$1 + 1, volume: entry.$2),
          ),
        ],
      ],
    ),
  );
}

class _ItemStatusBadge extends StatelessWidget {
  const _ItemStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color, background) = switch (status) {
      'delivered' => (
        'Entregue',
        const Color(0xFF238636),
        const Color(0xFFE9F6E7),
      ),
      'failed' => (
        'Não entregue',
        const Color(0xFFB42318),
        const Color(0xFFFFEEEC),
      ),
      _ => ('Pendente', _muted, _cream),
    };
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.index, required this.volume});

  final int index;
  final OrderVolumeDetails volume;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 7),
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    decoration: BoxDecoration(
      color: _cream,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: [
        const Icon(Icons.inventory_2_outlined, size: 17, color: _muted),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            'Volume $index · ${_dimension(volume.lengthCentimeters)} × '
            '${_dimension(volume.widthCentimeters)} × '
            '${_dimension(volume.heightCentimeters)} cm',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          _formatWeight(volume.weightGrams),
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );

  String _dimension(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
}

class _OperationalCard extends StatelessWidget {
  const _OperationalCard({required this.order});

  final OrderDetails order;

  static const _proofLabels = <String, String>{
    'require_photo': 'Foto obrigatória',
    'require_signature': 'Assinatura obrigatória',
    'require_recipient_name': 'Nome do recebedor',
    'require_document': 'Documento do recebedor',
  };

  @override
  Widget build(BuildContext context) {
    final proofRules = order.proofOverrides.entries
        .where((entry) => entry.value == true)
        .map((entry) => _proofLabels[entry.key] ?? entry.key)
        .toList();
    return _SectionCard(
      title: 'Operação',
      icon: Icons.assignment_outlined,
      children: [
        if (order.unassignedReason.isNotEmpty)
          _DetailRow(label: 'Observação', value: order.unassignedReason),
        if (order.skills.isNotEmpty)
          _DetailRow(label: 'Habilidades', value: order.skills.join(', ')),
        if (proofRules.isNotEmpty)
          _DetailRow(label: 'Comprovante', value: proofRules.join(' · ')),
      ],
    );
  }
}

class _NoItemsCard extends StatelessWidget {
  const _NoItemsCard();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE8E5DC)),
    ),
    child: const Column(
      children: [
        Icon(Icons.inventory_2_outlined, size: 36, color: _muted),
        SizedBox(height: 9),
        Text(
          'Pedido sem itemização',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        SizedBox(height: 4),
        Text(
          'Os totais agregados estão disponíveis no resumo acima.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 10),
        ),
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 44, color: _muted),
          const SizedBox(height: 12),
          const Text(
            'Não foi possível carregar o pedido',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Tentar novamente'),
          ),
        ],
      ),
    ),
  );
}

String _formatCurrency(double value) {
  final negative = value < 0;
  final parts = value.abs().toStringAsFixed(2).split('.');
  final digits = parts.first;
  final grouped = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write('.');
    grouped.write(digits[index]);
  }
  return '${negative ? '-' : ''}R\$ $grouped,${parts.last}';
}

String _formatWeight(int grams) {
  if (grams <= 0) return '—';
  return grams >= 1000 ? '${(grams / 1000).toStringAsFixed(1)} kg' : '$grams g';
}

String _formatVolume(int cubicCentimeters) {
  if (cubicCentimeters <= 0) return '—';
  return cubicCentimeters >= 1000
      ? '${(cubicCentimeters / 1000).toStringAsFixed(1)} L'
      : '$cubicCentimeters cm³';
}

String _formatDuration(int seconds) {
  if (seconds <= 0) return '—';
  final minutes = (seconds / 60).ceil();
  return '$minutes min';
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/'
      '${local.year} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
