import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../network/api_client.dart';
import '../network/api_failure.dart';
import '../network/offline_request_queue.dart';
import '../../features/waves/data/route_snapshot_store.dart';

/// Tipos de ação aceitos por `POST /api/v1/delivery/sincronizacao/`.
abstract final class SyncKind {
  static const routeStart = 'route.start';
  static const stopArrive = 'stop.arrive';
  static const stopBegin = 'stop.begin';
  static const stopPostpone = 'stop.postpone';
  static const stopComplete = 'stop.complete';
  static const stopFail = 'stop.fail';
  static const pickupScan = 'pickup.scan';
  static const pickupNotGoing = 'pickup.not_going';
}

/// Ação do entregador ainda não confirmada pelo servidor.
class PendingSyncEvent {
  const PendingSyncEvent({
    required this.id,
    required this.kind,
    required this.fields,
    required this.occurredAt,
  });

  factory PendingSyncEvent.fromQueue(QueuedRequestInfo info) {
    final fields = info.payload['fields'];
    return PendingSyncEvent(
      id: info.id,
      kind: info.payload['kind']?.toString() ?? '',
      fields: fields is Map
          ? Map<String, dynamic>.from(fields)
          : const <String, dynamic>{},
      occurredAt:
          DateTime.tryParse(info.payload['occurred_at']?.toString() ?? '') ??
          info.createdAt,
    );
  }

  final String id;
  final String kind;
  final Map<String, dynamic> fields;
  final DateTime occurredAt;

  int? intField(String name) => switch (fields[name]) {
    int value => value,
    String value => int.tryParse(value),
    _ => null,
  };

  /// Mesma ação sobre o mesmo alvo: a segunda não vira outra requisição.
  /// `null` para ações que podem se repetir (adiar a entrega).
  String? get dedupeKey => switch (kind) {
    SyncKind.routeStart => 'route:${intField('route_id')}',
    SyncKind.stopArrive || SyncKind.stopBegin => '$kind:${intField('stop_id')}',
    // Baixa e falha encerram a parada: só a primeira vale.
    SyncKind.stopComplete ||
    SyncKind.stopFail => 'close:${intField('stop_id')}',
    SyncKind.pickupScan =>
      'scan:${intField('wave_id')}:'
          '${'${fields['code']}'.toUpperCase().replaceAll(RegExp(r'\s'), '')}',
    SyncKind.pickupNotGoing =>
      'not_going:${intField('wave_id')}:${intField('order_id')}',
    _ => null,
  };

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'fields': fields,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
  };
}

/// Ação já aplicada pelo servidor, lembrada até as cópias locais trazerem
/// o resultado (ver [MobileSync.localEvents]).
class _ConfirmedEvent {
  const _ConfirmedEvent(this.event, this.confirmedAt, this.response);

  final PendingSyncEvent event;
  final DateTime confirmedAt;
  final Map<String, dynamic> response;
}

/// Resultado aplicado pelo servidor, para reconciliar a cópia local.
class SyncApplied {
  const SyncApplied({required this.event, required this.response});

  final PendingSyncEvent event;
  final Map<String, dynamic> response;

  bool get conflict => response['outcome'] == 'conflict';

  List<String> get conflicts => [
    for (final item
        in response['conflicts'] is List
            ? response['conflicts'] as List
            : const [])
      item.toString(),
  ];

  Map<String, dynamic> section(String name) => response[name] is Map
      ? Map<String, dynamic>.from(response[name] as Map)
      : const <String, dynamic>{};
}

/// Envia, uma por vez e em ordem, as ações feitas no aparelho.
///
/// Cada ação é gravada com a hora em que aconteceu (`occurred_at`) e um id
/// único; o servidor aplica uma vez só e devolve o estado atualizado.
class MobileSync {
  MobileSync(this.apiClient, {RouteSnapshotStore? confirmedStore})
    : _confirmedStore =
          confirmedStore ??
          RouteSnapshotStore(folder: 'sync_confirmed', prefix: 'events') {
    apiClient.offlineRequests
      ..registerRestoreHandler(requestType, _send)
      ..registerDeliveredHook(requestType, _remember);
    _confirmedLoad = _loadConfirmed();
  }

