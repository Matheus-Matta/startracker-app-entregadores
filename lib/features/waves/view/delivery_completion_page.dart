import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../data/active_route_service.dart';
import '../data/delivery_photo_recovery.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF77746C);

class DeliveryCompletionPage extends StatefulWidget {
  const DeliveryCompletionPage({
    required this.routeId,
    required this.stop,
    required this.service,
    this.recoveredCapture,
    super.key,
  });

  final int routeId;
  final ActiveRouteStop stop;
  final ActiveRouteService service;
  final RecoveredDeliveryCapture? recoveredCapture;

  @override
  State<DeliveryCompletionPage> createState() => _DeliveryCompletionPageState();
}

class _DeliveryCompletionPageState extends State<DeliveryCompletionPage> {
  final _recipientController = TextEditingController();
  final _documentController = TextEditingController();
  final _notesController = TextEditingController();
  final _picker = ImagePicker();
  late final DeliveryPhotoRecovery _photoRecovery;
  final _photos = <_CapturedPhoto>[];
  late final List<_ItemCompletionState> _itemStates;
  Uint8List? _signatureBytes;
  bool _submitting = false;
  bool _openingCamera = false;

  CompletionPolicy get _policy => widget.stop.policy;
  int get _totalPhotos => widget.stop.existingPhotoCount + _photos.length;

