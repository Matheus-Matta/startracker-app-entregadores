import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../../core/presentation/app_messages.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../app/app_dependencies.dart';
import '../../../core/async/debouncer.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/realtime/fleet_realtime_channel.dart';
import '../../orders/view/order_detail_page.dart';
import '../data/active_route_service.dart';
import '../data/wave_service.dart';
import 'delivery_completion_page.dart';
import 'pickup_page.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF77746C);

class ActiveWavePage extends StatefulWidget {
  const ActiveWavePage({required this.routeId, super.key});

  final int routeId;

  @override
  State<ActiveWavePage> createState() => _ActiveWavePageState();
}

class _ActiveWavePageState extends State<ActiveWavePage>
    with WidgetsBindingObserver {
  late final ActiveRouteService _service;
  late final WaveService _waveService;
  final _mapKey = GlobalKey<_ActiveRouteMapState>();
  ActiveRoute? _route;
  PickupProgress? _pickupProgress;
  String _mapStyle = ActiveRouteService.openFreeMapStyle;
  Position? _position;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<FleetRealtimeEvent>? _realtimeSubscription;
  StreamSubscription<OfflineQueueEvent>? _offlineQueueSubscription;
  final Debouncer _realtimeDebouncer = Debouncer(
    const Duration(milliseconds: 200),
  );
  String? _error;
  bool _loading = true;
  bool _performingAction = false;
  bool _routeRequestRunning = false;
  bool _routeReloadPending = false;
  int? _pendingPostponedStopId;
  int _locationGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final dependencies = AppDependencies.instance;
    _service = dependencies.activeRoutes;
    _waveService = dependencies.waves;
    _loadRoute();
    _loadMapStyle();
    _startLocation();
    _realtimeSubscription = FleetRealtimeChannel.instance.events.listen(
      _onRealtimeEvent,
    );
    _offlineQueueSubscription = dependencies.apiClient.offlineRequests.events
        .listen(_onOfflineQueueEvent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationGeneration++;
    _realtimeDebouncer.dispose();
    _realtimeSubscription?.cancel();
    _offlineQueueSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_positionSubscription == null) unawaited(_startLocation());
        unawaited(
          AppDependencies.instance.apiClient.offlineRequests.retryNow(),
        );
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_stopLocation());
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _loadRoute({int? postponedStopId}) async {
    if (_routeRequestRunning) {
      _routeReloadPending = true;
      _pendingPostponedStopId ??= postponedStopId;
      return;
    }
    _routeRequestRunning = true;
    try {
      var route = await _service.getRoute(widget.routeId);
      final pendingStops = route.stops.where((stop) => !stop.isTerminal).length;
      if (postponedStopId != null &&
          pendingStops > 1 &&
          route.currentStop?.stopId == postponedStopId) {
        // Alguns proxies/API gateways ainda podem entregar a primeira leitura
        // com a ordem anterior logo apos o skip. Uma segunda consulta curta,
        // tambem sem cache, evita manter o cartao no pedido adiado.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        route = await _service.getRoute(widget.routeId);
      }
      PickupProgress pickup;
      try {
        pickup = await _waveService.getPickupProgress(route.waveId);
      } on WaveServiceException {
        final pendingTransferred = route.stops
            .where((stop) => stop.orderStatus == 'awaiting_pickup')
            .length;
        pickup =
            _pickupProgress ??
            (pendingTransferred == 0
                ? PickupProgress.disabled(route.waveId)
                : PickupProgress(
                    waveId: route.waveId,
                    enabled: true,
                    barcodeSource: 'order_number',
                    total: pendingTransferred,
                    pickedUp: 0,
                    pending: pendingTransferred,
                    isComplete: false,
                    orders: const [],
                  ));
      }
      if (!mounted) return;
      setState(() {
        _route = route;
        _pickupProgress = pickup;
        _error = null;
        _loading = false;
      });
    } on ActiveRouteException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } finally {
      _routeRequestRunning = false;
      if (_routeReloadPending && mounted) {
        final pendingPostponedStopId = _pendingPostponedStopId;
        _routeReloadPending = false;
        _pendingPostponedStopId = null;
        unawaited(_loadRoute(postponedStopId: pendingPostponedStopId));
      }
    }
  }

  void _onRealtimeEvent(FleetRealtimeEvent event) {
    final route = _route;
    final affectsCurrentRoute =
        event.isRouteChange &&
        (event.routeId == null || event.routeId == widget.routeId);
    final affectsCurrentOrder =
        event.isOrderChange &&
        (event.orderId == null ||
            route == null ||
            route.stops.any((stop) => stop.orderId == event.orderId));
    if (!event.isConnected && !affectsCurrentRoute && !affectsCurrentOrder) {
      return;
    }

    // A mensagem é um sinal de invalidação. O REST continua sendo a fonte da
    // verdade para path_geometry, planned_waypoints e sequence das paradas.
    _realtimeDebouncer.run(() {
      if (mounted) unawaited(_loadRoute());
    });
  }

  void _onOfflineQueueEvent(OfflineQueueEvent event) {
    final route = _route;
    final affectsRoute = event.resourceKey == 'route:${widget.routeId}';
    final affectsStop =
        route?.stops.any(
          (stop) => event.resourceKey == 'stop:${stop.stopId}',
        ) ==
        true;
    if (!affectsRoute && !affectsStop) return;
    if (event.type == OfflineQueueEventType.rejected && mounted) {
      _message(
        'A API recusou uma alteracao salva offline. O estado foi restaurado.',
      );
    }
    if (event.type != OfflineQueueEventType.queued && mounted) {
      unawaited(_loadRoute());
    }
  }

  Future<void> _loadMapStyle() async {
    final style = await _service.getMapStyle();
    if (mounted && style != _mapStyle) setState(() => _mapStyle = style);
  }

  Future<void> _startLocation() async {
    final generation = ++_locationGeneration;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final first = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      if (!mounted || generation != _locationGeneration) return;
      setState(() => _position = first);
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((position) {
            if (mounted && generation == _locationGeneration) {
              setState(() => _position = position);
            }
          });
    } catch (_) {
      // O destino continua visível mesmo quando o GPS está indisponível.
    }
  }

  Future<void> _stopLocation() async {
    _locationGeneration++;
    final subscription = _positionSubscription;
    _positionSubscription = null;
    await subscription?.cancel();
  }

  Future<void> _runStopAction(
    Future<OfflineMutationResult<void>> Function() action, {
    String? successMessage,
    int? postponedStopId,
    ActiveRoute Function(ActiveRoute route)? optimisticUpdate,
  }) async {
    if (_performingAction) return;
    final previousRoute = _route;
    setState(() {
      _performingAction = true;
      if (previousRoute != null && optimisticUpdate != null) {
        _route = optimisticUpdate(previousRoute);
      }
    });
    try {
      final result = await action();
      if (!result.queued) {
        await _loadRoute(postponedStopId: postponedStopId);
      }
      if (mounted) {
        if (result.queued) {
          _message('Sem internet. Alteracao salva para envio automatico.');
        } else if (successMessage != null) {
          _message(successMessage);
        }
      }
    } on ActiveRouteException catch (error) {
      if (mounted) {
        setState(() => _route = previousRoute);
        _message(error.message);
        unawaited(_loadRoute());
      }
    } finally {
      if (mounted) setState(() => _performingAction = false);
    }
  }

  Future<void> _finalizeStop(ActiveRouteStop stop) async {
    if (_performingAction) return;
    final previousRoute = _route;
    setState(() {
      _performingAction = true;
      _route = _withStopStatus(stop.stopId, 'delivering');
    });
    try {
      if (stop.status != 'arrived' && stop.status != 'delivering') {
        await _service.arrive(stop.stopId);
      }
      if (stop.status != 'delivering') {
        await _service.begin(stop.stopId);
      }
    } on ActiveRouteException catch (error) {
      if (mounted) {
        setState(() => _route = previousRoute);
        _message(error.message);
        unawaited(_loadRoute());
      }
      return;
    } finally {
      if (mounted) setState(() => _performingAction = false);
    }
    if (!mounted) return;
    await _openCompletion(stop);
  }

  Future<void> _openCompletion(ActiveRouteStop stop) async {
    if (_performingAction) return;
    setState(() => _performingAction = true);
    ActiveRouteStop effectiveStop;
    try {
      effectiveStop = await _service.refreshCompletionPolicy(stop);
    } catch (_) {
      effectiveStop = stop;
    } finally {
      if (mounted) setState(() => _performingAction = false);
    }
    if (!mounted) return;
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => DeliveryCompletionPage(
          routeId: widget.routeId,
          stop: effectiveStop,
          service: _service,
        ),
      ),
    );
    if (!mounted || completed != true) return;
    setState(() => _route = _withStopStatus(stop.stopId, 'completed'));
    _message('Entrega finalizada com sucesso.');
    await _loadRoute();
  }

  Future<void> _registerFailure(ActiveRouteStop stop) async {
    final result = await showModalBottomSheet<_FailureData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _FailureSheet(requireNotes: stop.policy.requireNoteOnFailure),
    );
    if (result == null || !mounted) return;
    await _runStopAction(
      () => _service.fail(
        stopId: stop.stopId,
        reason: result.reason,
        notes: result.notes,
        latitude: _position?.latitude,
        longitude: _position?.longitude,
      ),
      optimisticUpdate: (route) => _withStopStatusIn(
        route,
        stop.stopId,
        'failed',
        orderStatus: 'delivery_failed',
      ),
    );
  }

  Future<void> _openOrder(ActiveRouteStop stop) async {
    final home = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OrderDetailPage(
          orderId: stop.orderId,
          initialNumber: stop.orderNumber,
        ),
      ),
    );
    if (!mounted) return;
    if (home == true) {
      Navigator.of(context).pop(true);
      return;
    }
    // Ao voltar para o mapa, busca novamente o path_geometry da rota.
    await _loadRoute();
  }

  Future<void> _openPickup() async {
    final progress = _pickupProgress;
    if (progress == null || !progress.enabled || progress.isComplete) return;
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PickupPage(service: _waveService, progress: progress),
      ),
    );
    if (!mounted) return;
    if (completed == true) _message('Retirada conferida. Rota atualizada.');
    await _loadRoute();
  }

  Future<void> _postponeStop(ActiveRouteStop stop) async {
    if (_performingAction) return;
    if (_route?.status != 'started') {
      _message('Inicie a rota antes de avançar para a próxima entrega.');
      return;
    }
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PostponeSheet(),
    );
    if (confirmed != true || !mounted) return;
    await _runStopAction(
      () => _service.skip(stopId: stop.stopId),
      successMessage: 'Pedido adiado. Próxima entrega carregada.',
      postponedStopId: stop.stopId,
      optimisticUpdate: (route) =>
          _withStopStatusIn(route, stop.stopId, 'skipped'),
    );
  }

  ActiveRoute? _withStopStatus(
    int stopId,
    String status, {
    String? orderStatus,
  }) {
    final route = _route;
    return route == null
        ? null
        : _withStopStatusIn(route, stopId, status, orderStatus: orderStatus);
  }

  ActiveRoute _withStopStatusIn(
    ActiveRoute route,
    int stopId,
    String status, {
    String? orderStatus,
  }) => route.copyWith(
    stops: route.stops
        .map(
          (stop) => stop.stopId == stopId
              ? stop.copyWith(status: status, orderStatus: orderStatus)
              : stop,
        )
        .toList(),
  );

  void _message(String text) {
    showAppMessage(context, text);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _cream,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_route == null) {
      return Scaffold(
        backgroundColor: _cream,
        body: _RouteError(
          message: _error ?? 'Não foi possível carregar a rota.',
          onBack: () => Navigator.of(context).pop(false),
          onRetry: () {
            setState(() => _loading = true);
            _loadRoute();
          },
        ),
      );
    }

    final route = _route!;
    final stop = route.currentStop;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _ActiveRouteMap(
            key: _mapKey,
            route: route,
            stop: stop,
            position: _position,
            style: _mapStyle,
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FloatingHeaderButton(
                    tooltip: 'Voltar',
                    icon: Icons.arrow_back_rounded,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  _FloatingHeaderButton(
                    tooltip: 'Início',
                    icon: Icons.home_rounded,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 68,
            right: 12,
            child: _MapControls(
              onRecenter: () => _mapKey.currentState?.recenter(),
              onPerspective: () => _mapKey.currentState?.togglePerspective(),
            ),
          ),
          _DeliverySheet(
            key: ValueKey<int?>(stop?.stopId),
            route: route,
            stop: stop,
            pickupProgress: _pickupProgress,
            position: _position,
            performingAction: _performingAction,
            onStart: () => _runStopAction(
              () => _service.startRoute(route.routeId),
              optimisticUpdate: (current) =>
                  current.copyWith(status: 'started'),
            ),
            onFinalize: stop == null ? null : () => _finalizeStop(stop),
            onFailure: stop == null ? null : () => _registerFailure(stop),
            onPostpone: stop == null ? null : () => _postponeStop(stop),
            onOpenOrder: stop == null ? null : () => _openOrder(stop),
            onOpenPickup: _openPickup,
          ),
        ],
      ),
    );
  }
}

