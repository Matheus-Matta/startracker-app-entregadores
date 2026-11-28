import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/offline_request_store.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';
import 'package:star_tracker/features/orders/data/order_service.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/route_snapshot_store.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

/// Servidor falso **com estado** que segue as regras do Django para a
/// sincronização (`delivery/services/mobile_sync*.py`):
/// * cada `client_event_id` é aplicado uma vez só; o reenvio devolve o mesmo
///   resultado;
/// * a baixa vale mesmo com a parada cancelada no portal (conflito);
/// * a rota fecha quando não sobra parada aberta; a carga fecha junto.
///
/// Tem rede ligável/desligável, falhas programáveis e leituras "seguráveis"
/// (para reproduzir a resposta antiga que chega depois da confirmação).
class FakeDeliveryServer implements HttpClientAdapter {
  FakeDeliveryServer({int stopCount = 2}) {
    for (var index = 1; index <= stopCount; index++) {
      stops[30 + index] = 'planned';
      orders[80 + index] = 'out_for_delivery';
    }
    pickupCodes = {
      for (var index = 1; index <= stopCount; index++)
        80 + index: {'PED-${80 + index}': null},
    };
  }

  bool online = true;

  /// "Rede zumbi": conectado, mas nada responde até este completer.
  Completer<void>? hang;

  /// Segura os envios de sincronização (para trocar a sessão no meio).
  Completer<void>? holdSync;

  /// Segura só os envios com anexo (upload lento das fotos no 4G).
  Completer<void>? holdUploads;

  /// Ids de rota (= carga) para a lista, no lugar da rota 20 única.
  List<int>? listOverride;

  /// Outras rotas do entregador na lista (id → status), além da 20.
  final Map<int, String> extraRoutes = {};

  /// Detalhe de uma das [extraRoutes] (`/rotas/<id>/`), como o servidor real.
  int? _extraRouteId(String path) {
    final match = RegExp(r'^/api/v1/delivery/rotas/(\d+)/$').firstMatch(path);
    final id = match == null ? null : int.parse(match.group(1)!);
    return extraRoutes.containsKey(id) ? id : null;
  }

  String routeStatus = 'started';
  String waveStatus = 'released';

  /// `false`: a carga ainda não tem rota (retirada em andamento), como antes
  /// de o servidor roteirizar ao fim da conferência.
  bool routeExists = true;

  /// `updated_at` da rota 20 na lista (muda quando o portal altera a rota).
  String routeUpdatedAt = '2026-11-16T08:00:00Z';

  /// Carga refeita pelo operador: a rota 20 fica substituída e esta nasce
  /// no lugar, na mesma carga 10.
  int? replacementRoute;
  final Map<int, String> stops = {};
  final Map<int, String> orders = {};

  /// Etiquetas por pedido (código → hora da leitura).
  late Map<int, Map<String, String?>> pickupCodes;
  final Set<int> notGoing = {};

  /// Eventos aplicados, em ordem, e quantas requisições chegaram por id.
  final List<Map<String, String>> applied = [];
  final Map<String, int> deliveries = {};
  final Map<String, Map<String, dynamic>> _responses = {};
  final List<String> seenPaths = [];
  int photosReceived = 0;

  /// Falhas para as próximas requisições de sincronização, em ordem.
  /// Recebem o id do evento; devolvem uma exceção, um [ResponseBody]
  /// (resposta alternativa) ou `null` para seguir normal. `applyFirst`
  /// grava antes de falhar (resposta perdida no 4G).
  final List<({Object? Function(String eventId) fault, bool applyFirst})>
  syncFaults = [];

  /// Leituras da rota ficam presas até este completer (corrida).
  Completer<void>? holdRouteReads;

  int syncRequests = 0;

  /// O aviso de situação falha (sinal caiu bem nessa hora).
  bool statusDown = false;

