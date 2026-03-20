import 'package:flutter/material.dart';
import '../services/reminders.dart';

// Accent color per reminder type.
Color _accentColor(Reminder r) {
  if (r.aiPrompt != null) return const Color(0xFF9C27B0); // purple
  if (r.recurrence == 'daily') return const Color(0xFFE65100); // deep orange
  if (r.recurrence == 'weekly') return const Color(0xFF00796B); // teal
  return const Color(0xFF1565C0); // deep blue (one-shot)
}

IconData _typeIcon(Reminder r) {
  if (r.aiPrompt != null) return Icons.auto_awesome;
  if (r.recurrence == 'daily') return Icons.repeat;
  if (r.recurrence == 'weekly') return Icons.date_range;
  return Icons.notifications_outlined;
}

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  bool _loading = true;
  List<Reminder> _reminders = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await RemindersService.instance.init();
      final upcoming = await RemindersService.instance.listUpcoming();
      if (!mounted) return;
      setState(() => _reminders = upcoming);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Time formatting ──────────────────────────────────────────────────────

  String _formatTime(BuildContext context, DateTime dt) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final loc = MaterialLocalizations.of(context);
    return loc.formatTimeOfDay(
      TimeOfDay.fromDateTime(dt),
      alwaysUse24HourFormat: use24h,
    );
  }

  String _formatNextOccurrence(BuildContext context, Reminder r) {
    final dt = computeNextOccurrence(r);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dtDay = DateTime(dt.year, dt.month, dt.day);
    final diff = dtDay.difference(today).inDays;
    final timeStr = _formatTime(context, dt);

    if (diff == 0) return 'Today · $timeStr';
    if (diff == 1) return 'Tomorrow · $timeStr';

    final loc = MaterialLocalizations.of(context);
    return '${loc.formatMediumDate(dt)} · $timeStr';
  }

  String _recurrenceLabel(Reminder r) {
    if (r.recurrence == 'daily') return 'Daily';
    if (r.recurrence == 'weekly') {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final dow = r.dayOfWeek ?? r.scheduledAtLocal.weekday;
      final name = (dow >= 1 && dow <= 7) ? days[dow - 1] : '?';
      return 'Every $name';
    }
    return '';
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _delete(Reminder r) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete reminder?'),
        content: Text('"${r.text}" will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    await RemindersService.instance.cancelReminder(r.id);
    await _load();
  }

  Future<void> _edit(Reminder r) async {
    final isAi = r.aiPrompt != null;
    // For AI reminders edit the prompt (what the AI uses to generate content).
    // For regular reminders edit the label text.
    final initialValue = isAi ? (r.aiPrompt ?? '') : r.text;
    final controller = TextEditingController(text: initialValue);

    final newValue = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isAi ? 'Edit AI instructions' : 'Edit reminder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: isAi ? 4 : 2,
          decoration: InputDecoration(
            hintText: isAi ? 'What should the AI say each time?' : 'Reminder text…',
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newValue == null || newValue.isEmpty || !mounted) return;
    if (newValue == initialValue) return;

    if (isAi) {
      await RemindersService.instance.updateAiPrompt(r.id, newValue);
    } else {
      await RemindersService.instance.updateReminderText(r.id, newValue);
    }
    await _load();
  }

  // ── Card widget ──────────────────────────────────────────────────────────

  Widget _buildCard(BuildContext context, Reminder r) {
    final accent = _accentColor(r);
    final icon = _typeIcon(r);
    final timeLabel = _formatNextOccurrence(context, r);
    final recLabel = _recurrenceLabel(r);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left color strip
              Container(width: 5, color: accent),

              // Icon badge
              Container(
                width: 56,
                color: accent.withAlpha(20),
                alignment: Alignment.center,
                child: Icon(icon, color: accent, size: 26),
              ),

              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.text,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _Chip(
                            label: timeLabel,
                            icon: Icons.access_time,
                            color: accent,
                          ),
                          if (recLabel.isNotEmpty)
                            _Chip(
                              label: recLabel,
                              icon: Icons.repeat,
                              color: accent,
                            ),
                          if (r.aiPrompt != null)
                            _Chip(
                              label: 'AI',
                              icon: Icons.auto_awesome,
                              color: accent,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Action buttons
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: Icon(Icons.edit_outlined,
                        color: accent.withAlpha(200), size: 20),
                    onPressed: () => _edit(r),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: Icon(Icons.delete_outline,
                        color: Colors.red.shade300, size: 20),
                    onPressed: () => _delete(r),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminders'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Failed to load reminders:\n$_error'),
                  ),
                )
              : _reminders.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_off_outlined,
                              size: 64, color: Colors.black26),
                          SizedBox(height: 12),
                          Text(
                            'No upcoming reminders',
                            style: TextStyle(color: Colors.black45),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _reminders.length,
                      itemBuilder: (context, i) =>
                          _buildCard(context, _reminders[i]),
                    ),
    );
  }
}

// Small colored chip widget used for time / recurrence / AI badges.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
