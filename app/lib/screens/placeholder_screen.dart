import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Placeholder screen shown while the real screen is under development.
class PlaceholderScreen extends StatelessWidget {
  final String  title;
  final IconData icon;
  final String  comingSoon;

  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    this.comingSoon = 'Coming in next sprint',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 40, color: AppColors.accent.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 20),
            Text(title, style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            )),
            const SizedBox(height: 8),
            Text(comingSoon, style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 14,
            )),
          ],
        ),
      ),
    );
  }
}