  /// Situações informadas pelo app (portal: Sincronização do app).
  final List<Map<String, dynamic>> statusReports = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seenPaths.add('${options.method} ${options.path}');
    if (!online) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Network is unreachable',
      );
    }
    final hanging = hang;
    if (hanging != null) await hanging.future;
    final path = options.path;
    if (path == MobileSync.endpoint) {
      final held = holdSync;
      if (held != null) await held.future;
      final uploads = holdUploads;
      final data = options.data;
      if (uploads != null && data is FormData && data.files.isNotEmpty) {
        await uploads.future;
      }
      return _sync(options);
    }
    final detail = RegExp(
      r'^/api/v1/delivery/pedidos/(\d+)/$',
    ).firstMatch(path);
    if (detail != null) {
      final id = int.parse(detail.group(1)!);
      return _json({
        'id': id,
        'order_number': 'PED-$id',
        'customer_name': 'Cliente $id',
        'status': orders[id] ?? 'out_for_delivery',
      });
    }
    if (path == '${MobileSync.endpoint}situacao/') {
      if (statusDown) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'caiu',
        );
      }
      statusReports.add(Map<String, dynamic>.from(options.data as Map));
      return _json(const {'reported_at': 'agora'});
    }
    if (!routeExists && path.startsWith('/api/v1/delivery/rotas/20/')) {
      return status(404, const {'detail': 'Não encontrado.'});
    }
    // A resposta é montada ANTES de esperar: é o estado no início da leitura.
    final Object data = switch (path) {
      '/api/v1/delivery/rotas/' ||
      '/api/v1/delivery/paradas/' when !routeExists => _page(const []),
      '/api/v1/' => const <String, dynamic>{},
      '/api/v1/delivery/rotas/20/' => {
        'id': 20,
        'wave': 10,
        'route_number': 'Rota 20',
        'status': replacementRoute != null ? 'superseded' : routeStatus,
        'path_geometry': <dynamic>[],
        'planned_waypoints': <dynamic>[],
      },
      '/api/v1/delivery/paradas/' => _page([
        for (final entry in stops.entries)
          {
            'id': entry.key,
            'route': 20,
            'order': entry.key + 50,
            'sequence': entry.key - 30,
            'status': entry.value,
            'proof': null,
          },
      ]),
      '/api/v1/delivery/pedidos/' => _page([
        for (final entry in orders.entries)
          {
            'id': entry.key,
            'order_number': 'PED-${entry.key}',
            'status': entry.value,
          },
      ]),
      '/api/v1/delivery/waves/10/retirada/' => _pickup(),
      '/api/v1/delivery/waves/10/' => {'id': 10, 'status': waveStatus},
      final detail
          when replacementRoute != null &&
              detail == '/api/v1/delivery/rotas/$replacementRoute/' =>
        {
          'id': replacementRoute,
          'wave': 10,
          'route_number': 'R$replacementRoute',
          'status': 'released',
          'path_geometry': <dynamic>[],
          'planned_waypoints': <dynamic>[],
        },
      '/api/v1/delivery/rotas/' when replacementRoute != null => _page([
        {
          'id': 20,
          'wave': 10,
          'route_number': 'Rota 20',
          'status': 'superseded',
        },
        {
          'id': replacementRoute!,
          'wave': 10,
          'route_number': 'R$replacementRoute',
          'status': 'released',
          'created_at': '2026-11-16T09:00:00Z',
        },
      ]),
      '/api/v1/delivery/rotas/' when listOverride != null => _page([
        for (final id in listOverride!)
          {'id': id, 'wave': id, 'route_number': 'R$id', 'status': 'started'},
      ]),
      '/api/v1/delivery/waves/' when listOverride != null => _page([
        for (final id in listOverride!) {'id': id, 'status': 'released'},
      ]),
      '/api/v1/delivery/rotas/' => _page([
        {
          'id': 20,
          'wave': 10,
          'route_number': 'Rota 20',
          'status': routeStatus,
          'created_at': '2026-11-16T08:00:00Z',
          'updated_at': routeUpdatedAt,
        },
        for (final entry in extraRoutes.entries)
          {
            'id': entry.key,
            'wave': entry.key,
            'route_number': 'R${entry.key}',
            'status': entry.value,
          },
      ]),
      '/api/v1/delivery/waves/' => _page([
        {'id': 10, 'status': waveStatus, 'created_at': '2026-11-16T07:00:00Z'},
      ]),
      final detail when _extraRouteId(detail) != null => {
        'id': _extraRouteId(detail),
        'wave': _extraRouteId(detail),
        'route_number': 'R${_extraRouteId(detail)}',
        'status': extraRoutes[_extraRouteId(detail)],
        'path_geometry': <dynamic>[],
        'planned_waypoints': <dynamic>[],
      },
      _ => _page(const []),
    };
    final hold = holdRouteReads;
    if (hold != null && path.startsWith('/api/v1/delivery/')) {
      await hold.future;
    }
    return _json(data);
  }

  Map<String, dynamic> _pickup() {
    final open = {
      for (final entry in pickupCodes.entries)
        if (!notGoing.contains(entry.key)) entry.key: entry.value,
    };
    final done = open.values
        .where((codes) => codes.values.every((value) => value != null))
        .length;
    return {
      'wave_id': 10,
      'pickup_enabled': true,
      'barcode_source': 'order_number',
      'total': open.length,
      'picked_up': done,
      'pending': open.length - done,
      'is_complete': open.isNotEmpty && done == open.length,
      'orders': [
        for (final entry in open.entries)
          {
            'order_id': entry.key,
            'order_number': 'PED-${entry.key}',
            'customer': 'Cliente',
            'codes': [
              for (final code in entry.value.entries)
                {'code': code.key, 'scanned_at': code.value},
            ],
            'picked_up_at': entry.value.values.every((value) => value != null)
                ? entry.value.values.first
                : null,
          },
      ],
    };
  }

  Future<ResponseBody> _sync(RequestOptions options) async {
    syncRequests++;
    final form = options.data as FormData;
    final fields = {for (final entry in form.fields) entry.key: entry.value};
    final eventId = fields['client_event_id']!;
    deliveries.update(eventId, (count) => count + 1, ifAbsent: () => 1);
    final planned = syncFaults.isEmpty ? null : syncFaults.removeAt(0);
    if (planned != null && planned.applyFirst) _apply(eventId, fields, form);
    final fault = planned?.fault(eventId);
    if (fault is Exception) throw fault;
    if (fault is ResponseBody) return fault;
    return _json(_apply(eventId, fields, form));
  }

  Map<String, dynamic> _apply(
    String eventId,
    Map<String, String> fields,
    FormData form,
  ) {
    final previous = _responses[eventId];
    if (previous != null) return {...previous, 'replayed': true};
    applied.add(fields);
    photosReceived += form.files.where((file) => file.key == 'photos').length;
    final conflicts = <String>[];
    final stopId = int.tryParse(fields['stop_id'] ?? '');
    switch (fields['kind']) {
      case SyncKind.routeStart:
        if (const {'released', 'accepted', 'planned'}.contains(routeStatus)) {
          routeStatus = 'started';
        }
      case SyncKind.stopArrive:
        if (stops[stopId] == 'planned') stops[stopId!] = 'arrived';
      case SyncKind.stopBegin:
        if (stops[stopId] == 'arrived') stops[stopId!] = 'delivering';
      case SyncKind.stopComplete || SyncKind.stopFail:
        final current = stops[stopId];
        if (current == 'cancelled') conflicts.add('parada cancelada');
        if (const {'completed', 'failed'}.contains(current)) break;
        final completed = fields['kind'] == SyncKind.stopComplete;
        stops[stopId!] = completed ? 'completed' : 'failed';
        orders[stopId + 50] = completed ? 'delivered' : 'delivery_failed';
        _closeRouteIfDone();
      case SyncKind.pickupScan:
        final code = fields['code'];
        for (final codes in pickupCodes.values) {
          if (codes.containsKey(code) && codes[code] == null) {
            codes[code!] = fields['occurred_at'];
          }
        }
      case SyncKind.pickupNotGoing:
        notGoing.add(int.parse(fields['order_id']!));
    }
    final response = <String, dynamic>{
      'client_event_id': eventId,
      'kind': fields['kind'],
      'outcome': conflicts.isEmpty ? 'applied' : 'conflict',
      'conflicts': conflicts,
      if (stopId != null) 'stop': {'id': stopId, 'status': stops[stopId]},
      if (stopId != null)
        'order': {'id': stopId + 50, 'status': orders[stopId + 50]},
      'route': {'id': 20, 'status': routeStatus},
      'wave': {'id': 10, 'status': waveStatus},
      if (fields['kind'] == SyncKind.pickupScan ||
          fields['kind'] == SyncKind.pickupNotGoing)
        'pickup': _pickup(),
    };
    _responses[eventId] = response;
    return response;
  }

  void _closeRouteIfDone() {
    if (stops.values.any(
      (status) => !const {'completed', 'failed', 'cancelled'}.contains(status),
    )) {
      return;
    }
    if (const {'cancelled', 'superseded'}.contains(routeStatus)) return;
    final all = stops.values.every((status) => status == 'completed');
    routeStatus = all ? 'completed' : 'partially_completed';
    waveStatus = orders.values.every((status) => status == 'delivered')
        ? 'completed'
        : 'partially_completed';
  }

  /// Quantas vezes cada evento chegou no servidor: tudo 1 = sem duplicata.
  int timesApplied(String kind) =>
      applied.where((fields) => fields['kind'] == kind).length;

  static Map<String, dynamic> _page(List<Object> items) => {
    'results': items,
    'next': null,
  };

  static ResponseBody _json(Object data, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  static ResponseBody status(int code, Object body) =>
      _json(body, status: code);

  @override
  void close({bool force = false}) {}
}

