import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/scanner_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/placeholder_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry Point
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.surface,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const FlutterBridgeApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Root App
// ─────────────────────────────────────────────────────────────────────────────

class FlutterBridgeApp extends StatelessWidget {
  const FlutterBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlutterBridge',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const MainShell(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Shell — bottom navigation + tab switching
// ─────────────────────────────────────────────────────────────────────────────

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  String? _vmServiceUrl;

  void _onUrlDetected(String url) {
    setState(() {
      _vmServiceUrl = url;
      _index = 1; // switch to Home tab
    });
    debugPrint('URL detected: $url');
  }

  void _onScanAgain() {
    setState(() {
      _index = 0; // Switch to Scanner tab
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      ScannerScreen(onUrlDetected: _onUrlDetected),
      HomeScreen(
        vmServiceUrl: _vmServiceUrl,
        onScanAgain: _onScanAgain,
      ),
      const LogsScreen(),
      const DevicesScreen(),
      const PlaceholderScreen(
        title: 'Settings',
        icon: Icons.tune_rounded,
        comingSoon: 'Screen 5 — App preferences',
      ),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      // Preserve state of each screen (camera, scroll position, etc.)
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: _buildNav(),
    );
  }

  Widget _buildNav() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: AppColors.surface,
        elevation: 0,
        animationDuration: const Duration(milliseconds: 300),
        destinations: [
          _navItem(Icons.qr_code_scanner_rounded, Icons.qr_code_scanner_rounded, 'Scanner'),
          _navItem(Icons.home_rounded,             Icons.home_outlined,            'Home'),
          _navItem(Icons.terminal_rounded,         Icons.terminal_rounded,         'Logs'),
          _navItem(Icons.phone_android_rounded,    Icons.phone_android_outlined,   'Devices'),
          _navItem(Icons.tune_rounded,             Icons.tune_rounded,             'Settings'),
        ],
      ),
    );
  }

  NavigationDestination _navItem(IconData selected, IconData unselected, String label) {
    return NavigationDestination(
      icon: Icon(unselected),
      selectedIcon: Icon(selected),
      label: label,
      tooltip: label,
    );
  }
}
