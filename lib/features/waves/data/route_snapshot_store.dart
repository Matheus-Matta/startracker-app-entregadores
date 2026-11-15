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
    this.maxAge = const Duration(hours: 48),
  }) : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDirectory;
  final Duration maxAge;
  Directory? _root;

  Future<Directory> _rootDirectory() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await _baseDirectory();
    final root = Directory(
      '${base.path}${Platform.pathSeparator}route_snapshots',
    );
    if (!await root.exists()) await root.create(recursive: true);
    return _root = root;
  }

  Future<File> _file(int routeId) async {
    final root = await _rootDirectory();
    return File('${root.path}${Platform.pathSeparator}route_$routeId.json');
  }

  /// Nunca lança: falha de disco não pode atrapalhar a tela.
  Future<void> save(int routeId, Map<String, dynamic> data) async {
    try {
      final file = await _file(routeId);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'data': data,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (_) {}
  }

  /// Devolve `null` se não houver cópia, se estiver velha demais ou corrompida.
  Future<Map<String, dynamic>?> read(int routeId) async {
    try {
      final file = await _file(routeId);
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

  /// Logout/troca de conta: não deixa dados de outra sessão no aparelho.
  Future<void> clear() async {
    try {
      final root = await _rootDirectory();
      if (await root.exists()) await root.delete(recursive: true);
      _root = null;
    } catch (_) {}
  }
}
