import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/session_storage.dart';
import '../../orders/view/order_detail_page.dart';
import '../data/active_route_service.dart';
import 'delivery_completion_page.dart';

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

class _ActiveWavePageState extends State<ActiveWavePage> {
  late final ActiveRouteService _service;
  final _mapKey = GlobalKey<_ActiveRouteMapState>();
  ActiveRoute? _route;
  String _mapStyle = ActiveRouteService.openFreeMapStyle;
  Position? _position;
  StreamSubscription<Position>? _positionSubscription;
  String? _error;
  bool _loading = true;
  bool _performingAction = false;

  @override
  void initState() {
    super.initState();
    const storage = SessionStorage();
    _service = ActiveRouteService(
      ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
    );
    _loadRoute();
    _loadMapStyle();
    _startLocation();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadRoute() async {
    try {
      final route = await _service.getRoute(widget.routeId);
      if (!mounted) return;
      setState(() {
        _route = route;
        _error = null;
        _loading = false;
      });
    } on ActiveRouteException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadMapStyle() async {
    final style = await _service.getMapStyle();
    if (mounted && style != _mapStyle) setState(() => _mapStyle = style);
  }

  Future<void> _startLocation() async {
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
      if (mounted) setState(() => _position = first);
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((position) {
            if (mounted) setState(() => _position = position);
          });
    } catch (_) {
      // O destino continua visível mesmo quando o GPS está indisponível.
    }
  }

  Future<void> _runStopAction(Future<void> Function() action) async {
    if (_performingAction) return;
    setState(() => _performingAction = true);
    try {
      await action();
      await _loadRoute();
    } on ActiveRouteException catch (error) {
      if (mounted) _message(error.message);
    } finally {
      if (mounted) setState(() => _performingAction = false);
    }
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
        builder: (_) =>
            DeliveryCompletionPage(stop: effectiveStop, service: _service),
      ),
    );
    if (!mounted || completed != true) return;
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
    if (mounted && home == true) Navigator.of(context).pop(true);
  }

  void _explainPostpone() {
    _message(
      'A API ainda não possui a ação de adiar a parada. Nada foi alterado para evitar perder a ordem da rota.',
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
            right: 18,
            child: _MapControls(
              onRecenter: () => _mapKey.currentState?.recenter(),
              onPerspective: () => _mapKey.currentState?.togglePerspective(),
            ),
          ),
          _DeliverySheet(
            route: route,
            stop: stop,
            position: _position,
            performingAction: _performingAction,
            onStart: () =>
                _runStopAction(() => _service.startRoute(route.routeId)),
            onArrive: stop == null
                ? null
                : () => _runStopAction(() => _service.arrive(stop.stopId)),
            onBegin: stop == null
                ? null
                : () => _runStopAction(() => _service.begin(stop.stopId)),
            onComplete: stop == null ? null : () => _openCompletion(stop),
            onFailure: stop == null ? null : () => _registerFailure(stop),
            onPostpone: stop == null ? null : _explainPostpone,
            onOpenOrder: stop == null ? null : () => _openOrder(stop),
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
    if (oldWidget.style != widget.style) _styleLoaded = false;
    if (_styleLoaded) _renderRoute();
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
    final leg = _nextLeg(widget.route.path, current, destination);
    try {
      await controller.clearLines();
      await controller.clearCircles();
      await controller.clearSymbols();
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
            iconSize: .9,
            iconAnchor: 'bottom',
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
            iconSize: .88,
            iconAnchor: 'bottom',
          ),
        );
      }
      if (current != null) {
        await controller.addSymbol(
          SymbolOptions(
            geometry: current,
            iconImage: 'startracker-driver-pointer',
            iconSize: .92,
            iconAnchor: 'center',
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

  LatLng? get _destination {
    final stop = widget.stop;
    if (stop?.latitude == null || stop?.longitude == null) return null;
    return LatLng(stop!.latitude!, stop.longitude!);
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

  List<LatLng> _nextLeg(
    List<RouteCoordinate> path,
    LatLng? current,
    LatLng? destination,
  ) {
    if (destination == null) return const [];
    if (path.isEmpty) return const [];
    final points = path
        .map((coordinate) => LatLng(coordinate.latitude, coordinate.longitude))
        .toList();
    final start = current == null ? 0 : _nearestIndex(points, current);
    final end = _nearestIndex(points, destination);
    if (end < start) return const [];
    return points.sublist(start, end + 1);
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
      backgroundColor: const Color(0xE6141820),
      foregroundColor: Colors.white,
      minimumSize: const Size(50, 50),
      iconSize: 23,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      shadowColor: Colors.black54,
      elevation: 7,
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
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      minimumSize: const Size(50, 50),
      iconSize: 31,
      shadowColor: Colors.black,
      elevation: 0,
    ),
    icon: Icon(
      icon,
      shadows: const [
        Shadow(color: Colors.black87, blurRadius: 7, offset: Offset(0, 2)),
      ],
    ),
  );
}

class _DeliverySheet extends StatefulWidget {
  const _DeliverySheet({
    required this.route,
    required this.stop,
    required this.position,
    required this.performingAction,
    required this.onStart,
    required this.onArrive,
    required this.onBegin,
    required this.onComplete,
    required this.onFailure,
    required this.onPostpone,
    required this.onOpenOrder,
  });

  final ActiveRoute route;
  final ActiveRouteStop? stop;
  final Position? position;
  final bool performingAction;
  final VoidCallback onStart;
  final VoidCallback? onArrive;
  final VoidCallback? onBegin;
  final VoidCallback? onComplete;
  final VoidCallback? onFailure;
  final VoidCallback? onPostpone;
  final VoidCallback? onOpenOrder;

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
                  status: widget.stop!.status,
                  loading: widget.performingAction,
                  onStart: widget.onStart,
                  onArrive: widget.onArrive,
                  onBegin: widget.onBegin,
                  onComplete: widget.onComplete,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            widget.performingAction ||
                                widget.route.status != 'started'
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
                                widget.route.status != 'started'
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
                  'Entregas da wave',
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

class _PrimaryStopAction extends StatelessWidget {
  const _PrimaryStopAction({
    required this.routeStatus,
    required this.status,
    required this.loading,
    required this.onStart,
    required this.onArrive,
    required this.onBegin,
    required this.onComplete,
  });

  final String routeStatus;
  final String status;
  final bool loading;
  final VoidCallback onStart;
  final VoidCallback? onArrive;
  final VoidCallback? onBegin;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final (label, icon, callback) = routeStatus != 'started'
        ? ('Começar a rota', Icons.play_arrow_rounded, onStart)
        : switch (status) {
            'arrived' => (
              'Iniciar atendimento',
              Icons.play_arrow_rounded,
              onBegin,
            ),
            'delivering' => (
              'Finalizar entrega',
              Icons.check_rounded,
              onComplete,
            ),
            _ => ('Registrar chegada', Icons.location_on_rounded, onArrive),
          };
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
          stop.isTerminal
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
        Text(
          stop.orderNumber,
          style: const TextStyle(fontSize: 9, color: _muted),
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
          'Wave finalizada',
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe uma observação para continuar.')),
      );
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