  @override
  void initState() {
    super.initState();
    _photoRecovery = DeliveryPhotoRecovery(widget.service.storage);
    final recovered = widget.recoveredCapture;
    final draft = recovered?.draft;
    _recipientController.text =
        draft?.recipientName ?? widget.stop.existingRecipientName;
    _documentController.text =
        draft?.recipientDocument ?? widget.stop.existingRecipientDocument;
    _notesController.text = draft?.notes ?? widget.stop.existingNotes;
    _itemStates = widget.stop.contents
        .map(_ItemCompletionState.fromItem)
        .toList();
    if (draft != null) {
      for (final state in _itemStates) {
        final saved = draft.items.where((item) => item.id == state.item.id);
        if (saved.isEmpty) continue;
        final item = saved.first;
        state.status = item.status;
        state.reason = item.reason;
        state.notesController.text = item.notes;
      }
      _signatureBytes = draft.signatureBytes;
    }
    if (recovered != null) {
      _photos.add(_CapturedPhoto(recovered.filename, recovered.photoBytes));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _message('Foto recuperada. Confirme os dados da entrega.');
      });
    }
  }

  @override
  void dispose() {
    _recipientController.dispose();
    _documentController.dispose();
    _notesController.dispose();
    for (final item in _itemStates) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _takePhoto() async {
    if (_openingCamera || _totalPhotos >= _policy.maximumPhotos) return;
    setState(() => _openingCamera = true);
    try {
      await _photoRecovery.saveDraft(_currentDraft());
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 78,
        maxWidth: 1800,
      );
      if (file == null) {
        await _photoRecovery.clearDraft();
        return;
      }
      final bytes = await file.readAsBytes();
      await _photoRecovery.clearDraft();
      if (!mounted) return;
      setState(() => _photos.add(_CapturedPhoto(file.name, bytes)));
    } catch (_) {
      await _photoRecovery.clearDraft();
      if (!mounted) return;
      _message(
        'A câmera é obrigatória para registrar a foto. Permita o acesso nas configurações do telefone.',
      );
    } finally {
      if (mounted) setState(() => _openingCamera = false);
    }
  }

  PendingDeliveryDraft _currentDraft() => PendingDeliveryDraft(
    routeId: widget.routeId,
    stopId: widget.stop.stopId,
    recipientName: _recipientController.text,
    recipientDocument: _documentController.text,
    notes: _notesController.text,
    items: _itemStates
        .map(
          (state) => DeliveryDraftItem(
            id: state.item.id,
            status: state.status,
            reason: state.reason,
            notes: state.notesController.text,
          ),
        )
        .toList(),
    signatureBytes: _signatureBytes,
  );

  Future<void> _openSignature() async {
    final signature = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        builder: (_) => const _SignatureCapturePage(),
      ),
    );
    if (!mounted || signature == null) return;
    setState(() => _signatureBytes = signature);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final validation = _validate();
    if (validation != null) {
      _message(validation);
      return;
    }

    setState(() => _submitting = true);
    try {
      final position = await _positionIfAvailable();
      await widget.service.complete(
        DeliveryProofSubmission(
          stop: widget.stop,
          recipientName: _recipientController.text,
          recipientDocument: _documentController.text,
          notes: _notesController.text,
          photos: _photos
              .map(
                (photo) => DeliveryPhotoUpload(
                  bytes: photo.bytes,
                  filename: photo.filename,
                ),
              )
              .toList(),
          signatureBytes: _signatureBytes,
          latitude: position?.latitude,
          longitude: position?.longitude,
          itemResults: _itemStates
              .map(
                (state) => DeliveryItemResult(
                  id: state.item.id,
                  status: state.status!,
                  reason: state.status == 'failed' ? state.reason : '',
                  notes: state.status == 'failed'
                      ? state.notesController.text
                      : '',
                ),
              )
              .toList(),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ActiveRouteException catch (error) {
      if (mounted) _message(error.message);
    } catch (_) {
      if (mounted) _message('Não foi possível finalizar esta entrega.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _validate() {
    for (var index = 0; index < _itemStates.length; index++) {
      final state = _itemStates[index];
      if (state.item.id <= 0) {
        return 'O item ${index + 1} não possui um identificador válido.';
      }
      if (state.status == null) {
        return 'Informe se o item ${index + 1} foi entregue.';
      }
      if (state.status == 'failed' && state.reason.trim().isEmpty) {
        return 'Informe o motivo da falha do item ${index + 1}.';
      }
      if (state.status == 'failed' &&
          _policy.requireNoteOnFailure &&
          state.notesController.text.trim().isEmpty) {
        return 'Informe uma observação para o item ${index + 1}.';
      }
    }
    if (_policy.requireRecipientName &&
        _recipientController.text.trim().isEmpty) {
      return 'Informe o nome de quem recebeu o pedido.';
    }
    if (_policy.requireDocument && _documentController.text.trim().isEmpty) {
      return 'Informe o documento de quem recebeu o pedido.';
    }
    if (_policy.requirePhoto && _totalPhotos < _policy.minimumPhotos) {
      final missing = _policy.minimumPhotos - _totalPhotos;
      return 'Tire mais $missing foto${missing == 1 ? '' : 's'} para continuar.';
    }
    if (_policy.requireSignature &&
        !widget.stop.hasSignature &&
        _signatureBytes == null) {
      return 'Faça a assinatura para continuar.';
    }
    return null;
  }

  Future<Position?> _positionIfAvailable() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Finalizar entrega',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 120),
        children: [
          _OrderSummary(stop: widget.stop),
          const SizedBox(height: 18),
          if (_itemStates.isNotEmpty) ...[
            _ItemResultsSection(
              states: _itemStates,
              requireFailureNotes: _policy.requireNoteOnFailure,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 20),
          ],
          if (_policy.requireRecipientName) ...[
            _FieldLabel(
              icon: Icons.person_outline_rounded,
              label: 'Nome de quem recebeu',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _recipientController,
              textCapitalization: TextCapitalization.words,
              decoration: _inputDecoration('Digite o nome completo'),
            ),
            const SizedBox(height: 16),
          ],
          if (_policy.requireDocument) ...[
            _FieldLabel(
              icon: Icons.badge_outlined,
              label: 'Documento do recebedor',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _documentController,
              decoration: _inputDecoration('CPF ou documento'),
            ),
            const SizedBox(height: 16),
          ],
          _PhotoSection(
            photos: _photos,
            existingCount: widget.stop.existingPhotoCount,
            minimum: _policy.minimumPhotos,
            maximum: _policy.maximumPhotos,
            openingCamera: _openingCamera,
            onTakePhoto: _takePhoto,
            onRemove: (index) => setState(() => _photos.removeAt(index)),
          ),
          if (_policy.requireSignature) ...[
            const SizedBox(height: 20),
            const _FieldLabel(icon: Icons.draw_outlined, label: 'Assinatura'),
            const SizedBox(height: 8),
            if (widget.stop.hasSignature)
              const _AlreadyRegistered(label: 'Assinatura já registrada'),
            if (_signatureBytes != null) ...[
              if (widget.stop.hasSignature) const SizedBox(height: 8),
              Container(
                width: double.infinity,
                height: 82,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: const Color(0xFFD8D5CC)),
                ),
                child: Image.memory(_signatureBytes!, fit: BoxFit.contain),
              ),
            ],
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _openSignature,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _ink,
                  side: const BorderSide(color: _ink),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.draw_rounded),
                label: Text(
                  widget.stop.hasSignature || _signatureBytes != null
                      ? 'Refazer assinatura'
                      : 'Coletar assinatura',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (_policy.captureTimestamp) ...[
            const _AlreadyRegistered(
              label: 'Data e hora serão registradas pelo servidor',
            ),
            const SizedBox(height: 16),
          ],
          const _FieldLabel(
            icon: Icons.notes_rounded,
            label: 'Observações (opcional)',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notesController,
            minLines: 3,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: _inputDecoration('Adicione alguma observação'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          decoration: const BoxDecoration(
            color: _cream,
            border: Border(top: BorderSide(color: Color(0xFFE2DFD6))),
          ),
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              icon: _submitting
                  ? const SizedBox.square(
                      dimension: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_rounded),
              label: Text(
                _submitting ? 'Finalizando...' : 'Confirmar entrega',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFE2DFD6)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: _ink, width: 1.5),
    ),
  );
}

class _CapturedPhoto {
  const _CapturedPhoto(this.filename, this.bytes);
  final String filename;
  final Uint8List bytes;
}

class _ItemCompletionState {
  _ItemCompletionState({
    required this.item,
    required this.status,
    required this.reason,
    required String notes,
  }) : notesController = TextEditingController(text: notes);

  factory _ItemCompletionState.fromItem(DeliveryContentItem item) {
    final savedStatus = const {'delivered', 'failed'}.contains(item.status)
        ? item.status
        : null;
    return _ItemCompletionState(
      item: item,
      status: savedStatus,
      reason: item.failureReason.isEmpty
          ? 'recipient_absent'
          : item.failureReason,
      notes: item.failureNotes,
    );
  }

  final DeliveryContentItem item;
  final TextEditingController notesController;
  String? status;
  String reason;

  void dispose() => notesController.dispose();
}

class _ItemResultsSection extends StatelessWidget {
  const _ItemResultsSection({
    required this.states,
    required this.requireFailureNotes,
    required this.onChanged,
  });

  final List<_ItemCompletionState> states;
  final bool requireFailureNotes;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _FieldLabel(
        icon: Icons.inventory_2_outlined,
        label: 'Resultado de cada item',
      ),
      const SizedBox(height: 5),
      const Text(
        'Confirme individualmente o que foi entregue.',
        style: TextStyle(fontSize: 11, color: _muted),
      ),
      const SizedBox(height: 11),
      ...states.indexed.map(
        (entry) => Padding(
          padding: EdgeInsets.only(
            bottom: entry.$1 == states.length - 1 ? 0 : 10,
          ),
          child: _ItemResultCard(
            index: entry.$1 + 1,
            state: entry.$2,
            requireFailureNotes: requireFailureNotes,
            onChanged: onChanged,
          ),
        ),
      ),
    ],
  );
}

