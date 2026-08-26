import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectFleetSocket(Uri uri, String accessToken) {
  throw UnsupportedError(
    'Esta plataforma não permite enviar o header Authorization no handshake.',
  );
}
