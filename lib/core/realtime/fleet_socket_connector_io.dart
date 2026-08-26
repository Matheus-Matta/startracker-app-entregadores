import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectFleetSocket(Uri uri, String accessToken) =>
    IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
      pingInterval: const Duration(seconds: 25),
      connectTimeout: const Duration(seconds: 15),
    );
