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
    this.fileKeys = const [],
  });

  final String type;
  final Map<String, dynamic> payload;

  /// Bytes em memória (antes de gravar). Depois de gravados ficam só no
  /// disco, listados em [fileKeys], e são lidos na hora do envio.
  final Map<String, Uint8List> files;
  final List<String> fileKeys;

  bool get hasFiles => files.isNotEmpty || fileKeys.isNotEmpty;

  PersistedOfflineRequest withoutFiles() => PersistedOfflineRequest(
    type: type,
    payload: payload,
    fileKeys: [...fileKeys, ...files.keys],
  );
}

class StoredOfflineRequest {
  const StoredOfflineRequest({
    required this.id,
    required this.resourceKey,
    required this.description,
    required this.idempotencyKey,
    required this.createdAt,
    required this.request,
    this.owner,
    this.rejection,
  });

  final String id;
  final String resourceKey;
  final String description;
  final String idempotencyKey;
  final DateTime createdAt;
  final PersistedOfflineRequest request;

  /// `usuario:conta` de quem fez a ação (ver `SessionStorage.readIdentity`).
  final String? owner;

  /// Motivo da recusa definitiva do servidor; `null` enquanto pendente.
  final String? rejection;
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

  /// Pastas sendo gravadas agora: sem `request.json` ainda, mas não são lixo.
  final Set<String> _saving = {};

  Future<void> save(StoredOfflineRequest stored) async {
    final name = _safe(stored.id);
    _saving.add(name);
    try {
      await _save(stored, name);
    } finally {
      _saving.remove(name);
    }
  }

