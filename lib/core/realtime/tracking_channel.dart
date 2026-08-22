import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class TrackingChannel {
  WebSocketChannel? _channel;

  Stream<dynamic> connect(Uri uri) {
    _channel = WebSocketChannel.connect(uri);
    return _channel!.stream;
  }

  void sendPosition({required double latitude, required double longitude}) {
    _channel?.sink.add(
      jsonEncode({'latitude': latitude, 'longitude': longitude}),
    );
  }

  Future<void> close() async => _channel?.sink.close();
}
