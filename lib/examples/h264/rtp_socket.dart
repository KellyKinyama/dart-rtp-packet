import 'dart:io';
import 'dart:typed_data';

class RtpSocket {
  RawDatagramSocket? _socket;

  Future<void> bind(int port) async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  }

  void send(Uint8List data, String host, int port) {
    _socket?.send(data, InternetAddress(host), port);
  }

  void listen(void Function(Uint8List data) onData) {
    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        final d = _socket?.receive();
        if (d != null) onData(d.data);
      }
    });
  }
}
