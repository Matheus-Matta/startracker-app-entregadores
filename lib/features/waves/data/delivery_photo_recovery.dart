import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../../../core/storage/session_storage.dart';

class DeliveryDraftItem {
  const DeliveryDraftItem({
    required this.id,
    required this.status,
    required this.reason,
    required this.notes,
  });

  final int id;
  final String? status;
  final String reason;
  final String notes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status,
    'reason': reason,
    'notes': notes,
  };

  factory DeliveryDraftItem.fromJson(Map<String, dynamic> json) =>
      DeliveryDraftItem(
        id: _asInt(json['id']) ?? 0,
        status: json['status']?.toString(),
        reason: json['reason']?.toString() ?? '',
        notes: json['notes']?.toString() ?? '',
      );
}

class PendingDeliveryDraft {
  const PendingDeliveryDraft({
    required this.routeId,
    required this.stopId,
    required this.recipientName,
    required this.recipientDocument,
    required this.notes,
    required this.items,
    required this.signatureBytes,
  });

  final int routeId;
  final int stopId;
  final String recipientName;
  final String recipientDocument;
  final String notes;
  final List<DeliveryDraftItem> items;
  final Uint8List? signatureBytes;

  Map<String, dynamic> toJson() => {
    'route_id': routeId,
    'stop_id': stopId,
    'recipient_name': recipientName,
    'recipient_document': recipientDocument,
    'notes': notes,
    'items': items.map((item) => item.toJson()).toList(),
    if (signatureBytes != null) 'signature': base64Encode(signatureBytes!),
  };

  factory PendingDeliveryDraft.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    Uint8List? signature;
    try {
      final encoded = json['signature']?.toString();
      if (encoded != null && encoded.isNotEmpty) {
        signature = base64Decode(encoded);
      }
    } on FormatException {
      signature = null;
    }
    return PendingDeliveryDraft(
      routeId: _asInt(json['route_id']) ?? 0,
      stopId: _asInt(json['stop_id']) ?? 0,
      recipientName: json['recipient_name']?.toString() ?? '',
      recipientDocument: json['recipient_document']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => DeliveryDraftItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const [],
      signatureBytes: signature,
    );
  }
}

class RecoveredDeliveryCapture {
  const RecoveredDeliveryCapture({
    required this.draft,
    required this.filename,
    required this.photoBytes,
  });

  final PendingDeliveryDraft draft;
  final String filename;
  final Uint8List photoBytes;
}

class DeliveryPhotoRecovery {
  DeliveryPhotoRecovery(this._storage, {ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final SessionStorage _storage;
  final ImagePicker _picker;

  Future<void> saveDraft(PendingDeliveryDraft draft) =>
      _storage.savePendingDeliveryCapture(draft.toJson());

  Future<void> clearDraft() => _storage.clearPendingDeliveryCapture();

  Future<RecoveredDeliveryCapture?> recoverLostCapture() async {
    try {
      final response = await _picker.retrieveLostData();
      final rawDraft = await _storage.readPendingDeliveryCapture();
      if (response.isEmpty || rawDraft == null) {
        await clearDraft();
        return null;
      }
      final files = response.files;
      if (files == null || files.isEmpty) {
        await clearDraft();
        return null;
      }
      final draft = PendingDeliveryDraft.fromJson(rawDraft);
      if (draft.routeId <= 0 || draft.stopId <= 0) {
        await clearDraft();
        return null;
      }
      final file = files.first;
      final bytes = await file.readAsBytes();
      await clearDraft();
      return RecoveredDeliveryCapture(
        draft: draft,
        filename: file.name,
        photoBytes: bytes,
      );
    } catch (_) {
      // Uma falha de leitura nao deve impedir a restauracao normal da sessao.
      return null;
    }
  }
}

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};