  /// Quanto tempo uma ação confirmada continua sobreposta às cópias.
  static const confirmedRetention = Duration(days: 2);

  final RouteSnapshotStore _confirmedStore;
  final List<_ConfirmedEvent> _confirmed = [];
  late final Future<void> _confirmedLoad;

  /// Ações a sobrepor a uma cópia lida do servidor em [fetchedAt].
  ///
  /// Inclui as pendentes e as já confirmadas **depois** daquela leitura: uma
  /// leitura que saiu antes da confirmação e chegou depois traria o estado
  /// antigo, e a tela "desfaria" a entrega. Cópia sem data recebe todas.
  List<PendingSyncEvent> localEvents({DateTime? fetchedAt}) {
    final cutoff = DateTime.now().subtract(confirmedRetention);
    _confirmed.removeWhere((item) => item.confirmedAt.isBefore(cutoff));
    return [
      for (final item in _confirmed)
        if (fetchedAt == null || item.confirmedAt.isAfter(fetchedAt))
          item.event,
      ...pending,
    ];
  }

  /// Respostas do servidor confirmadas depois de [fetchedAt], em ordem:
  /// aplicadas à cópia lida antes, ela nunca grava um estado mais velho.
  List<Map<String, dynamic>> confirmedResponses({DateTime? fetchedAt}) => [
    for (final item in _confirmed)
      if (fetchedAt == null || item.confirmedAt.isAfter(fetchedAt))
        item.response,
  ];

  /// Ações confirmadas depois de [fetchedAt] (ver [confirmedResponses]).
  List<PendingSyncEvent> confirmedEvents({DateTime? fetchedAt}) => [
    for (final item in _confirmed)
      if (fetchedAt == null || item.confirmedAt.isAfter(fetchedAt)) item.event,
  ];

  /// Aguarda a lista de confirmadas ser lida do disco (abertura do app).
  Future<void> get ready => _confirmedLoad;

  Future<void> _remember(Map<String, dynamic> payload, Object? result) async {
    await _confirmedLoad;
    final now = DateTime.now();
    // Sem isto o arquivo regravado a cada baixa crescia com ações de dias
    // atrás até alguém abrir uma tela (que é quem podava).
    final cutoff = now.subtract(confirmedRetention);
    _confirmed.removeWhere((item) => item.confirmedAt.isBefore(cutoff));
    final item = _ConfirmedEvent(
      _eventFrom(payload, now),
      now,
      _essential(result),
    );
    _confirmed.add(item);
    // Uma linha por confirmação; de tempos em tempos o registro é
    // compactado (sai o que venceu). Antes o arquivo inteiro era regravado
    // a cada confirmação: com a fila de um dia sem sinal, o envio gastava
    // ~20 s só nisso.
    if (++_logLines > max(_compactAfter, _confirmed.length * 2)) {
      await _compactConfirmed();
    } else {
      await _confirmedStore.append(0, _entry(item));
    }
  }

  /// Linhas no registro em disco (vivas + vencidas), para compactar.
  int _logLines = 0;
  static const _compactAfter = 200;

  /// Só os status: `stop_data` (comprovante com auditoria) e a conferência
  /// inteira inchavam o arquivo regravado a cada confirmação.
  static Map<String, dynamic> _essential(Object? result) {
    if (result is! Map) return const {};
    return {
      for (final key in const ['outcome', 'stop', 'order', 'route', 'wave'])
        if (result[key] != null) key: result[key],
    };
  }

  static PendingSyncEvent _eventFrom(
    Map<String, dynamic> payload,
    DateTime createdAt,
  ) => PendingSyncEvent.fromQueue(
    QueuedRequestInfo(
      id: '',
      resourceKey: '',
      description: '',
      createdAt: createdAt,
      type: requestType,
      payload: payload,
    ),
  );

