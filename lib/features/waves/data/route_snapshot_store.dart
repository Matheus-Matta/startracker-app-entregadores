import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Última leitura bem-sucedida de cada rota, gravada em disco.
///
/// O Android costuma encerrar o app quando a câmera abre ou ele fica em
/// segundo plano; a cópia em memória se perdia e, sem sinal, o mapa abria
/// direto na tela de erro. Com a cópia em disco o entregador continua vendo a
/// rota (com as baixas que estão na fila offline) até a rede voltar.
class RouteSnapshotStore {
  RouteSnapshotStore({
    Future<Directory> Function()? baseDirectory,
    // O entregador pode ficar dias sem sinal: a cópia precisa durar o mesmo
    // que a sessão (refresh token de 30 dias).
    this.maxAge = const Duration(days: 30),
    this.folder = 'route_snapshots',
    this.prefix = 'route',
  }) : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  /// Cópia da conferência de retirada de cada carga, para bipar sem sinal.
  factory RouteSnapshotStore.pickup({
    Future<Directory> Function()? baseDirectory,
  }) => RouteSnapshotStore(
    baseDirectory: baseDirectory,
    folder: 'pickup_snapshots',
    prefix: 'wave',
  );

  final Future<Directory> Function() _baseDirectory;
  final Duration maxAge;
  final String folder;
  final String prefix;
  Directory? _root;

  Future<Directory> _rootDirectory() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await _baseDirectory();
    final root = Directory('${base.path}${Platform.pathSeparator}$folder');
    if (!await root.exists()) await root.create(recursive: true);
    return _root = root;
  }

  Future<File> _file(int routeId) async {
    final root = await _rootDirectory();
    return File('${root.path}${Platform.pathSeparator}${prefix}_$routeId.json');
  }

  /// Gravações em andamento por arquivo. Duas gravações da mesma cópia ao
  /// mesmo tempo (leitura do servidor e confirmação de uma ação) usavam o
  /// mesmo `.tmp` e podiam se sobrescrever; agora entram em fila.
  static final Map<String, Future<void>> _writes = {};

  /// Nunca lança: falha de disco não pode atrapalhar a tela.
  Future<void> save(int routeId, Map<String, dynamic> data) async {
    final File file;
    try {
      file = await _file(routeId);
    } catch (_) {
      return;
    }
    final previous = _writes[file.path] ?? Future<void>.value();
    final write = previous.then((_) => _write(file, data));
    _writes[file.path] = write;
    await write;
    if (identical(_writes[file.path], write)) _writes.remove(file.path);
  }

  Future<void> _write(File file, Map<String, dynamic> data) async {
    try {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'data': data,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
      if (!_pruned) {
        _pruned = true;
        await _prune();
      }
    } catch (_) {}
  }

  bool _pruned = false;

  /// Apaga cópias vencidas de rotas/cargas antigas para não acumular no
  /// aparelho (antes só eram apagadas se alguém tentasse lê-las).
  Future<void> _prune() async {
    final root = await _rootDirectory();
    final limit = DateTime.now().subtract(maxAge);
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      try {
        if ((await entity.lastModified()).isBefore(limit)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  /// Devolve `null` se não houver cópia, se estiver velha demais ou corrompida.
  Future<Map<String, dynamic>?> read(int routeId) async {
    try {
      final file = await _file(routeId);
      // Lê depois da última gravação pedida, nunca a versão anterior.
      await _writes[file.path];
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final savedAt = DateTime.tryParse(decoded['saved_at']?.toString() ?? '');
      if (savedAt == null ||
          DateTime.now().toUtc().difference(savedAt) > maxAge) {
        await file.delete();
        return null;
      }
      final data = decoded['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  /// Ids das cópias salvas, da gravada mais recentemente para a mais antiga.
  Future<List<int>> savedIds() async {
    try {
      final root = await _rootDirectory();
      final pattern = RegExp(
        '^${RegExp.escape(prefix)}'
        r'_(\d+)\.json$',
      );
      final saved = <(int, DateTime)>[];
      await for (final entity in root.list()) {
        if (entity is! File) continue;
        final match = pattern.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        saved.add((int.parse(match.group(1)!), await entity.lastModified()));
      }
      saved.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final (id, _) in saved) id];
    } catch (_) {
      return const [];
    }
  }

  /// Registro só de acréscimo (`<prefix>_<id>.log`): uma linha JSON por
  /// entrada. Acrescentar custa o mesmo com 1 ou 1000 entradas; regravar o
  /// arquivo inteiro a cada uma crescia com o quadrado (e travava o envio
  /// da fila no fim de um dia sem sinal).
  Future<File> _logFile(int id) async {
    final root = await _rootDirectory();
    return File('${root.path}${Platform.pathSeparator}${prefix}_$id.log');
  }

  /// Nunca lança.
  Future<void> append(int id, Map<String, dynamic> entry) async {
    final File file;
    try {
      file = await _logFile(id);
    } catch (_) {
      return;
    }
    await _serialized(
      file.path,
      () => file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        // Sem forçar o disco (fsync, ~15 ms cada): com o app morto o
        // sistema grava do mesmo jeito; só uma queda de energia perderia a
        // última linha, e aí a cópia da rota já tem a confirmação.
      ),
    );
  }

  /// Entradas do registro; linha cortada (app morto no meio da gravação)
  /// ou corrompida é ignorada.
  Future<List<Map<String, dynamic>>> readLog(int id) async {
    try {
      final file = await _logFile(id);
      await _writes[file.path];
      if (!await file.exists()) return const [];
      final entries = <Map<String, dynamic>>[];
      for (final line in await file.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) entries.add(Map<String, dynamic>.from(decoded));
        } catch (_) {}
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// Regrava o registro só com [entries] (compactação). Nunca lança.
  Future<void> rewriteLog(int id, List<Map<String, dynamic>> entries) async {
    final File file;
    try {
      file = await _logFile(id);
    } catch (_) {
      return;
    }
    await _serialized(file.path, () async {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        entries.map((entry) => '${jsonEncode(entry)}\n').join(),
        flush: true,
      );
      await temporary.rename(file.path);
    });
  }

  /// Apaga a cópia `<prefix>_<id>.json`. Nunca lança.
  Future<void> delete(int id) async {
    try {
      final file = await _file(id);
      await _serialized(file.path, () async {
        if (await file.exists()) await file.delete();
      });
    } catch (_) {}
  }

  Future<void> _serialized(String path, Future<void> Function() action) async {
    final previous = _writes[path] ?? Future<void>.value();
    final write = previous.then((_) async {
      try {
        await action();
      } catch (_) {}
    });
    _writes[path] = write;
    await write;
    if (identical(_writes[path], write)) _writes.remove(path);
  }

  /// Logout/troca de conta: não deixa dados de outra sessão no aparelho.
  Future<void> clear() async {
    try {
      final root = await _rootDirectory();
      if (await root.exists()) await root.delete(recursive: true);
      _root = null;
    } catch (_) {}
  }
}