class _ItemResultCard extends StatelessWidget {
  const _ItemResultCard({
    required this.index,
    required this.state,
    required this.requireFailureNotes,
    required this.onChanged,
  });

  static const _reasons = <String, String>{
    'recipient_absent': 'Cliente ausente',
    'Cliente recusou o pedido': 'Cliente recusou o pedido',
    'Endereço não localizado': 'Endereço não localizado',
    'other': 'Outro motivo',
  };

  final int index;
  final _ItemCompletionState state;
  final bool requireFailureNotes;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final delivered = state.status == 'delivered';
    final failed = state.status == 'failed';
    final reasons = Map<String, String>.from(_reasons);
    if (state.reason.isNotEmpty && !reasons.containsKey(state.reason)) {
      reasons[state.reason] = state.reason;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: failed
              ? const Color(0xFFF0B8B3)
              : delivered
              ? const Color(0xFFB9DDBF)
              : const Color(0xFFE2DFD6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _cream,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  '$index',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.item.name,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      '${state.item.volumeCount} volume${state.item.volumeCount == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ResultButton(
                  selected: delivered,
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Entregue',
                  selectedColor: const Color(0xFF238636),
                  onPressed: () {
                    state.status = 'delivered';
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ResultButton(
                  selected: failed,
                  icon: Icons.cancel_outlined,
                  label: 'Não entregue',
                  selectedColor: const Color(0xFFB42318),
                  onPressed: () {
                    state.status = 'failed';
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          if (failed) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: state.reason,
              isExpanded: true,
              decoration: _itemInputDecoration('Motivo da falha'),
              items: reasons.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                state.reason = value;
                onChanged();
              },
            ),
            const SizedBox(height: 9),
            TextField(
              controller: state.notesController,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: _itemInputDecoration(
                requireFailureNotes
                    ? 'Observação obrigatória'
                    : 'Observação (opcional)',
              ),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _itemInputDecoration(String label) => InputDecoration(
    labelText: label,
    filled: true,
    fillColor: _cream,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: BorderSide.none,
    ),
  );
}

class _ResultButton extends StatelessWidget {
  const _ResultButton({
    required this.selected,
    required this.icon,
    required this.label,
    required this.selectedColor,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final Color selectedColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 43,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? Colors.white : _ink,
        backgroundColor: selected ? selectedColor : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        side: BorderSide(
          color: selected ? selectedColor : const Color(0xFFD8D5CC),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      icon: Icon(icon, size: 18),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    ),
  );
}

class _OrderSummary extends StatelessWidget {
  const _OrderSummary({required this.stop});
  final ActiveRouteStop stop;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: _yellow,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Row(
      children: [
        Container(
          width: 45,
          height: 45,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Text(
            '${stop.sequence}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stop.customerName,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 3),
              Text(
                stop.orderNumber,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 19, color: _ink),
      const SizedBox(width: 7),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    ],
  );
}

class _PhotoSection extends StatelessWidget {
  const _PhotoSection({
    required this.photos,
    required this.existingCount,
    required this.minimum,
    required this.maximum,
    required this.openingCamera,
    required this.onTakePhoto,
    required this.onRemove,
  });

  final List<_CapturedPhoto> photos;
  final int existingCount;
  final int minimum;
  final int maximum;
  final bool openingCamera;
  final VoidCallback onTakePhoto;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final total = existingCount + photos.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: _FieldLabel(
                icon: Icons.photo_camera_outlined,
                label: 'Fotos da entrega',
              ),
            ),
            Text(
              '$total/$maximum',
              style: const TextStyle(
                color: _muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          minimum > 0
              ? 'Mínimo $minimum · máximo $maximum'
              : 'Opcional · máximo $maximum',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        if (existingCount > 0) ...[
          const SizedBox(height: 9),
          _AlreadyRegistered(
            label:
                '$existingCount foto${existingCount == 1 ? '' : 's'} já registrada${existingCount == 1 ? '' : 's'}',
          ),
        ],
        if (photos.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.memory(
                      photos[index].bytes,
                      width: 92,
                      height: 92,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: InkWell(
                      onTap: () => onRemove(index),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: _ink,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 11),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton.icon(
            onPressed: total >= maximum || openingCamera ? null : onTakePhoto,
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              side: const BorderSide(color: _ink),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: openingCamera
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.camera_alt_rounded),
            label: Text(
              total >= maximum ? 'Limite de fotos atingido' : 'Abrir câmera',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _AlreadyRegistered extends StatelessWidget {
  const _AlreadyRegistered({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: const Color(0xFFE9F6E7),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.check_circle_rounded,
          color: Color(0xFF238636),
          size: 18,
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _SignatureCapturePage extends StatefulWidget {
  const _SignatureCapturePage();

  @override
  State<_SignatureCapturePage> createState() => _SignatureCapturePageState();
}

class _SignatureCapturePageState extends State<_SignatureCapturePage> {
  final _signatureKey = GlobalKey<_SignaturePadState>();
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
  }

  @override
  void dispose() {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_exporting) return;
    if (!(_signatureKey.currentState?.hasSignature ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Faça a assinatura para confirmar.')),
      );
      return;
    }
    setState(() => _exporting = true);
    final bytes = await _signatureKey.currentState?.exportPng();
    if (!mounted) return;
    setState(() => _exporting = false);
    if (bytes != null) Navigator.of(context).pop(bytes);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Cancelar',
                  onPressed: _exporting
                      ? null
                      : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Assinatura do recebedor',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'Assine com o dedo dentro da área branca.',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: _SignaturePad(key: _signatureKey)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: _exporting
                      ? null
                      : () => _signatureKey.currentState?.clear(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Limpar'),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _exporting ? null : _confirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: _ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                    ),
                    icon: _exporting
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: const Text(
                      'Confirmar assinatura',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _SignaturePad extends StatefulWidget {
  const _SignaturePad({super.key});

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final _boundaryKey = GlobalKey();
  final _points = <Offset?>[];
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  bool get hasSignature => _points.whereType<Offset>().length > 3;

  void clear() {
    _points.clear();
    _revision.value++;
  }

  void _addPoint(Offset? point) {
    _points.add(point);
    _revision.value++;
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  Future<Uint8List?> exportPng() async {
    if (!hasSignature) return null;
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 2.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _boundaryKey,
    child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFBDB9AF), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _addPoint(details.localPosition),
        onPanUpdate: (details) => _addPoint(details.localPosition),
        onPanEnd: (_) => _addPoint(null),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _SignaturePainter(_points, _revision)),
            ValueListenableBuilder<int>(
              valueListenable: _revision,
              builder: (context, _, _) => hasSignature
                  ? const SizedBox.shrink()
                  : const Center(
                      child: Text(
                        'Assine aqui',
                        style: TextStyle(
                          color: Color(0xFFAAA79F),
                          fontSize: 18,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.points, Listenable repaint) : super(repaint: repaint);
  final List<Offset?> points;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _ink
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.8;
    for (var index = 0; index < points.length - 1; index++) {
      final first = points[index];
      final second = points[index + 1];
      if (first != null && second != null) {
        canvas.drawLine(first, second, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => false;
}
