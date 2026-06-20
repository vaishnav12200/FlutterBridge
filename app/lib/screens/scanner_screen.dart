import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../widgets/scanner_overlay_painter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Screen 1: QR Scanner
// ─────────────────────────────────────────────────────────────────────────────

class ScannerScreen extends StatefulWidget {
  /// Called when a valid VM service URL is detected (either via QR or manually).
  final void Function(String url)? onUrlDetected;

  const ScannerScreen({super.key, this.onUrlDetected});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with TickerProviderStateMixin {
  // ── Controllers ─────────────────────────────────────────────────────────────
  late final MobileScannerController _camera;
  late final TextEditingController   _urlController;
  late final FocusNode               _urlFocus;

  // ── Animations ───────────────────────────────────────────────────────────────
  late final AnimationController _scanLineCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _statusSlideCtrl;

  late final Animation<double> _scanLineAnim;
  late final Animation<double> _pulseAnim;
  late final Animation<Offset> _statusSlideAnim;

  // ── State ────────────────────────────────────────────────────────────────────
  _ScanState _state = _ScanState.scanning;
  String? _detectedUrl;
  bool   _torchOn = false;

  @override
  void initState() {
    super.initState();

    _camera        = MobileScannerController(torchEnabled: false);
    _urlController = TextEditingController();
    _urlFocus      = FocusNode();

    // Scan line: 0 → 1 → 0 with 2.4s period
    _scanLineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _scanLineAnim = CurvedAnimation(
      parent: _scanLineCtrl,
      curve: Curves.easeInOut,
    );

    // Bracket pulse: gentle opacity change
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Bottom status panel slide-in on mount
    _statusSlideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();

    _statusSlideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end:   Offset.zero,
    ).animate(CurvedAnimation(
      parent: _statusSlideCtrl,
      curve: Curves.easeOutCubic,
    ));
  }

  @override
  void dispose() {
    _camera.dispose();
    _urlController.dispose();
    _urlFocus.dispose();
    _scanLineCtrl.dispose();
    _pulseCtrl.dispose();
    _statusSlideCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String? _normalise(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    Uri uri;
    try {
      uri = t.contains('://') ? Uri.parse(t) : Uri.parse('ws://$t');
    } catch (_) {
      return null;
    }
    if (uri.scheme == 'http')  uri = uri.replace(scheme: 'ws');
    if (uri.scheme == 'https') uri = uri.replace(scheme: 'wss');
    if (uri.scheme != 'ws' && uri.scheme != 'wss') return null;
    return uri.toString();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_state != _ScanState.scanning) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      final url = _normalise(raw);
      if (url != null) {
        _accept(url);
        return;
      }
    }
    // QR found but not a valid VM URL
    setState(() => _state = _ScanState.badQr);
  }

  void _accept(String url) {
    _camera.stop();
    _scanLineCtrl.stop();
    _pulseCtrl.stop();
    setState(() {
      _state = _ScanState.found;
      _detectedUrl = url;
    });
    widget.onUrlDetected?.call(url);
  }

  void _connectManual() {
    final url = _normalise(_urlController.text);
    if (url == null) {
      setState(() => _state = _ScanState.badQr);
      return;
    }
    _accept(url);
  }

  void _reset() {
    _urlController.clear();
    _camera.start();
    _scanLineCtrl.repeat(reverse: true);
    _pulseCtrl.repeat(reverse: true);
    setState(() {
      _state       = _ScanState.scanning;
      _detectedUrl = null;
    });
  }

  void _toggleTorch() {
    setState(() => _torchOn = !_torchOn);
    _camera.toggleTorch();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // ── Camera + overlay ──────────────────────────────────────────────
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Camera feed
                MobileScanner(
                  controller: _camera,
                  onDetect: _onDetect,
                  errorBuilder: (context, error, child) {
                    return _CameraErrorWidget(error: error.errorCode.name);
                  },
                ),

                // Overlay
                AnimatedBuilder(
                  animation: Listenable.merge([_scanLineAnim, _pulseAnim]),
                  builder: (context, _) => CustomPaint(
                    painter: ScannerOverlayPainter(
                      scanProgress: _scanLineAnim.value,
                      pulseOpacity: _pulseAnim.value,
                    ),
                  ),
                ),

                // Hint text above scan area
                Positioned(
                  top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
                  left: 24,
                  right: 24,
                  child: _buildHintBanner(),
                ),

                // Torch button (bottom-left of camera)
                Positioned(
                  bottom: 16,
                  right: 24,
                  child: _TorchButton(on: _torchOn, onTap: _toggleTorch),
                ),
              ],
            ),
          ),

          // ── Status panel ────────────────────────────────────────────────
          SlideTransition(
            position: _statusSlideAnim,
            child: _buildStatusPanel(),
          ),
        ],
      ),
    );
  }

  // ── AppBar ───────────────────────────────────────────────────────────────

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
            child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('QR Scanner', style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: AppColors.textPrimary,
          )),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () {},
        ),
        const SizedBox(width: 4),
      ],
      backgroundColor: Colors.transparent,
    );
  }

  // ── Hint banner ──────────────────────────────────────────────────────────

  Widget _buildHintBanner() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: _state == _ScanState.badQr
          ? _Banner(
              key: const ValueKey('bad'),
              icon: Icons.warning_amber_rounded,
              color: AppColors.warning,
              text: 'Not a FlutterBridge QR code. Try again.',
            )
          : _Banner(
              key: const ValueKey('hint'),
              icon: Icons.qr_code_rounded,
              color: Colors.white.withValues(alpha: 0.85),
              text: 'Point the camera at the FlutterBridge QR code',
            ),
    );
  }

  // ── Status panel ─────────────────────────────────────────────────────────

  Widget _buildStatusPanel() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status row
          _StatusRow(state: _state, url: _detectedUrl),

          const SizedBox(height: 20),

          if (_state != _ScanState.found) ...[
            // Manual URL field
            TextField(
              controller: _urlController,
              focusNode: _urlFocus,
              style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Manual URL',
                hintText: 'ws://192.168.x.x:PORT/...',
                prefixIcon: Icon(Icons.link_rounded),
                suffixIcon: Icon(Icons.content_paste_rounded),
              ),
              onSubmitted: (_) => _connectManual(),
            ),
            const SizedBox(height: 14),
            _ConnectButton(state: _state, onConnect: _connectManual, onReset: _reset),
          ] else ...[
            // Found state: show URL + connect action
            _FoundCard(url: _detectedUrl!, onReset: _reset),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Supporting Widgets
// ─────────────────────────────────────────────────────────────────────────────

enum _ScanState { scanning, badQr, found }

// ── Status row ───────────────────────────────────────────────────────────────

class _StatusRow extends StatefulWidget {
  final _ScanState state;
  final String?    url;

  const _StatusRow({required this.state, this.url});

  @override
  State<_StatusRow> createState() => _StatusRowState();
}

class _StatusRowState extends State<_StatusRow> with SingleTickerProviderStateMixin {
  late final AnimationController _dotCtrl;
  late final Animation<double>   _dotAnim;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
    _dotAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _dotCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, label, subtitle) = switch (widget.state) {
      _ScanState.scanning => (AppColors.accent,   'Scanning...',          'Waiting for QR code'),
      _ScanState.badQr    => (AppColors.warning,  'Invalid QR code',      'Use FlutterBridge CLI to generate one'),
      _ScanState.found    => (AppColors.success,  'QR Code Detected!',    widget.url ?? ''),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pulsing dot
        AnimatedBuilder(
          animation: _dotAnim,
          builder: (ctx, _) => Opacity(
            opacity: widget.state == _ScanState.scanning ? _dotAnim.value : 1.0,
            child: Container(
              margin: const EdgeInsets.only(top: 4),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6, spreadRadius: 1)],
              ),
            ),
          ),
        ),

        const SizedBox(width: 12),

        // Text
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: GoogleFonts.inter(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              )),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle, style: GoogleFonts.inter(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Connect / Scan Again button ──────────────────────────────────────────────

class _ConnectButton extends StatelessWidget {
  final _ScanState state;
  final VoidCallback onConnect;
  final VoidCallback onReset;

  const _ConnectButton({
    required this.state,
    required this.onConnect,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: _GradientButton(
            label: 'Connect',
            icon: Icons.electrical_services_rounded,
            onPressed: onConnect,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
            label: const Text('Scan'),
          ),
        ),
      ],
    );
  }
}

