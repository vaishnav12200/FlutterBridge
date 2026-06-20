import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../services/vm_connection_manager.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    VMConnectionManager.instance.addListener(_onStateChange);
  }

  @override
  void dispose() {
    VMConnectionManager.instance.removeListener(_onStateChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final vm = VMConnectionManager.instance;
    final isConnected = vm.status == VMConnectionStatus.connected;
    
    // Mock available devices for UI purposes (phase 4 will use mDNS)
    final availableDevices = [
      _DeviceModel(name: 'MacBook Pro', platform: 'macOS', type: Icons.laptop_mac_rounded),
      _DeviceModel(name: 'Pixel 6', platform: 'Android', type: Icons.phone_android_rounded),
      _DeviceModel(name: 'iPhone 15', platform: 'iOS', type: Icons.phone_iphone_rounded),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchBar(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              children: [
                _buildSectionTitle('CONNECTED'),
                if (isConnected)
                  _buildDeviceCard(
                    name: vm.deviceName ?? 'Flutter Device',
                    platform: 'Dart VM',
                    type: Icons.phone_android_rounded,
                    isConnected: true,
                    onTapAction: vm.disconnect,
                  )
                else
                  _buildEmptyState('No device connected.\nScan a QR code to connect.'),
                  
                const SizedBox(height: 24),
                _buildSectionTitle('AVAILABLE (MOCK)'),
                ...availableDevices.map((d) => _buildDeviceCard(
                  name: d.name,
                  platform: d.platform,
                  type: d.type,
                  isConnected: false,
                  onTapAction: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Network discovery not yet implemented'),
                        backgroundColor: AppColors.surface2,
                      ),
                    );
                  },
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.phone_android_rounded,
              color: AppColors.textPrimary,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Devices',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: TextField(
        controller: _searchCtrl,
        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          hintText: 'Search devices...',
          hintStyle: GoogleFonts.inter(color: AppColors.textMuted),
          prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textMuted),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: GoogleFonts.inter(
          color: AppColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          color: AppColors.textSecondary,
          fontSize: 14,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildDeviceCard({
    required String name,
    required String platform,
    required IconData type,
    required bool isConnected,
    required VoidCallback onTapAction,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConnected ? AppColors.success.withValues(alpha: 0.3) : AppColors.border,
          width: 1,
        ),
        boxShadow: isConnected
            ? [BoxShadow(color: AppColors.success.withValues(alpha: 0.05), blurRadius: 10, spreadRadius: 2)]
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              type, 
              color: isConnected ? AppColors.success : AppColors.textSecondary, 
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        platform.toUpperCase(),
                        style: GoogleFonts.inter(
                          color: AppColors.textMuted,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isConnected ? AppColors.success : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isConnected ? 'Active' : 'Offline',
                      style: GoogleFonts.inter(
                        color: isConnected ? AppColors.success : AppColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onTapAction,
            style: TextButton.styleFrom(
              foregroundColor: isConnected ? AppColors.error : AppColors.accent,
              backgroundColor: isConnected 
                  ? AppColors.error.withValues(alpha: 0.1) 
                  : AppColors.accent.withValues(alpha: 0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            ),
            child: Text(
              isConnected ? 'Disconnect' : 'Connect',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceModel {
  final String name;
  final String platform;
  final IconData type;

  _DeviceModel({
    required this.name, 
    required this.platform, 
    required this.type,
  });
}
