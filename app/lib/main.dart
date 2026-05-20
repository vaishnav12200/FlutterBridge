import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const BridgeApp());
}

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    return MaterialApp(
      title: 'FlutterBridge',
      theme: ThemeData(colorScheme: colorScheme, useMaterial3: true),
      home: const BridgeHome(),
    );
  }
}

enum ConnectionStatus {
  scanning,
  connecting,
  connected,
  error,
}

class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key});

  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> {
  final MobileScannerController _scannerController = MobileScannerController();
  final TextEditingController _manualController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _connectTimeout;
  ConnectionStatus _status = ConnectionStatus.scanning;
  String? _statusMessage;
  String? _lastUrl;
  String? _isolateId;
  int _nextId = 1;

  @override
  void initState() {
    super.initState();
    _statusMessage = 'Ready to scan a QR code.';
  }

  @override
  void dispose() {
    _disconnect();
    _scannerController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  void _setStatus(ConnectionStatus status, {String? message}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = status;
      _statusMessage = message;
    });
  }

  void _disconnect() {
    _connectTimeout?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isolateId = null;
  }

  void _startScanning() {
    _disconnect();
    _scannerController.start();
    _setStatus(ConnectionStatus.scanning, message: 'Ready to scan a QR code.');
  }

  void _handleBarcode(BarcodeCapture capture) {
    if (_status == ConnectionStatus.connecting || _status == ConnectionStatus.connected) {
      return;
    }

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue?.trim();
      if (rawValue != null && rawValue.isNotEmpty) {
        final normalized = _normalizeVmServiceUrl(rawValue);
        if (normalized == null) {
          _setStatus(ConnectionStatus.error, message: 'Unsupported QR code value.');
          return;
        }
        _manualController.text = normalized;
        _connect(normalized);
        return;
      }
    }
  }

  String? _normalizeVmServiceUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    Uri uri;
    if (!trimmed.contains('://')) {
      uri = Uri.parse('ws://$trimmed');
    } else {
      uri = Uri.parse(trimmed);
    }

    if (uri.scheme == 'http') {
      uri = uri.replace(scheme: 'ws');
    } else if (uri.scheme == 'https') {
      uri = uri.replace(scheme: 'wss');
    }

    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      return null;
    }

    return uri.toString();
  }

  void _connect(String url) {
    _disconnect();
    _scannerController.stop();

    _lastUrl = url;
    _setStatus(ConnectionStatus.connecting, message: 'Connecting to VM service...');

    try {
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);
    } catch (_) {
      _setStatus(ConnectionStatus.error, message: 'Invalid VM service URL.');
      return;
    }

    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (error) {
        _setStatus(ConnectionStatus.error, message: 'Connection failed: $error');
      },
      onDone: () {
        if (_status == ConnectionStatus.connected) {
          _setStatus(ConnectionStatus.error, message: 'Connection closed.');
        }
      },
    );

    _connectTimeout?.cancel();
    _connectTimeout = Timer(const Duration(seconds: 10), () {
      if (_status != ConnectionStatus.connected) {
        _setStatus(ConnectionStatus.error, message: 'Timed out waiting for VM response.');
      }
    });

    _sendRequest('getVM');
  }

  void _handleMessage(dynamic message) {
    if (message is! String) {
      return;
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final result = decoded['result'];
    if (result is Map<String, dynamic>) {
      final isolates = result['isolates'];
      if (isolates is List && isolates.isNotEmpty) {
        final isolate = isolates.first;
        if (isolate is Map<String, dynamic>) {
          _isolateId = isolate['id']?.toString();
        }
      }
    }

    if (_status != ConnectionStatus.connected) {
      _connectTimeout?.cancel();
      _setStatus(ConnectionStatus.connected, message: 'Connected to VM service.');
    }
  }

  void _sendRequest(String method, {Map<String, dynamic>? params}) {
    if (_channel == null) {
      return;
    }
    final id = _nextId++;
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
    };
    if (params != null) {
      payload['params'] = params;
    }
    _channel!.sink.add(jsonEncode(payload));
  }

  void _triggerHotReload() {
    if (_status != ConnectionStatus.connected || _isolateId == null) {
      _setStatus(ConnectionStatus.error, message: 'No isolate available for reload.');
      return;
    }

    _sendRequest('callServiceExtension', params: {
      'isolateId': _isolateId,
      'method': 'ext.flutter.reassemble',
    });
    _setStatus(ConnectionStatus.connected, message: 'Hot reload requested.');
  }

  Color _statusColor(BuildContext context) {
    switch (_status) {
      case ConnectionStatus.scanning:
        return Theme.of(context).colorScheme.primary;
      case ConnectionStatus.connecting:
        return Colors.orange;
      case ConnectionStatus.connected:
        return Colors.green;
      case ConnectionStatus.error:
        return Colors.redAccent;
    }
  }

  String _statusLabel() {
    switch (_status) {
      case ConnectionStatus.scanning:
        return 'Scanning';
      case ConnectionStatus.connecting:
        return 'Connecting';
      case ConnectionStatus.connected:
        return 'Connected';
      case ConnectionStatus.error:
        return 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canHotReload = _status == ConnectionStatus.connected && _isolateId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FlutterBridge'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _handleBarcode,
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  top: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Point the camera at the FlutterBridge QR code',
                      style: TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceVariant,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _statusColor(context),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _statusLabel(),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_statusMessage!),
                ],
                if (_lastUrl != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _lastUrl!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _manualController,
                  decoration: const InputDecoration(
                    labelText: 'VM service URL (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final url = _normalizeVmServiceUrl(_manualController.text);
                          if (url == null) {
                            _setStatus(ConnectionStatus.error, message: 'Enter a valid VM service URL.');
                            return;
                          }
                          _connect(url);
                        },
                        child: const Text('Connect'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _startScanning,
                        child: const Text('Scan Again'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: canHotReload ? _triggerHotReload : null,
                  icon: const Icon(Icons.flash_on),
                  label: const Text('Hot Reload'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
