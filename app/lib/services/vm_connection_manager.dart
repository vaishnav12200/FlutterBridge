import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum VMConnectionStatus { idle, connecting, connected, error }
enum VMReloadState { idle, loading, success, error }
enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;

  LogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });
}

class VMConnectionManager extends ChangeNotifier {
  static final VMConnectionManager instance = VMConnectionManager._();
  VMConnectionManager._();

  // WebSocket / Connection State
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _connTimeout;
  int _nextId = 1;

  VMConnectionStatus _status = VMConnectionStatus.idle;
  VMConnectionStatus get status => _status;

  String? _errorMsg;
  String? get errorMsg => _errorMsg;

  String? _deviceName;
  String? get deviceName => _deviceName;

  String? _dartVersion;
  String? get dartVersion => _dartVersion;

  String? _isolateId;
  String? get isolateId => _isolateId;

  String? _currentUrl;
  String? get currentUrl => _currentUrl;

  // Uptime
  Timer? _uptimeTimer;
  Duration _uptime = Duration.zero;
  Duration get uptime => _uptime;

  // Reload State
  VMReloadState _reloadState = VMReloadState.idle;
  VMReloadState get reloadState => _reloadState;

  Duration? _lastReloadDuration;
  Duration? get lastReloadDuration => _lastReloadDuration;

  DateTime? _reloadStart;
  Timer? _reloadResetTimer;

  // Logs
  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);

  // Connection management
  void connect(String url) {
    cleanup();
    _currentUrl = url;
    _status = VMConnectionStatus.connecting;
    _errorMsg = null;
    _deviceName = null;
    _dartVersion = null;
    _isolateId = null;
    _uptime = Duration.zero;
    _reloadState = VMReloadState.idle;
    _lastReloadDuration = null;
    _logs.clear();
    notifyListeners();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _setError('Invalid URL: $e');
      return;
    }

    _connTimeout = Timer(const Duration(seconds: 12), () {
      if (_status == VMConnectionStatus.connecting) {
        _setError(
          'Connection timed out.\n\nMake sure your PC and phone are on the same WiFi network.',
        );
      }
    });

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) => _setError('Connection error: $e'),
      onDone: () {
        if (_status == VMConnectionStatus.connected) {
          _setError('Connection closed by the remote end.');
        }
      },
    );

    _send('getVM');
  }

  void cleanup() {
    _connTimeout?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _uptimeTimer?.cancel();
    _reloadResetTimer?.cancel();
  }

  void disconnect() {
    cleanup();
    _status = VMConnectionStatus.idle;
    _currentUrl = null;
    notifyListeners();
  }

  void _setError(String msg) {
    _connTimeout?.cancel();
    _uptimeTimer?.cancel();
    _status = VMConnectionStatus.error;
    _errorMsg = msg;
    notifyListeners();
  }

  // Messaging
  void _send(String method, {Map<String, dynamic>? params}) {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      // ignore: use_null_aware_elements
      if (params != null) 'params': params,
    }));
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Handle stream notifications (Stdout, Stderr, Logging)
    if (msg['method'] == 'streamNotify') {
      final params = msg['params'] as Map<String, dynamic>?;
      if (params != null) {
        _handleStreamNotify(params);
      }
      return;
    }

    final result = msg['result'];

    if (result is Map<String, dynamic>) {
      // getVM handshake response
      if (result.containsKey('isolates')) {
        _connTimeout?.cancel();
        final isolates =
            (result['isolates'] as List?)?.cast<Map<String, dynamic>>();
        
        _status = VMConnectionStatus.connected;
        _deviceName = result['name']?.toString() ?? 'Flutter Device';
        _dartVersion = result['version']?.toString();
        _isolateId = isolates?.firstOrNull?['id']?.toString();
        
        _startUptime();
        _subscribeToStreams();
        notifyListeners();
        return;
      }

      // Any response while reload is in-flight = success
      if (_reloadState == VMReloadState.loading) {
        _finishReload(success: true);
        return;
      }
    }

    // JSON-RPC error while reload in-flight
    if (msg.containsKey('error') && _reloadState == VMReloadState.loading) {
      _finishReload(success: false);
    }
  }

  void _subscribeToStreams() {
    _send('streamListen', params: {'streamId': 'Stdout'});
    _send('streamListen', params: {'streamId': 'Stderr'});
    _send('streamListen', params: {'streamId': 'Logging'});
  }

  void _handleStreamNotify(Map<String, dynamic> params) {
    final streamId = params['streamId'] as String?;
    final event = params['event'] as Map<String, dynamic>?;
    if (streamId == null || event == null) return;

    if (streamId == 'Stdout' || streamId == 'Stderr') {
      final bytesBase64 = event['bytes'] as String?;
      if (bytesBase64 != null) {
        try {
          final message = utf8.decode(base64.decode(bytesBase64));
          // Avoid empty logging
          if (message.trim().isNotEmpty) {
            _addLog(
              message,
              streamId == 'Stderr' ? LogLevel.error : LogLevel.info,
              event['timestamp'] as int?,
            );
          }
        } catch (_) {}
      }
    } else if (streamId == 'Logging') {
      final logRecord = event['logRecord'] as Map<String, dynamic>?;
      if (logRecord != null) {
        final messageRef = logRecord['message'] as Map<String, dynamic>?;
        final message = messageRef?['valueAsString']?.toString() ?? '';
        final level = logRecord['level'] as int? ?? 0;
        
        LogLevel logLevel = LogLevel.info;
        if (level >= 1000) {
          logLevel = LogLevel.error;
        } else if (level >= 900) {
          logLevel = LogLevel.warning;
        } else if (level >= 500) {
          logLevel = LogLevel.debug;
        }

        if (message.trim().isNotEmpty) {
          _addLog(message, logLevel, event['timestamp'] as int?);
        }
      }
    }
  }

  void _addLog(String message, LogLevel level, int? timestampMs) {
    final time = timestampMs != null
        ? DateTime.fromMillisecondsSinceEpoch(timestampMs)
        : DateTime.now();
    _logs.add(LogEntry(timestamp: time, message: message, level: level));
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void _finishReload({required bool success}) {
    final elapsed = _reloadStart != null
        ? DateTime.now().difference(_reloadStart!)
        : null;
    _reloadStart = null;
    
    _reloadState = success ? VMReloadState.success : VMReloadState.error;
    _lastReloadDuration = elapsed;
    notifyListeners();

    _reloadResetTimer?.cancel();
    _reloadResetTimer = Timer(const Duration(seconds: 4), () {
      _reloadState = VMReloadState.idle;
      notifyListeners();
    });
  }

  void _startUptime() {
    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _uptime += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  // Reload / Restart Actions
  void hotReload() {
    if (_status != VMConnectionStatus.connected) return;
    if (_reloadState == VMReloadState.loading) return;

    _reloadState = VMReloadState.loading;
    _reloadStart = DateTime.now();
    notifyListeners();

    _send('callServiceExtension', params: {
      'isolateId': _isolateId,
      'method': 'ext.flutter.reassemble',
    });
  }

  void hotRestart() {
    if (_status != VMConnectionStatus.connected) return;
    if (_reloadState == VMReloadState.loading) return;

    _reloadState = VMReloadState.loading;
    _reloadStart = DateTime.now();
    notifyListeners();

    _send('hotRestart', params: {'isolateId': _isolateId});
  }

  @override
  void dispose() {
    cleanup();
    super.dispose();
  }
}