/// Sessão de teste com dono configurável (`usuario:conta`).
class TestSession extends SessionStorage {
  TestSession({this.identity = '1:10'});

  String? identity;
  bool loggedIn = true;

  @override
  Future<String?> readToken() async => loggedIn ? 'token-de-teste' : null;

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<String?> readIdentity() async => loggedIn ? identity : null;

  @override
  Future<Map<String, dynamic>> readDeliveryConfig() async => const {};
}

/// Um "aparelho": serviços do app com tudo gravado em [directory]. Criar
/// outro com a mesma pasta equivale a o sistema matar e reabrir o app.
class TestDevice {
  TestDevice(
    this.server,
    this.directory, {
    TestSession? session,
    RouteSnapshotStore Function(Future<Directory> Function() folder)?
    routeSnapshots,
  }) : session = session ?? TestSession() {
    Future<Directory> folder(String name) async =>
        Directory('${directory.path}${Platform.pathSeparator}$name');
    client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: this.session,
      offlineStore: OfflineRequestStore(baseDirectory: () => folder('queue')),
    )..readRetryDelays = const [];
    client.dio.httpClientAdapter = server;
    sync = MobileSync(
      client,
      confirmedStore: RouteSnapshotStore(
        baseDirectory: () => folder('confirmed'),
        folder: 'c',
        prefix: 'events',
      ),
    );
    routes = ActiveRouteService(
      client,
      storage: this.session,
      sync: sync,
      snapshotStore:
          routeSnapshots?.call(() => folder('snap')) ??
          RouteSnapshotStore(baseDirectory: () => folder('snap')),
    );
    waves = WaveService(
      client,
      sync: sync,
      pickupStore: RouteSnapshotStore.pickup(
        baseDirectory: () => folder('pickup'),
      ),
      listStore: RouteSnapshotStore(
        baseDirectory: () => folder('list'),
        folder: 'l',
        prefix: 'list',
      ),
    )..activeRoutes = routes;
    routes.startBlocker = waves.otherRouteInProgress;
    orders = OrderService(
      client,
      sync: sync,
      detailStore: RouteSnapshotStore(
        baseDirectory: () => folder('orders'),
        folder: 'o',
        prefix: 'order',
      ),
      pageStore: RouteSnapshotStore(
        baseDirectory: () => folder('order_pages'),
        folder: 'p',
        prefix: 'page',
      ),
      routeStore: RouteSnapshotStore(baseDirectory: () => folder('snap')),
    );
    waves.onOrdersFetched = orders.rememberOrders;
  }

  final FakeDeliveryServer server;
  final Directory directory;
  final TestSession session;
  late final ApiClient client;
  late final MobileSync sync;
  late final ActiveRouteService routes;
  late final WaveService waves;
  late final OrderService orders;

  /// O que o app faz ao abrir (auth_gate).
  Future<void> boot() async {
    await client.offlineRequests.restorePersisted();
    await sync.ready;
  }

  /// Envia tudo que der (como o banner "Enviar agora").
  Future<void> flush() async {
    // Como o entregador tocando "Enviar agora" até esvaziar (sem esperar
    // os intervalos do timer).
    for (var i = 0; i < 30 && client.offlineRequests.pendingCount > 0; i++) {
      await client.offlineRequests.retryNow(manual: true);
      await Future<void>.delayed(Duration.zero);
    }
    // Dá tempo aos ouvintes (cópia em disco, confirmadas) de gravarem.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  void dispose() => client.offlineRequests.dispose();
}

DeliveryProofSubmission submissionFor(ActiveRouteStop stop, {int photos = 2}) =>
    DeliveryProofSubmission(
      stop: stop,
      recipientName: 'Maria',
      recipientDocument: '',
      notes: '',
      photos: [
        for (var index = 0; index < photos; index++)
          DeliveryPhotoUpload(
            bytes: Uint8List.fromList(List.filled(2048, index)),
            filename: 'foto$index.jpg',
          ),
      ],
      signatureBytes: Uint8List.fromList([1, 2, 3]),
      latitude: null,
      longitude: null,
      itemResults: const [],
    );