class _ActiveRouteMap extends StatefulWidget {
  const _ActiveRouteMap({
    super.key,
    required this.route,
    required this.stop,
    required this.position,
    required this.style,
  });

  final ActiveRoute route;
  final ActiveRouteStop? stop;
  final Position? position;
  final String style;

  @override
  State<_ActiveRouteMap> createState() => _ActiveRouteMapState();
}

class _ActiveRouteMapState extends State<_ActiveRouteMap> {
  MapLibreMapController? _controller;
  Symbol? _driverSymbol;
  bool _styleLoaded = false;
  bool _perspective = true;

  LatLng get _initialTarget {
    final position = widget.position;
    if (position != null) return LatLng(position.latitude, position.longitude);
    final stop = widget.stop;
    if (stop?.latitude != null && stop?.longitude != null) {
      return LatLng(stop!.latitude!, stop.longitude!);
    }
    return const LatLng(-23.5505, -46.6333);
  }

  @override
  void didUpdateWidget(covariant _ActiveRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      _styleLoaded = false;
      _driverSymbol = null;
      return;
    }
    if (!_styleLoaded) return;

    final routeChanged =
        !identical(oldWidget.route.path, widget.route.path) ||
        oldWidget.stop?.stopId != widget.stop?.stopId;
    if (routeChanged) {
      unawaited(_renderRoute());
      return;
    }
    final oldPosition = oldWidget.position;
    final position = widget.position;
    if (oldPosition?.latitude != position?.latitude ||
        oldPosition?.longitude != position?.longitude ||
        oldPosition?.heading != position?.heading) {
      unawaited(_updateDriverPosition());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _renderRoute() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    final destination = _destination;
    final current = widget.position == null
        ? null
        : LatLng(widget.position!.latitude, widget.position!.longitude);
    final leg = _routeLegFromOrigin(widget.route.path, destination);
    try {
      await controller.clearLines();
      await controller.clearCircles();
      await controller.clearSymbols();
      _driverSymbol = null;
      await controller.setSymbolIconAllowOverlap(true);
      await controller.setSymbolIconIgnorePlacement(true);
      if (leg.length >= 2) {
        await controller.addLine(
          LineOptions(
            geometry: leg,
            lineColor: '#0B1320',
            lineWidth: 11,
            lineOpacity: .88,
            lineJoin: 'round',
          ),
        );
        await controller.addLine(
          LineOptions(
            geometry: leg,
            lineColor: '#3478F6',
            lineWidth: 7,
            lineOpacity: 1,
            lineJoin: 'round',
          ),
        );
      }
      if (destination != null) {
        await controller.addSymbol(
          SymbolOptions(
            geometry: destination,
            iconImage: 'startracker-delivery-marker',
            iconSize: 1.08,
            iconAnchor: 'bottom',
            zIndex: 30,
          ),
        );
      }
      final warehouse = widget.route.warehouse;
      if (warehouse != null) {
        await controller.addSymbol(
          SymbolOptions(
            geometry: LatLng(
              warehouse.coordinate.latitude,
              warehouse.coordinate.longitude,
            ),
            iconImage: 'startracker-warehouse-marker',
            iconSize: .94,
            iconAnchor: 'bottom',
            zIndex: 10,
          ),
        );
      }
      if (current != null) {
        _driverSymbol = await controller.addSymbol(
          SymbolOptions(
            geometry: current,
            iconImage: 'startracker-driver-pointer',
            iconSize: .92,
            iconAnchor: 'center',
            zIndex: 20,
          ),
        );
        await _followPosition(current);
      }
      if (current == null && destination != null) {
        await controller.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: destination,
              zoom: 16,
              tilt: _perspective ? 48 : 0,
            ),
          ),
        );
      }
    } catch (_) {
      // Uma atualização posterior de GPS tenta desenhar novamente.
    }
  }

  Future<void> _updateDriverPosition() async {
    final controller = _controller;
    final position = widget.position;
    if (controller == null || !_styleLoaded || position == null) return;
    final current = LatLng(position.latitude, position.longitude);
    try {
      final symbol = _driverSymbol;
      if (symbol == null) {
        _driverSymbol = await controller.addSymbol(
          SymbolOptions(
            geometry: current,
            iconImage: 'startracker-driver-pointer',
            iconSize: .92,
            iconAnchor: 'center',
            zIndex: 20,
          ),
        );
      } else {
        await controller.updateSymbol(symbol, SymbolOptions(geometry: current));
      }
      await _followPosition(current);
    } catch (_) {
      _driverSymbol = null;
    }
  }

  LatLng? get _destination {
    final stop = widget.stop;
    if (stop == null) return null;
    if (stop.latitude != null && stop.longitude != null) {
      return LatLng(stop.latitude!, stop.longitude!);
    }
    final waypoint = widget.route.deliveryWaypoints[stop.orderId];
    if (waypoint == null) return null;
    return LatLng(waypoint.latitude, waypoint.longitude);
  }

  Future<void> _installMarkerImages() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.addImage(
      'startracker-delivery-marker',
      await _materialMarker(
        icon: Icons.local_shipping_rounded,
        color: const Color(0xFF3478F6),
      ),
    );
    await controller.addImage(
      'startracker-warehouse-marker',
      await _materialMarker(
        icon: Icons.warehouse_rounded,
        color: const Color(0xFF171713),
      ),
    );
    await controller.addImage(
      'startracker-driver-pointer',
      await _navigationPointer(),
    );
  }

  Future<Uint8List> _navigationPointer() async {
    const size = 112.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    void paintIcon({
      required double fontSize,
      required Color color,
      List<Shadow>? shadows,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.navigation_rounded.codePoint),
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontFamily: Icons.navigation_rounded.fontFamily,
            package: Icons.navigation_rounded.fontPackage,
            shadows: shadows,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset((size - painter.width) / 2, (size - painter.height) / 2),
      );
    }

    paintIcon(
      fontSize: 94,
      color: Colors.white,
      shadows: const [
        Shadow(color: Color(0x9908172E), blurRadius: 10, offset: Offset(0, 5)),
      ],
    );
    paintIcon(fontSize: 74, color: const Color(0xFF3478F6));

    final image = await recorder.endRecording().toImage(112, 112);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _materialMarker({
    required IconData icon,
    required Color color,
  }) async {
    const size = 96.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final marker = Path()
      ..moveTo(size / 2, size - 3)
      ..cubicTo(42, 82, 13, 61, 13, 37)
      ..cubicTo(13, 17, 29, 4, size / 2, 4)
      ..cubicTo(67, 4, 83, 17, 83, 37)
      ..cubicTo(83, 61, 54, 82, size / 2, size - 3)
      ..close();
    canvas.drawShadow(marker, Colors.black54, 8, true);
    canvas.drawPath(marker, Paint()..color = color);
    canvas.drawCircle(
      const Offset(size / 2, 37),
      25,
      Paint()..color = Colors.white,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          color: color,
          fontSize: 34,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, 37 - painter.height / 2),
    );
    final image = await recorder.endRecording().toImage(96, 96);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<void> recenter() async {
    final controller = _controller;
    final position = widget.position;
    if (controller == null || position == null) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 17.2,
            tilt: _perspective ? 55 : 0,
            bearing: _navigationBearing,
          ),
        ),
      );
    } catch (_) {
      // O próximo evento de localização tenta centralizar novamente.
    }
  }

  Future<void> _followPosition(LatLng current) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: current,
          zoom: 17.2,
          tilt: _perspective ? 55 : 0,
          bearing: _navigationBearing,
        ),
      ),
      duration: const Duration(milliseconds: 650),
    );
  }

  Future<void> togglePerspective() async {
    _perspective = !_perspective;
    await recenter();
  }

  double get _navigationBearing {
    final position = widget.position;
    if (position == null) return 0;
    if (position.heading.isFinite && position.heading >= 0) {
      return position.heading;
    }
    final destination = _destination;
    if (destination == null) return 0;
    final startLat = position.latitude * math.pi / 180;
    final endLat = destination.latitude * math.pi / 180;
    final longitudeDelta =
        (destination.longitude - position.longitude) * math.pi / 180;
    final y = math.sin(longitudeDelta) * math.cos(endLat);
    final x =
        math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(longitudeDelta);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFE8E7E1),
    child: MapLibreMap(
      key: ValueKey(widget.style),
      styleString: widget.style,
      initialCameraPosition: CameraPosition(
        target: _initialTarget,
        zoom: widget.position == null ? 16 : 17.2,
        tilt: 55,
        bearing: _navigationBearing,
      ),
      compassEnabled: false,
      myLocationEnabled: false,
      attributionButtonPosition: AttributionButtonPosition.topRight,
      attributionButtonMargins: const math.Point(12, 290),
      onMapCreated: (controller) {
        _controller = controller;
        if (widget.position != null) recenter();
      },
      onStyleLoadedCallback: () {
        _styleLoaded = true;
        _installMarkerImages().then((_) => _renderRoute());
      },
    ),
  );

  List<LatLng> _routeLegFromOrigin(
    List<RouteCoordinate> path,
    LatLng? destination,
  ) {
    if (destination == null) return const [];
    if (path.isEmpty) return const [];
    final points = path
        .map((coordinate) => LatLng(coordinate.latitude, coordinate.longitude))
        .toList();
    final end = _nearestIndex(points, destination);
    return points.sublist(0, end + 1);
  }

  int _nearestIndex(List<LatLng> points, LatLng target) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < points.length; index++) {
      final lat = points[index].latitude - target.latitude;
      final lon = points[index].longitude - target.longitude;
      final distance = lat * lat + lon * lon;
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }
    return bestIndex;
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({required this.onRecenter, required this.onPerspective});

  final VoidCallback onRecenter;
  final VoidCallback onPerspective;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _MapControlButton(
        tooltip: 'Centralizar no entregador',
        icon: Icons.my_location_rounded,
        onPressed: onRecenter,
      ),
      const SizedBox(height: 10),
      _MapControlButton(
        tooltip: 'Alternar perspectiva',
        icon: Icons.threed_rotation_rounded,
        onPressed: onPerspective,
      ),
    ],
  );
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
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
      backgroundColor: Colors.white,
      foregroundColor: _ink,
      minimumSize: const Size(50, 50),
      maximumSize: const Size(50, 50),
      iconSize: 25,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      side: const BorderSide(color: Color(0x1F171713)),
      shadowColor: const Color(0x66171713),
      elevation: 6,
    ),
    icon: Icon(icon),
  );
}