  Future<void> _loadConfirmed() async {
    try {
      // Formato antigo: um JSON com a lista inteira (convertido abaixo).
      final legacy = (await _confirmedStore.read(0))?['items'];
      final legacyItems = legacy is List ? legacy : const [];
      final logged = await _confirmedStore.readLog(0);
      _logLines = logged.length;
      final cutoff = DateTime.now().subtract(confirmedRetention);
      for (final raw in [...legacyItems, ...logged].whereType<Map>()) {
        final map = Map<String, dynamic>.from(raw);
        final confirmedAt = DateTime.tryParse('${map['confirmed_at']}');
        if (confirmedAt == null || confirmedAt.isBefore(cutoff)) continue;
        final response = map['response'];
        _confirmed.add(
          _ConfirmedEvent(
            _eventFrom(map, confirmedAt),
            confirmedAt,
            response is Map ? Map<String, dynamic>.from(response) : const {},
          ),
        );
      }
      _confirmed.sort((a, b) => a.confirmedAt.compareTo(b.confirmedAt));
      if (legacyItems.isNotEmpty) {
        // Primeiro o registro novo, depois some o antigo: morrer no meio
        // só repete entradas (sobrepor duas vezes dá o mesmo resultado).
        await _compactConfirmed();
        await _confirmedStore.delete(0);
      } else if (_logLines > max(_compactAfter, _confirmed.length * 2)) {
        await _compactConfirmed();
      }
    } catch (_) {}
  }

  static Map<String, dynamic> _entry(_ConfirmedEvent item) => {
    ...item.event.toJson(),
    'confirmed_at': item.confirmedAt.toUtc().toIso8601String(),
    'response': item.response,
  };

  Future<void> _compactConfirmed() {
    _logLines = _confirmed.length;
    return _confirmedStore.rewriteLog(0, [
      for (final item in _confirmed) _entry(item),
    ]);
  }

  static const requestType = 'mobile_sync.event';
  static const endpoint = '/api/v1/delivery/sincronizacao/';
  static const _filesKey = 'file_names';

  final ApiClient apiClient;

  OfflineRequestQueue get queue => apiClient.offlineRequests;

  /// Ações pendentes, na ordem em que o entregador fez.
  List<PendingSyncEvent> get pending => [
    for (final info in queue.pendingRequests)
      if (info.type == requestType) PendingSyncEvent.fromQueue(info),
  ];

  /// Resultados aplicados pelo servidor (para atualizar as cópias locais).
  Stream<SyncApplied> get applied => queue.events
      .where(
        (event) =>
            event.type == OfflineQueueEventType.delivered &&
            event.requestType == requestType &&
            event.result is Map,
      )
      .map(
        (event) => SyncApplied(
          event: PendingSyncEvent.fromQueue(
            QueuedRequestInfo(
              id: '',
              resourceKey: event.resourceKey,
              description: event.description,
              createdAt: DateTime.now(),
              type: requestType,
              payload: event.payload,
            ),
          ),
          response: Map<String, dynamic>.from(event.result! as Map),
        ),
      );

  /// Grava a ação no aparelho e agenda o envio.
  ///
  /// [files]: `photo_0`, `photo_1`... e `signature`, com o nome do arquivo
  /// em [fileNames].
  Future<OfflineMutationResult<Map<String, dynamic>>> record({
    required String kind,
    required String resourceKey,
    required String description,
    required Map<String, dynamic> fields,
    Map<String, Uint8List> files = const {},
    Map<String, String> fileNames = const {},
    DateTime? occurredAt,
    Duration? waitFor,
  }) {
    final candidate = PendingSyncEvent(
      id: '',
      kind: kind,
      fields: fields,
      occurredAt: occurredAt ?? DateTime.now(),
    );
    if (_isDuplicate(candidate)) {
      // Toque repetido / tela reaberta: a ação já está na fila.
      return Future.value(const OfflineMutationResult.queued());
    }
    final payload = <String, dynamic>{
      'kind': kind,
      'occurred_at': (occurredAt ?? DateTime.now()).toUtc().toIso8601String(),
      'fields': fields,
      _filesKey: fileNames,
    };
    return queue.enqueue<Map<String, dynamic>>(
      resourceKey: resourceKey,
      description: description,
      persisted: PersistedOfflineRequest(
        type: requestType,
        payload: payload,
        files: files,
      ),
      operation: (eventId) async =>
          (await _send(eventId, payload, files)) as Map<String, dynamic>,
      waitFor: waitFor,
    );
  }

