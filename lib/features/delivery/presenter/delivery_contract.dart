import '../model/delivery.dart';

abstract interface class DeliveryView {
  void renderDelivery(Delivery delivery);
  void showMessage(String message);
}

abstract interface class DeliveryPresenterContract {
  void loadDelivery();
  void advanceStatus();
  void dispose();
}
