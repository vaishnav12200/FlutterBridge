import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// State enums
// ─────────────────────────────────────────────────────────────────────────────

enum _ConnStatus { idle, connecting, connected, error }

enum _ReloadState { idle, loading, success, error }

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  /// VM service URL detected from QR or manual input.
  final String? vmServiceUrl;

  /// Navigate the shell back to the Scanner tab.
  final VoidCallback? onScanAgain;

  const HomeScreen({super.key, this.vmServiceUrl, this.onScanAgain});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ── WebSocket ─────────────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _connTimeout;
  int _nextId = 1;

  // ── Connection state ──────────────────────────────────────────────────────
  _ConnStatus _status = _ConnStatus.idle;
  String? _errorMsg;
  String? _deviceName;
  String? _dartVersion;
  String? _isolateId;

  // ── Uptime ────────────────────────────────────────────────────────────────
  Timer? _uptimeTimer;
  Duration _uptime = Duration.zero;

  // ── Reload state ──────────────────────────────────────────────────────────
  _ReloadState _reloadState = _ReloadState.idle;
  Duration? _lastReloadDuration;
  DateTime? _reloadStart;
  Timer? _reloadResetTimer;

  // ── Animations ────────────────────────────────────────────────────────────
  late final AnimationController _glowCtrl;
  late final AnimationController _shimmerCtrl;

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    if (widget.vmServiceUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _connect(widget.vmServiceUrl!),
      );
    }
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (widget.vmServiceUrl != old.vmServiceUrl &&
        widget.vmServiceUrl != null) {
      _connect(widget.vmServiceUrl!);
    }
  }

  @override
  void dispose() {
    _cleanup();
    _glowCtrl.dispose();
    _shimmerCtrl.dispose();
    _uptimeTimer?.cancel();
    _reloadResetTimer?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connection management
  // ─────────────────────────────────────────────────────────────────────────

  void _connect(String url) {
    _cleanup();
    setState(() {
      _status = _ConnStatus.connecting;
      _errorMsg = null;
      _deviceName = null;
      _dartVersion = null;
      _isolateId = null;
      _uptime = Duration.zero;
      _reloadState = _ReloadState.idle;
      _lastReloadDuration = null;
    });

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _setError('Invalid URL: $e');
      return;
    }

    _connTimeout = Timer(const Duration(seconds: 12), () {
      if (mounted && _status == _ConnStatus.connecting) {
        _setError(
          'Connection timed out.\n\nMake sure your PC and phone are on the same WiFi network.',
        );
      }
    });

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) => _setError('Connection error: $e'),
      onDone: () {
        if (mounted && _status == _ConnStatus.connected) {
          _setError('Connection closed by the remote end.');
        }
      },
    );

    _send('getVM');
  }

  void _cleanup() {
    _connTimeout?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _uptimeTimer?.cancel();
  }

  void _disconnect() {
    _cleanup();
    if (mounted) setState(() => _status = _ConnStatus.idle);
  }

  void _setError(String msg) {
    _connTimeout?.cancel();
    _uptimeTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _status = _ConnStatus.error;
      _errorMsg = msg;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Messaging
  // ─────────────────────────────────────────────────────────────────────────

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

    final result = msg['result'];

    if (result is Map<String, dynamic>) {
      // getVM handshake response
      if (result.containsKey('isolates')) {
        _connTimeout?.cancel();
        final isolates =
            (result['isolates'] as List?)?.cast<Map<String, dynamic>>();
        if (!mounted) return;
        setState(() {
          _status = _ConnStatus.connected;
          _deviceName = result['name']?.toString() ?? 'Flutter Device';
          _dartVersion = result['version']?.toString();
          _isolateId = isolates?.firstOrNull?['id']?.toString();
        });
        _startUptime();
        return;
      }

      // Any response while reload is in-flight = success
      if (_reloadState == _ReloadState.loading) {
        _finishReload(success: true);
        return;
      }
    }

    // JSON-RPC error while reload in-flight
    if (msg.containsKey('error') && _reloadState == _ReloadState.loading) {
      _finishReload(success: false);
    }
  }

  void _finishReload({required bool success}) {
    final elapsed = _reloadStart != null
        ? DateTime.now().difference(_reloadStart!)
        : null;
    _reloadStart = null;
    if (!mounted) return;
    setState(() {
      _reloadState = success ? _ReloadState.success : _ReloadState.error;
      _lastReloadDuration = elapsed;
    });
    _reloadResetTimer?.cancel();
    _reloadResetTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _reloadState = _ReloadState.idle);
    });
  }

  void _startUptime() {
    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _uptime += const Duration(seconds: 1));
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Actions
  // ─────────────────────────────────────────────────────────────────────────

  void _hotReload() {
    if (_status != _ConnStatus.connected) return;
    if (_reloadState == _ReloadState.loading) return;
    setState(() {
      _reloadState = _ReloadState.loading;
      _reloadStart = DateTime.now();
    });
    _send('callServiceExtension', params: {
      'isolateId': _isolateId,
      'method': 'ext.flutter.reassemble',
    });
  }

  void _hotRestart() {
    if (_status != _ConnStatus.connected) return;
    if (_reloadState == _ReloadState.loading) return;
    setState(() {
      _reloadState = _ReloadState.loading;
      _reloadStart = DateTime.now();
    });
    _send('hotRestart', params: {'isolateId': _isolateId});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 380),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: _buildBody(),
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6B8AF7), AppColors.accent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.developer_board_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Home',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
      actions: [
        if (_status == _ConnStatus.connected) ...[
          IconButton(
            icon: const Icon(Icons.link_off_rounded),
            tooltip: 'Disconnect',
            onPressed: _disconnect,
          ),
        ],
        const SizedBox(width: 4),
      ],
    );
  }

  // ── Body router ───────────────────────────────────────────────────────────

  Widget _buildBody() {
    return switch (_status) {
      _ConnStatus.idle => _IdleView(
          key: const ValueKey('idle'),
          onScanAgain: widget.onScanAgain,
        ),
      _ConnStatus.connecting => _ConnectingView(
          key: const ValueKey('connecting'),
          url: widget.vmServiceUrl ?? '',
        ),
      _ConnStatus.connected => _ConnectedView(
          key: const ValueKey('connected'),
          deviceName: _deviceName ?? 'Flutter Device',
          dartVersion: _dartVersion,
          isolateId: _isolateId,
          uptime: _uptime,
          reloadState: _reloadState,
          lastReloadDuration: _lastReloadDuration,
          shimmerCtrl: _shimmerCtrl,
          glowCtrl: _glowCtrl,
          onHotReload: _hotReload,
          onHotRestart: _hotRestart,
          onDisconnect: _disconnect,
        ),
      _ConnStatus.error => _ErrorView(
          key: const ValueKey('error'),
          message: _errorMsg ?? 'Unknown error',
          url: widget.vmServiceUrl,
          onRetry: widget.vmServiceUrl != null
              ? () => _connect(widget.vmServiceUrl!)
              : null,
          onScanAgain: widget.onScanAgain,
        ),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View: Idle (no device connected)
// ─────────────────────────────────────────────────────────────────────────────

class _IdleView extends StatelessWidget {
  final VoidCallback? onScanAgain;
  const _IdleView({super.key, this.onScanAgain});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        children: [
          // Illustration
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: 1.5),
            ),
            child: const Icon(
              Icons.wifi_off_rounded,
              size: 44,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Device Connected',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Scan the QR code generated by FlutterBridge CLI to wirelessly connect to your running Flutter app.',
            style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Scan button
          _GradientButton(
            label: 'Scan QR Code',
            icon: Icons.qr_code_scanner_rounded,
            onPressed: onScanAgain ?? () {},
          ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),

          // Step list
          Text(
            'HOW TO CONNECT',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          _StepCard(
            number: '01',
            title: 'Run FlutterBridge CLI',
            subtitle: 'npx @vaishnavkm/flutterbridge',
            icon: Icons.terminal_rounded,
          ),
          const SizedBox(height: 10),
          _StepCard(
            number: '02',
            title: 'A QR code appears',
            subtitle: 'in your terminal window',
            icon: Icons.qr_code_2_rounded,
          ),
          const SizedBox(height: 10),
          _StepCard(
            number: '03',
            title: 'Scan it here',
            subtitle: 'Tap "Scan QR Code" above',
            icon: Icons.phone_android_rounded,
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final String number;
  final String title;
  final String subtitle;
  final IconData icon;

  const _StepCard({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                number,
                style: GoogleFonts.inter(
                  color: AppColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(icon, color: AppColors.textMuted, size: 20),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View: Connecting
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectingView extends StatefulWidget {
  final String url;
  const _ConnectingView({super.key, required this.url});

  @override
  State<_ConnectingView> createState() => _ConnectingViewState();
}

class _ConnectingViewState extends State<_ConnectingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Spinning ring
            AnimatedBuilder(
              animation: _rotCtrl,
              builder: (ctx, child) => Transform.rotate(
                angle: _rotCtrl.value * 2 * math.pi,
                child: child,
              ),
              child: SizedBox(
                width: 80,
                height: 80,
                child: CustomPaint(painter: _SpinnerPainter()),
              ),
            ),
            const SizedBox(height: 8),
            // WiFi icon in centre (no rotation)
            Transform.translate(
              offset: const Offset(0, -56),
              child: const Icon(
                Icons.wifi_rounded,
                color: AppColors.accent,
                size: 28,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Connecting...',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Establishing VM service connection',
              style: GoogleFonts.inter(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded,
                      size: 14, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.url,
                      style: GoogleFonts.robotoMono(
                        color: AppColors.accent,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          AppColors.accent.withValues(alpha: 0.0),
          AppColors.accent,
        ],
      ).createShader(rect);
    canvas.drawArc(rect, 0, math.pi * 1.7, false, paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// View: Connected
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectedView extends StatelessWidget {
  final String deviceName;
  final String? dartVersion;
  final String? isolateId;
  final Duration uptime;
  final _ReloadState reloadState;
  final Duration? lastReloadDuration;
  final AnimationController shimmerCtrl;
  final AnimationController glowCtrl;
  final VoidCallback onHotReload;
  final VoidCallback onHotRestart;
  final VoidCallback onDisconnect;

  const _ConnectedView({
    super.key,
    required this.deviceName,
    this.dartVersion,
    this.isolateId,
    required this.uptime,
    required this.reloadState,
    this.lastReloadDuration,
    required this.shimmerCtrl,
    required this.glowCtrl,
    required this.onHotReload,
    required this.onHotRestart,
    required this.onDisconnect,
  });

  String _formatUptime(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m ${d.inSeconds.remainder(60)}s';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final canReload = isolateId != null && reloadState != _ReloadState.loading;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 1. Status card ──────────────────────────────────────────────
          _buildStatusCard(),
          const SizedBox(height: 16),

          // ── 2. Live preview ─────────────────────────────────────────────
          _LivePreviewCard(shimmerCtrl: shimmerCtrl),
          const SizedBox(height: 16),

          // ── 3. Hot Reload + Hot Restart ─────────────────────────────────
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _HotReloadButton(
                  loading: reloadState == _ReloadState.loading,
                  enabled: canReload,
                  onPressed: onHotReload,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _HotRestartButton(
                  enabled: canReload,
                  onPressed: onHotRestart,
                ),
              ),
            ],
          ),

          // ── 4. Reload status chip ───────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: reloadState != _ReloadState.idle
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ReloadStatusChip(
                      state: reloadState,
                      duration: lastReloadDuration,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ── 5. Connection info card ─────────────────────────────────────
          _buildInfoCard(),
        ],
      ),
    );
  }

  // ── Status card ───────────────────────────────────────────────────────────

  Widget _buildStatusCard() {
    return AnimatedBuilder(
      animation: glowCtrl,
      builder: (ctx, child) {
        final g = glowCtrl.value;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.successDim,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.success.withValues(alpha: 0.35)),
            boxShadow: [
              BoxShadow(
                color:
                    AppColors.success.withValues(alpha: 0.06 + 0.1 * g),
                blurRadius: 16 + 8 * g,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Row(
        children: [
          // Pulsing dot
          AnimatedBuilder(
            animation: glowCtrl,
            builder: (ctx, _) => Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.success.withValues(
                        alpha: 0.4 + 0.4 * glowCtrl.value),
                    blurRadius: 6 + 4 * glowCtrl.value,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Connected',
                      style: GoogleFonts.inter(
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'LIVE',
                        style: GoogleFonts.inter(
                          color: AppColors.success,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  deviceName,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'UPTIME',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 9,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                _formatUptime(uptime),
                style: GoogleFonts.robotoMono(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Info card ─────────────────────────────────────────────────────────────

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CONNECTION INFO',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 10),
          if (dartVersion != null) ...[
            _InfoRow(
              icon: Icons.code_rounded,
              label: 'Dart SDK',
              value: dartVersion!,
            ),
            const SizedBox(height: 8),
          ],
          _InfoRow(
            icon: Icons.memory_rounded,
            label: 'Isolate ID',
            value: isolateId != null
                ? '${isolateId!.substring(0, math.min(20, isolateId!.length))}…'
                : 'Unknown',
          ),
          const SizedBox(height: 8),
          _InfoRow(
            icon: Icons.timer_outlined,
            label: 'Session time',
            value: _formatUptime(uptime),
          ),
        ],
      ),
    );
  }
}

// ── Info row ──────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.inter(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            style: GoogleFonts.robotoMono(
              color: AppColors.textPrimary,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live Preview Card
// ─────────────────────────────────────────────────────────────────────────────

class _LivePreviewCard extends StatelessWidget {
  final AnimationController shimmerCtrl;
  const _LivePreviewCard({required this.shimmerCtrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.preview_rounded,
                  size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                'Live Preview',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.warningDim,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  'Phase 4',
                  style: GoogleFonts.inter(
                    color: AppColors.warning,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Phone frame + shimmer
          Center(
            child: SizedBox(
              width: 160,
              height: 290,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: AppColors.border, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Notch
                    const SizedBox(height: 12),
                    Container(
                      width: 48,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Screen area with shimmer
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AnimatedBuilder(
                            animation: shimmerCtrl,
                            builder: (ctx, _) {
                              final pos =
                                  -1.0 + 3.0 * shimmerCtrl.value;
                              return Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment(pos - 1, -0.3),
                                    end: Alignment(pos, 0.3),
                                    colors: const [
                                      Color(0xFF1A1D2E),
                                      Color(0xFF242736),
                                      Color(0xFF2D3148),
                                      Color(0xFF242736),
                                      Color(0xFF1A1D2E),
                                    ],
                                    stops: const [
                                      0.0,
                                      0.2,
                                      0.5,
                                      0.8,
                                      1.0
                                    ],
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.phone_android_rounded,
                                      size: 36,
                                      color: AppColors.textMuted
                                          .withValues(alpha: 0.3),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Live Preview',
                                      style: GoogleFonts.inter(
                                        color: AppColors.textMuted
                                            .withValues(alpha: 0.5),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),

                    // Home bar
                    const SizedBox(height: 10),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Caption
          Text(
            'Screen streaming via ADB will be available in Phase 4',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hot Reload Button
// ─────────────────────────────────────────────────────────────────────────────

class _HotReloadButton extends StatefulWidget {
  final bool loading;
  final bool enabled;
  final VoidCallback onPressed;

  const _HotReloadButton({
    required this.loading,
    required this.enabled,
    required this.onPressed,
  });

  @override
  State<_HotReloadButton> createState() => _HotReloadButtonState();
}

class _HotReloadButtonState extends State<_HotReloadButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !widget.loading;

    return GestureDetector(
      onTapDown: active ? (_) => setState(() => _pressed = true) : null,
      onTapUp: active
          ? (_) {
              setState(() => _pressed = false);
              widget.onPressed();
            }
          : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        height: 50,
        decoration: BoxDecoration(
          gradient: active
              ? LinearGradient(
                  colors: _pressed
                      ? [const Color(0xFF3D56D6), const Color(0xFF3D5BD4)]
                      : [const Color(0xFF6B8AF7), AppColors.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: active ? null : AppColors.surface2,
          borderRadius: BorderRadius.circular(12),
          boxShadow: (active && !_pressed)
              ? [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
          border: active
              ? null
              : Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            else
              Icon(
                Icons.bolt_rounded,
                color: active ? Colors.white : AppColors.textMuted,
                size: 20,
              ),
            const SizedBox(width: 8),
            Text(
              widget.loading ? 'Reloading...' : '⚡ Hot Reload',
              style: GoogleFonts.inter(
                color: active ? Colors.white : AppColors.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hot Restart Button
// ─────────────────────────────────────────────────────────────────────────────

class _HotRestartButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onPressed;

  const _HotRestartButton({required this.enabled, required this.onPressed});

  @override
  State<_HotRestartButton> createState() => _HotRestartButtonState();
}

class _HotRestartButtonState extends State<_HotRestartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    super.dispose();
  }

  void _handlePress() {
    _rotCtrl.forward(from: 0);
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.enabled ? _handlePress : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        height: 50,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.enabled ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _rotCtrl,
              builder: (ctx, child) => Transform.rotate(
                angle: _rotCtrl.value * 2 * math.pi,
                child: child,
              ),
              child: Icon(
                Icons.restart_alt_rounded,
                size: 18,
                color: widget.enabled ? AppColors.accent : AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Restart',
              style: GoogleFonts.inter(
                color: widget.enabled ? AppColors.accent : AppColors.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reload status chip
// ─────────────────────────────────────────────────────────────────────────────

class _ReloadStatusChip extends StatelessWidget {
  final _ReloadState state;
  final Duration? duration;

  const _ReloadStatusChip({required this.state, this.duration});

  @override
  Widget build(BuildContext context) {
    final (color, bgColor, icon, label) = switch (state) {
      _ReloadState.loading => (
          AppColors.accent,
          AppColors.accentDim,
          Icons.hourglass_top_rounded,
          'Reloading app...',
        ),
      _ReloadState.success => (
          AppColors.success,
          AppColors.successDim,
          Icons.check_circle_rounded,
          duration != null
              ? 'Hot reload in ${duration!.inMilliseconds}ms ✓'
              : 'Hot reload successful',
        ),
      _ReloadState.error => (
          AppColors.error,
          AppColors.errorDim,
          Icons.error_rounded,
          'Hot reload failed',
        ),
      _ReloadState.idle => (
          AppColors.textMuted,
          AppColors.surface,
          Icons.info_outline,
          '',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Text(
            label,
            style: GoogleFonts.inter(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// View: Error
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String message;
  final String? url;
  final VoidCallback? onRetry;
  final VoidCallback? onScanAgain;

  const _ErrorView({
    super.key,
    required this.message,
    this.url,
    this.onRetry,
    this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 32),

          // Error icon
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: AppColors.errorDim,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi_off_rounded,
                color: AppColors.error, size: 40),
          ),
          const SizedBox(height: 24),

          Text(
            'Connection Failed',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),

          // Error message
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              message,
              style: GoogleFonts.inter(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          // URL chip
          if (url != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                url!,
                style: GoogleFonts.robotoMono(
                    color: AppColors.textMuted, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Troubleshooting card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.accentGlow,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Troubleshooting',
                  style: GoogleFonts.inter(
                    color: AppColors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                for (final tip in [
                  'PC and phone on the same WiFi',
                  'FlutterBridge CLI is still running',
                  'Try disabling firewall temporarily',
                  'QR code may have expired — rescan',
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.arrow_right_rounded,
                            size: 16, color: AppColors.accent),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            tip,
                            style: GoogleFonts.inter(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Retry button
          if (onRetry != null) ...[
            _GradientButton(
              label: 'Retry Connection',
              icon: Icons.refresh_rounded,
              onPressed: onRetry!,
            ),
            const SizedBox(height: 12),
          ],

          // Scan again
          if (onScanAgain != null)
            OutlinedButton.icon(
              onPressed: onScanAgain,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
              label: const Text('Scan New QR Code'),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared: Gradient button
// ─────────────────────────────────────────────────────────────────────────────

class _GradientButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _GradientButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  State<_GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<_GradientButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        height: 50,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _pressed
                ? [const Color(0xFF3D56D6), const Color(0xFF3D5BD4)]
                : [const Color(0xFF6B8AF7), AppColors.accent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: _pressed
              ? []
              : [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              widget.label,
              style: GoogleFonts.inter(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