  /// Mesma ação, sobre o mesmo alvo, já na fila — e sem um "próxima entrega"
  /// da mesma parada depois dela (a parada volta a ficar por fazer, e a nova
  /// chegada é outra visita, que precisa ser registrada).
  bool _isDuplicate(PendingSyncEvent candidate) {
    final key = candidate.dedupeKey;
    if (key == null) return false;
    final queued = pending;
    final last = queued.lastIndexWhere((event) => event.dedupeKey == key);
    if (last < 0) return false;
    final stopId = candidate.intField('stop_id');
    return !queued
        .skip(last + 1)
        .any(
          (event) =>
              event.kind == SyncKind.stopPostpone &&
              event.intField('stop_id') == stopId,
        );
  }

  /// Logout sem nada pendente: as ações confirmadas de um entregador não
  /// ficam sobrepostas às telas do próximo.
  Future<void> clearSession() async {
    await _confirmedLoad;
    _confirmed.clear();
    _logLines = 0;
    await _confirmedStore.clear();
  }

  Future<Object?> _send(
    String eventId,
    Map<String, dynamic> payload,
    Map<String, Uint8List> files,
  ) async {
    final fields = payload['fields'] is Map
        ? Map<String, dynamic>.from(payload['fields'] as Map)
        : const <String, dynamic>{};
    final names = payload[_filesKey] is Map
        ? Map<String, dynamic>.from(payload[_filesKey] as Map)
        : const <String, dynamic>{};
    final form = FormData()
      ..fields.addAll([
        MapEntry('kind', payload['kind']?.toString() ?? ''),
        MapEntry('client_event_id', eventId),
        MapEntry('occurred_at', payload['occurred_at']?.toString() ?? ''),
        MapEntry('sent_at', DateTime.now().toUtc().toIso8601String()),
        for (final entry in fields.entries)
          // `local_*`: só para as telas do aparelho (ex.: status do pedido).
          if (entry.value != null && !entry.key.startsWith('local_'))
            MapEntry(
              entry.key,
              entry.value is Map || entry.value is List
                  ? jsonEncode(entry.value)
                  : entry.value.toString(),
            ),
      ]);
    for (final entry in files.entries) {
      final filename = names[entry.key]?.toString() ?? '${entry.key}.jpg';
      form.files.add(
        MapEntry(
          entry.key == 'signature' ? 'signature' : 'photos',
          MultipartFile.fromBytes(entry.value, filename: filename),
        ),
      );
    }
    final response = await apiClient.dio.post<dynamic>(
      endpoint,
      data: form,
      options: apiClient.offlineRequests.requestOptions(
        eventId,
        stage: _stage(payload['kind']?.toString() ?? ''),
        upload: files.isNotEmpty,
      ),
    );
    final data = response.data;
    if (data is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: const UnexpectedResponseFormat('sincronização sem objeto JSON'),
      );
    }
    return Map<String, dynamic>.from(data);
  }

  static String _stage(String kind) => switch (kind) {
    SyncKind.routeStart => 'Iniciar rota',
    SyncKind.stopArrive => 'Registrar chegada',
    SyncKind.stopBegin => 'Iniciar entrega',
    SyncKind.stopPostpone => 'Adiar entrega',
    SyncKind.stopComplete => 'Enviar baixa',
    SyncKind.stopFail => 'Registrar falha',
    SyncKind.pickupScan => 'Registrar retirada',
    SyncKind.pickupNotGoing => 'Marcar pedido que não vai',
    _ => 'Sincronizar',
  };
}
