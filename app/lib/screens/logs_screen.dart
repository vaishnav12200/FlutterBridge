import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../services/vm_connection_manager.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  LogLevel? _filter; // null means 'All'
  bool _autoScroll = true;
  final ScrollController _scrollController = ScrollController();
  int _lastLogCount = 0;

  @override
  void initState() {
    super.initState();
    VMConnectionManager.instance.addListener(_onVMManagerChange);
  }

  @override
  void dispose() {
    VMConnectionManager.instance.removeListener(_onVMManagerChange);
    _scrollController.dispose();
    super.dispose();
  }

  void _onVMManagerChange() {
    final currentCount = VMConnectionManager.instance.logs.length;
    if (currentCount > _lastLogCount) {
      _lastLogCount = currentCount;
      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } else if (currentCount < _lastLogCount) {
      _lastLogCount = currentCount; // logs were cleared
    }
    
    // We only need to rebuild if we are actually tracking state, but ListenableBuilder takes care of the list rebuild.
  }

  Color _colorForLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return const Color(0xFF6B8AF7); // Blue
      case LogLevel.info:
        return const Color(0xFF14B8A6); // Teal
      case LogLevel.warning:
        return AppColors.warning; // Amber
      case LogLevel.error:
        return AppColors.error; // Red
    }
  }

  String _nameForLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug: return 'Debug';
      case LogLevel.info: return 'Info';
      case LogLevel.warning: return 'Warn';
      case LogLevel.error: return 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFilterRow(),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: _buildLogList(),
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
              Icons.terminal_rounded,
              color: AppColors.textPrimary,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Logs',
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Auto-scroll',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _autoScroll ? AppColors.textPrimary : AppColors.textMuted,
              ),
            ),
            Switch(
              value: _autoScroll,
              activeTrackColor: AppColors.accent,
              onChanged: (val) {
                setState(() => _autoScroll = val);
                if (val) _onVMManagerChange(); // Trigger scroll
              },
            ),
          ],
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.delete_sweep_rounded),
          tooltip: 'Clear Logs',
          onPressed: () {
            VMConnectionManager.instance.clearLogs();
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildFilterRow() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildFilterChip('All', null, null),
            const SizedBox(width: 8),
            _buildFilterChip('Debug', LogLevel.debug, _colorForLevel(LogLevel.debug)),
            const SizedBox(width: 8),
            _buildFilterChip('Info', LogLevel.info, _colorForLevel(LogLevel.info)),
            const SizedBox(width: 8),
            _buildFilterChip('Warn', LogLevel.warning, _colorForLevel(LogLevel.warning)),
            const SizedBox(width: 8),
            _buildFilterChip('Error', LogLevel.error, _colorForLevel(LogLevel.error)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, LogLevel? level, Color? dotColor) {
    final isSelected = _filter == level;
    return InkWell(
      onTap: () => setState(() => _filter = level),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.accent : AppColors.border,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogList() {
    return ListenableBuilder(
      listenable: VMConnectionManager.instance,
      builder: (context, _) {
        final allLogs = VMConnectionManager.instance.logs;
        // Separators always pass through; level filter applies only to regular entries
        final filteredLogs = _filter == null
            ? allLogs
            : allLogs
                .where((log) => log.isSeparator || log.level == _filter)
                .toList();

        if (allLogs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.speaker_notes_off_rounded, size: 48, color: AppColors.border),
                const SizedBox(height: 16),
                Text(
                  'No logs yet',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          controller: _scrollController,
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: filteredLogs.length,
          separatorBuilder: (context, index) {
            // No divider line before/after a separator widget — it has its own spacing
            if (filteredLogs[index].isSeparator ||
                (index + 1 < filteredLogs.length && filteredLogs[index + 1].isSeparator)) {
              return const SizedBox.shrink();
            }
            return const Divider(height: 1, color: AppColors.border);
          },
          itemBuilder: (context, index) {
            final log = filteredLogs[index];
            return _buildLogEntry(log);
          },
        );
      },
    );
  }

  Widget _buildLogEntry(LogEntry log) {
    // ── Separator (Hot Restart divider) ──────────────────────────────────────
    if (log.isSeparator) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Expanded(child: Divider(color: AppColors.accentDim, thickness: 1)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accentGlow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentDim),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.refresh_rounded, size: 11, color: AppColors.accent),
                  const SizedBox(width: 5),
                  Text(
                    'Hot Restarted',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: Divider(color: AppColors.accentDim, thickness: 1)),
          ],
        ),
      );
    }

    // ── Regular log entry ────────────────────────────────────────────────────
    final color = _colorForLevel(log.level);

    final hour = log.timestamp.hour.toString().padLeft(2, '0');
    final minute = log.timestamp.minute.toString().padLeft(2, '0');
    final second = log.timestamp.second.toString().padLeft(2, '0');
    final millis = log.timestamp.millisecond.toString().padLeft(3, '0');
    final timeStr = '$hour:$minute:$second.$millis';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          left: BorderSide(color: color, width: 4),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                timeStr,
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _nameForLevel(log.level).toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            log.message,
            style: GoogleFonts.firaCode(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
