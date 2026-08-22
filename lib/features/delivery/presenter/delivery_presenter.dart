import '../model/delivery.dart';
import 'delivery_contract.dart';

class DeliveryPresenter implements DeliveryPresenterContract {
  DeliveryPresenter(this._view);

  DeliveryView? _view;
  Delivery _delivery = const Delivery(
    id: '#ST-2048',
    customerName: 'Marina Costa',
    address: 'Av. Paulista, 1578 — São Paulo',
    status: DeliveryStatus.awaitingPickup,
  );

  @override
  void loadDelivery() => _view?.renderDelivery(_delivery);

  @override
  void advanceStatus() {
    switch (_delivery.status) {
      case DeliveryStatus.awaitingPickup:
        _delivery = _delivery.copyWith(status: DeliveryStatus.onTheWay);
        _view?.showMessage('Rota iniciada');
      case DeliveryStatus.onTheWay:
        _delivery = _delivery.copyWith(status: DeliveryStatus.delivered);
        _view?.showMessage('Entrega concluída');
      case DeliveryStatus.delivered:
        _view?.showMessage('Esta entrega já foi concluída');
    }
    _view?.renderDelivery(_delivery);
  }

  @override
  void dispose() => _view = null;
}