class _FloatingHeaderButton extends StatelessWidget {
  const _FloatingHeaderButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      _MapControlButton(tooltip: tooltip, icon: icon, onPressed: onPressed);
}

class _DeliverySheet extends StatefulWidget {
  const _DeliverySheet({
    super.key,
    required this.route,
    required this.stop,
    required this.pickupProgress,
    required this.position,
    required this.performingAction,
    required this.onStart,
    required this.onFinalize,
    required this.onFailure,
    required this.onPostpone,
    required this.onOpenOrder,
    required this.onOpenPickup,
  });

  final ActiveRoute route;
  final ActiveRouteStop? stop;
  final PickupProgress? pickupProgress;
  final Position? position;
  final bool performingAction;
  final VoidCallback onStart;
  final VoidCallback? onFinalize;
  final VoidCallback? onFailure;
  final VoidCallback? onPostpone;
  final VoidCallback? onOpenOrder;
  final VoidCallback onOpenPickup;

  @override
  State<_DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends State<_DeliverySheet> {
  static const _closedSize = .165;
  static const _expandedSize = .84;
  final _controller = DraggableScrollableController();
  bool _expanded = false;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSizeChanged);
  }

  @override
  void didUpdateWidget(covariant _DeliverySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stop?.stopId == widget.stop?.stopId) return;
    _expanded = false;
    _showDetails = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.isAttached) {
        _controller.jumpTo(_closedSize);
      }
    });
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onSizeChanged)
      ..dispose();
    super.dispose();
  }

  void _onSizeChanged() {
    final expanded = _controller.size > .5;
    final showDetails = _controller.size > .25;
    if (expanded == _expanded && showDetails == _showDetails) return;
    setState(() {
      _expanded = expanded;
      _showDetails = showDetails;
    });
  }

  Future<void> _toggle() async {
    if (!_controller.isAttached) return;
    await _controller.animateTo(
      _expanded ? _closedSize : _expandedSize,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    controller: _controller,
    minChildSize: _closedSize,
    initialChildSize: _closedSize,
    maxChildSize: _expandedSize,
    snap: true,
    snapSizes: const [_closedSize, _expandedSize],
    builder: (context, scrollController) => Material(
      color: _cream,
      elevation: 18,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(18, 10, 18, _showDetails ? 26 : 6),
          children: [
            Center(
              child: Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFFBBB8AF),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (widget.stop == null)
              _RouteFinished(route: widget.route)
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 58,
                    height: 50,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _yellow,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${widget.stop!.sequence}',
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _distanceToCustomer,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 8,
                            height: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.stop!.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.stop!.fullAddress.isEmpty
                              ? 'Endereço não informado'
                              : widget.stop!.fullAddress,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _expanded ? 'Recolher painel' : 'Abrir painel',
                    onPressed: widget.performingAction ? null : _toggle,
                    icon: Icon(
                      _expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                    ),
                  ),
                ],
              ),
              if (_showDetails) ...[
                const SizedBox(height: 18),
                _DeliveryContentsCard(stop: widget.stop!),
                const SizedBox(height: 18),
                _PrimaryStopAction(
                  routeStatus: widget.route.status,
                  requiresPickup: widget.stop!.orderStatus == 'awaiting_pickup',
                  loading: widget.performingAction,
                  onStart: widget.onStart,
                  onFinalize: widget.onFinalize,
                  onPickup: widget.onOpenPickup,
                ),
                if (_pickupPending) ...[
                  const SizedBox(height: 10),
                  _TransferredPickupNotice(
                    progress: widget.pickupProgress!,
                    currentOrderBlocked:
                        widget.stop!.orderStatus == 'awaiting_pickup',
                    onPressed: widget.onOpenPickup,
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.performingAction
                            ? null
                            : widget.onPostpone,
                        icon: const Icon(Icons.skip_next_rounded),
                        label: const Text('Próxima'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            widget.performingAction ||
                                widget.route.status != 'started' ||
                                widget.stop!.orderStatus == 'awaiting_pickup'
                            ? null
                            : widget.onFailure,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB42318),
                          side: const BorderSide(color: Color(0xFFB42318)),
                        ),
                        icon: const Icon(Icons.report_problem_outlined),
                        label: const Text('Não entregue'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: widget.onOpenOrder,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Ver todos os dados do pedido'),
                ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  'Entregas da carga',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                ...widget.route.stops.map(
                  (item) => _StopTimelineItem(
                    stop: item,
                    active: item.stopId == widget.stop!.stopId,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    ),
  );

  String get _distanceToCustomer {
    final stop = widget.stop;
    final latitude = stop?.latitude;
    final longitude = stop?.longitude;
    if (stop == null || latitude == null || longitude == null) return '-- km';

    final destination = RouteCoordinate(latitude, longitude);
    final path = widget.route.path;
    final position = widget.position;
    if (path.isEmpty) return '-- km';

    final start = position == null
        ? 0
        : _nearestRoutePoint(
            path,
            RouteCoordinate(position.latitude, position.longitude),
          );
    final end = _nearestRoutePoint(path, destination);
    if (end < start) return '-- km';

    var meters = 0.0;
    if (position != null) {
      meters += Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        path[start].latitude,
        path[start].longitude,
      );
    }
    for (var index = start; index < end; index++) {
      meters += Geolocator.distanceBetween(
        path[index].latitude,
        path[index].longitude,
        path[index + 1].latitude,
        path[index + 1].longitude,
      );
    }
    meters += Geolocator.distanceBetween(
      path[end].latitude,
      path[end].longitude,
      latitude,
      longitude,
    );
    return _kilometers(meters);
  }

  bool get _pickupPending =>
      widget.pickupProgress?.enabled == true &&
      widget.pickupProgress?.isComplete == false;

  int _nearestRoutePoint(List<RouteCoordinate> path, RouteCoordinate target) {
    var nearest = 0;
    var shortest = double.infinity;
    for (var index = 0; index < path.length; index++) {
      final latitude = path[index].latitude - target.latitude;
      final longitude = path[index].longitude - target.longitude;
      final distance = latitude * latitude + longitude * longitude;
      if (distance < shortest) {
        shortest = distance;
        nearest = index;
      }
    }
    return nearest;
  }

  String _kilometers(double meters) =>
      '${(meters / 1000).toStringAsFixed(1)} km';
}

class _DeliveryContentsCard extends StatelessWidget {
  const _DeliveryContentsCard({required this.stop});

  final ActiveRouteStop stop;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _yellow,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.inventory_2_rounded, size: 22),
            SizedBox(width: 9),
            Text(
              'Itens da entrega',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (stop.contents.isNotEmpty)
          ...stop.contents.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Icon(Icons.circle, size: 6),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      item.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (item.volumeCount > 0)
                    Text(
                      '${item.volumeCount} vol.',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          )
        else
          Text(
            [
              '${stop.units} volume${stop.units == 1 ? '' : 's'}',
              if (stop.weightGrams > 0) _weightLabel(stop.weightGrams),
            ].join(' · '),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
          ),
        const SizedBox(height: 5),
        Text(
          'Pedido ${stop.orderNumber}',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  String _weightLabel(int grams) =>
      grams >= 1000 ? '${(grams / 1000).toStringAsFixed(1)} kg' : '$grams g';
}

class _TransferredPickupNotice extends StatelessWidget {
  const _TransferredPickupNotice({
    required this.progress,
    required this.currentOrderBlocked,
    required this.onPressed,
  });

  final PickupProgress progress;
  final bool currentOrderBlocked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE4E1D8)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0F171713),
          blurRadius: 14,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.move_to_inbox_rounded),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                currentOrderBlocked
                    ? 'Retirada obrigatória para este pedido'
                    : 'Nova retirada adicionada à rota',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '${progress.pending} pedido${progress.pending == 1 ? '' : 's'} aguardando retirada'
          '${progress.totalVolumes > 0 ? ' · ${progress.pendingVolumes} volume${progress.pendingVolumes == 1 ? '' : 's'} sem leitura' : ''}.',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text(
              'Conferir retirada',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PrimaryStopAction extends StatelessWidget {
  const _PrimaryStopAction({
    required this.routeStatus,
    required this.requiresPickup,
    required this.loading,
    required this.onStart,
    required this.onFinalize,
    required this.onPickup,
  });

  final String routeStatus;
  final bool requiresPickup;
  final bool loading;
  final VoidCallback onStart;
  final VoidCallback? onFinalize;
  final VoidCallback onPickup;

  @override
  Widget build(BuildContext context) {
    final (label, icon, callback) = requiresPickup
        ? ('Conferir retirada', Icons.qr_code_scanner_rounded, onPickup)
        : routeStatus != 'started'
        ? ('Começar a rota', Icons.play_arrow_rounded, onStart)
        : ('Finalizar entrega', Icons.check_rounded, onFinalize);
    return SizedBox(
      height: 54,
      child: FilledButton.icon(
        onPressed: loading ? null : callback,
        style: FilledButton.styleFrom(
          backgroundColor: _ink,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        ),
        icon: loading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
    );
  }
}

class _StopTimelineItem extends StatelessWidget {
  const _StopTimelineItem({required this.stop, required this.active});
  final ActiveRouteStop stop;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: active ? _yellow : Colors.white,
      borderRadius: BorderRadius.circular(15),
    ),
    child: Row(
      children: [
        Icon(
          stop.orderStatus == 'awaiting_pickup'
              ? Icons.inventory_2_outlined
              : stop.isTerminal
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked,
          size: 20,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            '${stop.sequence}. ${stop.customerName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              stop.orderNumber,
              style: const TextStyle(fontSize: 9, color: _muted),
            ),
            if (stop.isManual)
              const Text(
                'TRANSFERIDO',
                style: TextStyle(
                  fontSize: 7,
                  color: Color(0xFF8A5A00),
                  fontWeight: FontWeight.w900,
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class _RouteFinished extends StatelessWidget {
  const _RouteFinished({required this.route});
  final ActiveRoute route;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      children: [
        Container(
          width: 62,
          height: 62,
          decoration: const BoxDecoration(
            color: _yellow,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.flag_rounded, size: 32),
        ),
        const SizedBox(height: 13),
        const Text(
          'Carga finalizada',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 5),
        Text(route.routeNumber, style: const TextStyle(color: _muted)),
      ],
    ),
  );
}

class _FailureData {
  const _FailureData(this.reason, this.notes);
  final String reason;
  final String notes;
}

class _PostponeSheet extends StatelessWidget {
  const _PostponeSheet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Material(
      color: _cream,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 45,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFBBB8AF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 17),
              const Text(
                'Ir para a próxima entrega',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 5),
              const Text(
                'O pedido atual será movido para o final das entregas pendentes.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: _ink,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.skip_next_rounded),
                  label: const Text(
                    'Confirmar próxima entrega',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FailureSheet extends StatefulWidget {
  const _FailureSheet({required this.requireNotes});
  final bool requireNotes;

  @override
  State<_FailureSheet> createState() => _FailureSheetState();
}

class _FailureSheetState extends State<_FailureSheet> {
  final _notes = TextEditingController();
  String _reason = 'recipient_absent';

  static const _reasons = <String, String>{
    'recipient_absent': 'Cliente ausente',
    'Cliente recusou o pedido': 'Cliente recusou o pedido',
    'Endereço não localizado': 'Endereço não localizado',
    'other': 'Outro motivo',
  };

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  void _confirm() {
    if (widget.requireNotes && _notes.text.trim().isEmpty) {
      showAppMessage(context, 'Informe uma observação para continuar.');
      return;
    }
    Navigator.of(context).pop(_FailureData(_reason, _notes.text.trim()));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Material(
      color: _cream,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 45,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFBBB8AF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 17),
              const Text(
                'Não foi possível entregar',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _reason,
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  labelText: 'Motivo',
                  border: OutlineInputBorder(),
                ),
                items: _reasons.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _reason = value ?? _reason),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                minLines: 3,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  labelText: widget.requireNotes
                      ? 'Observação obrigatória'
                      : 'Observação',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _confirm,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                  ),
                  child: const Text(
                    'Registrar ocorrência',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RouteError extends StatelessWidget {
  const _RouteError({
    required this.message,
    required this.onBack,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Tentar novamente'),
            ),
            TextButton(onPressed: onBack, child: const Text('Voltar')),
          ],
        ),
      ),
    ),
  );
}
