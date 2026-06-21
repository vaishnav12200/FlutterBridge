import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum VMConnectionStatus {
  idle,
  connecting,
  reconnecting, // Hot restart detected, silently reconnecting
  connected,
  stopped,      // Flutter process was stopped cleanly (not an error)
  error,
}
enum VMReloadState { idle, loading, success, error }
enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;
  final bool isSeparator; // True for '--- Hot Restarted ---' dividers

  LogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
    this.isSeparator = false,
  });
}

class VMConnectionManager extends ChangeNotifier {
  static final VMConnectionManager instance = VMConnectionManager._();
  VMConnectionManager._();

  // ── VM service WebSocket ──────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _connTimeout;
  int _nextId = 1;

  // ── Control channel WebSocket (push events from CLI) ──────────────────────
  WebSocketChannel? _controlChannel;
  StreamSubscription<dynamic>? _controlSub;
  String? _controlUrl;

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

  String? _previewUrl;
  String? get previewUrl => _previewUrl;

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

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Full connect — called when the user scans a QR code.
  /// Parses previewPort and controlPort from query params.
  void connect(String url) {
    _cleanupVmChannel();
    _currentUrl = url;

    try {
      final uri = Uri.parse(url);
      final pPort = uri.queryParameters['previewPort'];
      if (pPort != null) {
        _previewUrl = 'ws://${uri.host}:$pPort';
      } else {
        _previewUrl = null;
      }

      // Connect to the CLI control channel if a controlPort is present
      final cPort = uri.queryParameters['controlPort'];
      if (cPort != null) {
        final controlUri = 'ws://${uri.host}:$cPort';
        if (controlUri != _controlUrl) {
          _connectControl(controlUri);
        }
      }
    } catch (_) {
      _previewUrl = null;
    }

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

    _openVmChannel(url);
  }

  /// Disconnect completely — clears all state including control channel.
  void disconnect() {
    _cleanupVmChannel();
    _cleanupControlChannel();
    _status = VMConnectionStatus.idle;
    _currentUrl = null;
    _previewUrl = null;
    _controlUrl = null;
    notifyListeners();
  }

  // ── VM channel management ──────────────────────────────────────────────────

  void _openVmChannel(String url) {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _setError('Invalid URL: $e');
      return;
    }

    _connTimeout = Timer(const Duration(seconds: 12), () {
      if (_status == VMConnectionStatus.connecting ||
          _status == VMConnectionStatus.reconnecting) {
        _setError(
          'Connection timed out.\n\nMake sure your PC and phone are on the same WiFi network.',
        );
      }
    });

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) => _setError('Connection error: $e'),
      onDone: () {
        // Only show an error if we haven't already received a flutter_stopped
        // notification from the control channel, and we're not in the middle
        // of a silent reconnect triggered by vm_url_changed.
        if (_status == VMConnectionStatus.connected) {
          _setError('Connection closed by the remote end.');
        }
      },
    );

    _send('getVM');
  }

  /// Silently reconnects to a new VM service URL after hot restart.
  /// Preserves logs and adds a visible separator, does NOT clear state.
  void _silentReconnect(String newUrl) {
    // Close old VM channel only — keep control channel, logs, and session alive
    _cleanupVmChannel();

    _currentUrl = newUrl;

    // Update preview URL from new URL params
    try {
      final uri = Uri.parse(newUrl);
      final pPort = uri.queryParameters['previewPort'];
      if (pPort != null) {
        _previewUrl = 'ws://${uri.host}:$pPort';
      }
    } catch (_) {}

    _status = VMConnectionStatus.reconnecting;
    _reloadState = VMReloadState.idle;

    // Add a visible separator in the log panel
    _logs.add(LogEntry(
      timestamp: DateTime.now(),
      message: '─── Hot Restarted ───',
      level: LogLevel.info,
      isSeparator: true,
    ));

    notifyListeners();

    _openVmChannel(newUrl);
  }

  void _cleanupVmChannel() {
    _connTimeout?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _uptimeTimer?.cancel();
    _reloadResetTimer?.cancel();
  }

  // ── Control channel management ─────────────────────────────────────────────

  void _connectControl(String controlWsUrl) {
    _cleanupControlChannel();
    _controlUrl = controlWsUrl;

    try {
      _controlChannel = WebSocketChannel.connect(Uri.parse(controlWsUrl));
    } catch (_) {
      return; // Control channel is best-effort, don't crash the session
    }

    _controlSub = _controlChannel!.stream.listen(
      _onControlMessage,
      onError: (_) {}, // Silently ignore control channel errors
      onDone: () {
        // Control channel closed — if Flutter is still running this is unexpected,
        // but we don't want to surface it as an error.
        _controlUrl = null;
      },
    );
  }

  void _cleanupControlChannel() {
    _controlSub?.cancel();
    _controlSub = null;
    _controlChannel?.sink.close();
    _controlChannel = null;
  }

  void _onControlMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;

    switch (type) {
      case 'vm_url_changed':
        // Hot restart: Flutter emitted a new VM service URL.
        // Silently reconnect without requiring a re-scan.
        final newUrl = msg['url'] as String?;
        if (newUrl != null && newUrl.isNotEmpty) {
          _silentReconnect(newUrl);
        }
        break;

      case 'flutter_stopped':
        // The flutter run process on the PC has exited cleanly.
        // Show a calm "stopped" state, not a scary error.
        _cleanupVmChannel();
        _status = VMConnectionStatus.stopped;
        _errorMsg = null;
        notifyListeners();
        break;

      default:
        break;
    }
  }

  // ── Messaging (VM service JSON-RPC) ───────────────────────────────────────

  void _setError(String msg) {
    _connTimeout?.cancel();
    _uptimeTimer?.cancel();
    _status = VMConnectionStatus.error;
    _errorMsg = msg;
    notifyListeners();
  }

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
      // getVM handshake response — connection established
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

  // ── Reload / Restart Actions ───────────────────────────────────────────────

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
    _cleanupVmChannel();
    _cleanupControlChannel();
    super.dispose();
  }
}