// ── Found card ───────────────────────────────────────────────────────────────

class _FoundCard extends StatelessWidget {
  final String       url;
  final VoidCallback onReset;

  const _FoundCard({required this.url, required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.successDim,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(url,
                  style: GoogleFonts.robotoMono(color: AppColors.textSecondary, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
          label: const Text('Scan Again'),
        ),
      ],
    );
  }
}

// ── Gradient primary button ───────────────────────────────────────────────────

class _GradientButton extends StatefulWidget {
  final String       label;
  final IconData     icon;
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
      onTapDown:  (_) => setState(() => _pressed = true),
      onTapUp:    (_) { setState(() => _pressed = false); widget.onPressed(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 50,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _pressed
                ? [const Color(0xFF3D56D6), const Color(0xFF3D5BD4)]
                : [const Color(0xFF6B8AF7), AppColors.accent],
            begin: Alignment.topLeft,
            end:   Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: _pressed ? [] : [
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
            Text(widget.label, style: GoogleFonts.inter(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            )),
          ],
        ),
      ),
    );
  }
}

// ── Hint banner ───────────────────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   text;

  const _Banner({super.key, required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text, style: GoogleFonts.inter(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

// ── Torch toggle button ───────────────────────────────────────────────────────

class _TorchButton extends StatelessWidget {
  final bool         on;
  final VoidCallback onTap;

  const _TorchButton({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.6),
          shape: BoxShape.circle,
          border: Border.all(
            color: on ? AppColors.accent : Colors.white.withValues(alpha: 0.2),
          ),
          boxShadow: on ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.5), blurRadius: 12)] : [],
        ),
        child: Icon(
          on ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }
}

// ── Camera error ──────────────────────────────────────────────────────────────

class _CameraErrorWidget extends StatelessWidget {
  final String error;

  const _CameraErrorWidget({required this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.errorDim,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.no_photography_rounded, color: AppColors.error, size: 32),
            ),
            const SizedBox(height: 16),
            Text('Camera unavailable', style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 6),
            Text(error, style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 13,
            )),
            const SizedBox(height: 20),
            Text('Enable camera permission in Settings', style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 12,
            )),
          ],
        ),
      ),
    );
  }
}
