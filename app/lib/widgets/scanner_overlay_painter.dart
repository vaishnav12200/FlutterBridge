import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Animated QR scanning overlay with corner brackets and scan line.
/// Draw it as a fullscreen CustomPaint on top of the camera widget.
class ScannerOverlayPainter extends CustomPainter {
  final double scanProgress; // 0.0 → 1.0 (bounces via reverse repeat)
  final double pulseOpacity; // 0.0 → 1.0 for bracket brightness pulse

  const ScannerOverlayPainter({
    required this.scanProgress,
    required this.pulseOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Scan area geometry ───────────────────────────────────────────────────
    final double scanSize = size.width * 0.68;
    final double left = (size.width - scanSize) / 2;
    final double top  = (size.height - scanSize) / 2 - 20;
    final Rect scanRect = Rect.fromLTWH(left, top, scanSize, scanSize);

    // ── Dark overlay around the scan area ────────────────────────────────────
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.62);

    // Clip path: full screen minus the scan rect (rounded)
    final RRect scanRRect = RRect.fromRectAndRadius(scanRect, const Radius.circular(16));
    final Path fullPath  = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path holePath  = Path()..addRRect(scanRRect);
    final Path clipPath  = Path.combine(PathOperation.difference, fullPath, holePath);

    canvas.drawPath(clipPath, overlayPaint);

    // ── Corner bracket lines ─────────────────────────────────────────────────
    final double cornerLen = 28.0;
    final double cornerRadius = 6.0;
    final Color bracketColor = Color.lerp(
      AppColors.accent.withValues(alpha: 0.7),
      AppColors.accent,
      pulseOpacity,
    )!;

    final bracketPaint = Paint()
      ..color = bracketColor
      ..strokeWidth = 3.0
      ..strokeCap  = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Glow paint for brackets
    final bracketGlow = Paint()
      ..color = AppColors.accent.withValues(alpha: 0.25 * pulseOpacity)
      ..strokeWidth = 8.0
      ..strokeCap  = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    void drawCorner(Canvas c, Offset corner, double dx, double dy) {
      final Path p = Path();

      // Horizontal arm
      p.moveTo(corner.dx + dx * cornerRadius, corner.dy);
      p.lineTo(corner.dx + dx * cornerLen, corner.dy);

      // Vertical arm
      p.moveTo(corner.dx, corner.dy + dy * cornerRadius);
      p.lineTo(corner.dx, corner.dy + dy * cornerLen);

      c.drawPath(p, bracketGlow);
      c.drawPath(p, bracketPaint);
    }

    // Top-left
    drawCorner(canvas, Offset(scanRect.left, scanRect.top), 1, 1);
    // Top-right
    drawCorner(canvas, Offset(scanRect.right, scanRect.top), -1, 1);
    // Bottom-left
    drawCorner(canvas, Offset(scanRect.left, scanRect.bottom), 1, -1);
    // Bottom-right
    drawCorner(canvas, Offset(scanRect.right, scanRect.bottom), -1, -1);

    // ── Animated scan line ───────────────────────────────────────────────────
    final double scanY = top + (scanSize * scanProgress);

    // Outer glow
    final glowPaint = Paint()
      ..strokeWidth = 12
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          AppColors.accent.withValues(alpha: 0.5),
          AppColors.accent.withValues(alpha: 0.7),
          AppColors.accent.withValues(alpha: 0.5),
          Colors.transparent,
        ],
        stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
      ).createShader(Rect.fromLTWH(left, scanY - 6, scanSize, 12));

    canvas.drawLine(Offset(left, scanY), Offset(left + scanSize, scanY), glowPaint);

    // Core line
    final linePaint = Paint()
      ..strokeWidth = 1.8
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          AppColors.accent.withValues(alpha: 0.8),
          AppColors.accent,
          AppColors.accent.withValues(alpha: 0.8),
          Colors.transparent,
        ],
        stops: const [0.0, 0.15, 0.5, 0.85, 1.0],
      ).createShader(Rect.fromLTWH(left, scanY - 1, scanSize, 2));

    canvas.drawLine(Offset(left, scanY), Offset(left + scanSize, scanY), linePaint);
  }

  @override
  bool shouldRepaint(ScannerOverlayPainter oldDelegate) =>
      oldDelegate.scanProgress != scanProgress ||
      oldDelegate.pulseOpacity != pulseOpacity;
}