  Future<void> _save(StoredOfflineRequest stored, String name) async {
    final root = await _rootDirectory();
    final folder = Directory('${root.path}${Platform.pathSeparator}$name');
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
      'version': 2,
      'id': stored.id,
      'owner': ?stored.owner,
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

  /// Pastas lidas ao mesmo tempo na abertura: uma por vez, a fila de um
  /// dia sem sinal (900 ações) segurava a tela de abertura.
  static const _readBatch = 16;

  Future<List<StoredOfflineRequest>> readAll() async {
    if (_deletions.isNotEmpty) await Future.wait([..._deletions]);
    final root = await _rootDirectory();
    final result = <StoredOfflineRequest>[];
    final discarded = <DiscardedOfflineRequest>[];
    final folders = <Directory>[];
    await for (final entity in root.list()) {
      if (entity is Directory) folders.add(entity);
    }
    for (var start = 0; start < folders.length; start += _readBatch) {
      final batch = folders.skip(start).take(_readBatch);
      for (final item in await Future.wait(batch.map(_readFolder))) {
        switch (item) {
          case StoredOfflineRequest stored:
            result.add(stored);
          case DiscardedOfflineRequest lost:
            discarded.add(lost);
        }
      }
    }
    lastDiscarded = List.unmodifiable(discarded);
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result.where((item) => item.id.isNotEmpty).toList();
  }

  /// Uma ação salva: o registro, o descarte (corrompido, sem anexo) ou
  /// `null` (gravação em andamento ou interrompida).
  Future<Object?> _readFolder(Directory entity) async {
    // Ação sendo gravada agora (fotos antes do JSON): quem grava a põe na
    // fila; apagá-la como "gravação interrompida" perdia a baixa.
    final name = entity.path.split(Platform.pathSeparator).last;
    if (_saving.contains(name)) return null;
    final requestFile = File(
      '${entity.path}${Platform.pathSeparator}request.json',
    );
    Map<String, dynamic>? data;
    try {
      if (!await requestFile.exists()) {
        await entity.delete(recursive: true);
        return null;
      }
      final decoded = jsonDecode(await requestFile.readAsString());
      if (decoded is! Map) throw const FormatException('json inválido');
      final record = data = Map<String, dynamic>.from(decoded);
      final fileKeys = <String>[];
      final rawFiles = record['files'];
      if (rawFiles is Map) {
        for (final entry in rawFiles.entries) {
          final file = File(
            '${entity.path}${Platform.pathSeparator}${entry.value}',
          );
          if (!await file.exists()) {
            throw FileSystemException('anexo "${entry.key}" ausente');
          }
          fileKeys.add(entry.key.toString());
        }
      }
      final payload = record['payload'];
      return StoredOfflineRequest(
        id: record['id']?.toString() ?? '',
        resourceKey: record['resource_key']?.toString() ?? '',
        description: record['description']?.toString() ?? '',
        idempotencyKey: record['idempotency_key']?.toString() ?? '',
        createdAt:
            DateTime.tryParse(record['created_at']?.toString() ?? '') ??
            DateTime.now(),
        owner: record['owner']?.toString(),
        rejection: await _readRejection(entity),
        request: PersistedOfflineRequest(
          type: record['type']?.toString() ?? '',
          payload: payload is Map
              ? Map<String, dynamic>.from(payload)
              : const {},
          fileKeys: fileKeys,
        ),
      );
    } catch (error) {
      // Um registro corrompido não pode travar a fila inteira, mas o
      // descarte precisa chegar à interface e ao diagnóstico.
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
      return DiscardedOfflineRequest(
        resourceKey: data?['resource_key']?.toString() ?? '',
        description:
            data?['description']?.toString() ?? 'Alteração salva offline',
        reason: switch (error) {
          FileSystemException(:final message) => message,
          FormatException() => 'registro corrompido',
          _ => error.runtimeType.toString(),
        },
      );
    }
  }

  /// Anexos de um registro, lidos do disco só na hora do envio.
  Future<Map<String, Uint8List>> readFiles(String id) async {
    final folder = await _folder(id);
    final requestFile = File(
      '${folder.path}${Platform.pathSeparator}request.json',
    );
    final decoded = jsonDecode(await requestFile.readAsString());
    final rawFiles = decoded is Map ? decoded['files'] : null;
    final files = <String, Uint8List>{};
    if (rawFiles is Map) {
      for (final entry in rawFiles.entries) {
        final file = File(
          '${folder.path}${Platform.pathSeparator}${entry.value}',
        );
        if (!await file.exists()) {
          throw FileSystemException(
            'a foto/assinatura "${entry.key}" foi apagada do aparelho',
          );
        }
        files[entry.key.toString()] = await file.readAsBytes();
      }
    }
    return files;
  }

  /// Recusa definitiva: o registro (com fotos) fica guardado para o
  /// entregador ver o motivo e decidir reenviar ou descartar.
  Future<void> markRejected(String id, String reason) async {
    try {
      final folder = await _folder(id);
      if (!await folder.exists()) return;
      await File(
        '${folder.path}${Platform.pathSeparator}rejected.txt',
      ).writeAsString(reason, flush: true);
    } catch (_) {}
  }

  /// Volta o registro recusado para a fila de envio.
  Future<void> clearRejection(String id) async {
    try {
      final file = File(
        '${(await _folder(id)).path}${Platform.pathSeparator}rejected.txt',
      );
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<Directory> _folder(String id) async {
    final root = await _rootDirectory();
    return Directory('${root.path}${Platform.pathSeparator}${_safe(id)}');
  }

  static Future<String?> _readRejection(Directory folder) async {
    final file = File('${folder.path}${Platform.pathSeparator}rejected.txt');
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// Exclusões em andamento: a fila não espera por elas (o envio seguinte
  /// sai na hora), mas a releitura do disco espera, para não pegar de volta
  /// uma ação já enviada.
  final Set<Future<void>> _deletions = {};

  Future<void> delete(String id) {
    final deletion = _delete(id);
    _deletions.add(deletion);
    return deletion.whenComplete(() => _deletions.remove(deletion));
  }

  Future<void> _delete(String id) async {
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
