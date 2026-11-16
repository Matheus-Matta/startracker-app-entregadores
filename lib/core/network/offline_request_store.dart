import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Descrição serializável de uma requisição que falhou por falta de rede.
///
/// O `type` identifica o handler registrado na fila que sabe reconstruir a
/// operação depois que o app for reaberto. Arquivos binários (fotos e
/// assinatura) ficam em disco, fora do JSON, para não estourar memória.
class PersistedOfflineRequest {
  const PersistedOfflineRequest({
    required this.type,
    required this.payload,
    this.files = const {},
  });

  final String type;
  final Map<String, dynamic> payload;
  final Map<String, Uint8List> files;
}

class StoredOfflineRequest {
  const StoredOfflineRequest({
    required this.id,
    required this.resourceKey,
    required this.description,
    required this.idempotencyKey,
    required this.createdAt,
    required this.request,
  });

  final String id;
  final String resourceKey;
  final String description;
  final String idempotencyKey;
  final DateTime createdAt;
  final PersistedOfflineRequest request;
}

/// Guarda as requisições pendentes no diretório privado do app.
///
/// Cada requisição ocupa uma pasta própria: `request.json` + um arquivo por
/// anexo. A escrita do JSON é feita por último e via rename, então uma pasta
/// sem `request.json` é sempre lixo de uma gravação interrompida.
/// Registro salvo que não pôde ser reconstruído (JSON corrompido, anexo
/// apagado pelo sistema). Antes sumia em silêncio: uma baixa feita sem rede
/// desaparecia e ninguém sabia por quê.
class DiscardedOfflineRequest {
  const DiscardedOfflineRequest({
    required this.resourceKey,
    required this.description,
    required this.reason,
  });

  final String resourceKey;
  final String description;
  final String reason;
}

class OfflineRequestStore {
  OfflineRequestStore({Future<Directory> Function()? baseDirectory})
    : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDirectory;
  Directory? _root;

  /// O que a última chamada de [readAll] precisou descartar.
  List<DiscardedOfflineRequest> lastDiscarded = const [];

  Future<Directory> _rootDirectory() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await _baseDirectory();
    final root = Directory(
      '${base.path}${Platform.pathSeparator}offline_queue',
    );
    if (!await root.exists()) await root.create(recursive: true);
    return _root = root;
  }

  Future<void> save(StoredOfflineRequest stored) async {
    final root = await _rootDirectory();
    final folder = Directory(
      '${root.path}${Platform.pathSeparator}${_safe(stored.id)}',
    );
    await folder.create(recursive: true);
    final fileNames = <String, String>{};
    var index = 0;
    for (final entry in stored.request.files.entries) {
      final name = 'file_${index++}.bin';
      fileNames[entry.key] = name;
      await File(
        '${folder.path}${Platform.pathSeparator}$name',
      ).writeAsBytes(entry.value, flush: true);
    }
    final json = jsonEncode({
      'version': 1,
      'id': stored.id,
      'resource_key': stored.resourceKey,
      'description': stored.description,
      'idempotency_key': stored.idempotencyKey,
      'created_at': stored.createdAt.toIso8601String(),
      'type': stored.request.type,
      'payload': stored.request.payload,
      'files': fileNames,
    });
    final temp = File('${folder.path}${Platform.pathSeparator}request.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename('${folder.path}${Platform.pathSeparator}request.json');
  }

  Future<List<StoredOfflineRequest>> readAll() async {
    final root = await _rootDirectory();
    final result = <StoredOfflineRequest>[];
    final discarded = <DiscardedOfflineRequest>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final requestFile = File(
        '${entity.path}${Platform.pathSeparator}request.json',
      );
      Map<String, dynamic>? data;
      try {
        if (!await requestFile.exists()) {
          await entity.delete(recursive: true);
          continue;
        }
        final decoded = jsonDecode(await requestFile.readAsString());
        if (decoded is! Map) throw const FormatException('json inválido');
        final record = data = Map<String, dynamic>.from(decoded);
        final files = <String, Uint8List>{};
        final rawFiles = record['files'];
        if (rawFiles is Map) {
          for (final entry in rawFiles.entries) {
            final file = File(
              '${entity.path}${Platform.pathSeparator}${entry.value}',
            );
            if (!await file.exists()) {
              throw FileSystemException('anexo "${entry.key}" ausente');
            }
            files[entry.key.toString()] = await file.readAsBytes();
          }
        }
        final payload = data['payload'];
        result.add(
          StoredOfflineRequest(
            id: data['id']?.toString() ?? '',
            resourceKey: data['resource_key']?.toString() ?? '',
            description: data['description']?.toString() ?? '',
            idempotencyKey: data['idempotency_key']?.toString() ?? '',
            createdAt:
                DateTime.tryParse(data['created_at']?.toString() ?? '') ??
                DateTime.now(),
            request: PersistedOfflineRequest(
              type: data['type']?.toString() ?? '',
              payload: payload is Map
                  ? Map<String, dynamic>.from(payload)
                  : const {},
              files: files,
            ),
          ),
        );
      } catch (error) {
        // Um registro corrompido não pode travar a fila inteira, mas o
        // descarte precisa chegar à interface e ao diagnóstico.
        discarded.add(
          DiscardedOfflineRequest(
            resourceKey: data?['resource_key']?.toString() ?? '',
            description:
                data?['description']?.toString() ?? 'Alteração salva offline',
            reason: switch (error) {
              FileSystemException(:final message) => message,
              FormatException() => 'registro corrompido',
              _ => error.runtimeType.toString(),
            },
          ),
        );
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    }
    lastDiscarded = List.unmodifiable(discarded);
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result.where((item) => item.id.isNotEmpty).toList();
  }

  Future<void> delete(String id) async {
    try {
      final root = await _rootDirectory();
      final folder = Directory(
        '${root.path}${Platform.pathSeparator}${_safe(id)}',
      );
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (_) {
      // Na pior hipótese a requisição é reenviada com a mesma chave de
      // idempotência, que o backend já reconhece.
    }
  }

  Future<void> clear() async {
    try {
      final root = await _rootDirectory();
      if (await root.exists()) await root.delete(recursive: true);
      _root = null;
    } catch (_) {}
  }

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}
