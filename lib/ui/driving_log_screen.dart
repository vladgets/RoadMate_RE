import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/driving_log_store.dart';
import '../services/driving_monitor_service.dart';

class DrivingLogScreen extends StatefulWidget {
  const DrivingLogScreen({super.key});

  @override
  State<DrivingLogScreen> createState() => _DrivingLogScreenState();
}

class _DrivingLogScreenState extends State<DrivingLogScreen> {
  List<DrivingEvent> _events = [];
  bool _loading = true;
  StreamSubscription<void>? _visitSub;
  // Days (other than Today) that are currently expanded.
  // Today is always expanded; all other days start collapsed.
  final Set<String> _expandedDays = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Rebuild banner when POI resolves or visit state changes
    _visitSub = DrivingMonitorService.instance.visitUpdates.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _visitSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await DrivingLogStore.instance.init();
    setState(() {
      _events = List.of(DrivingLogStore.instance.getRecentEvents(200));
      _loading = false;
    });
  }

  /// Returns a flat list of [_DaySectionRow] headers and [DrivingEvent] items.
  /// Today is always expanded; other days start collapsed and toggle on tap.
  List<Object> _buildRows() {
    final rows = <Object>[];

    // Group events by day label, preserving sort order (newest first).
    // Visits use their end timestamp for grouping so an overnight visit
    // (started yesterday, ended today) appears under "Today" not "Yesterday".
    final List<String> orderedDays = [];
    final Map<String, List<DrivingEvent>> byDay = {};
    for (final event in _events) {
      final day = _dayLabelForEvent(event);
      if (!byDay.containsKey(day)) orderedDays.add(day);
      byDay.putIfAbsent(day, () => []).add(event);
    }

    for (final day in orderedDays) {
      final events = byDay[day]!;
      final isToday = day == 'Today';
      final isExpanded = isToday || _expandedDays.contains(day);

      rows.add(_DaySectionRow(
        label: day,
        count: events.length,
        isExpandable: !isToday,
        isExpanded: isExpanded,
      ));

      if (isExpanded) {
        rows.addAll(events);
      }
    }

    return rows;
  }

  String _dayLabel(String isoTimestamp) {
    try {
      final local = DateTime.parse(isoTimestamp).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final eventDay = DateTime(local.year, local.month, local.day);
      final diff = today.difference(eventDay).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Yesterday';
      if (diff < 7) return DateFormat('EEEE').format(local); // e.g. Monday
      if (local.year == now.year) return DateFormat('MMM d').format(local);
      return DateFormat('MMM d, y').format(local);
    } catch (_) {
      return '';
    }
  }

  /// Day label for grouping purposes.
  /// Visit events use their end timestamp so an overnight visit
  /// (started yesterday, ended today) appears under "Today".
  String _dayLabelForEvent(DrivingEvent event) {
    if (event.type == 'visit' && event.endTimestamp != null) {
      return _dayLabel(event.endTimestamp!);
    }
    return _dayLabel(event.timestamp);
  }

  String _buildMapLabel(DrivingEvent event) {
    final isStart = event.type == 'start';
    final isVisit = event.type == 'visit';
    final verb = isStart ? 'Trip started' : isVisit ? (event.label ?? 'Visit') : 'Parked';

    String timeStr;
    try {
      final utc = DateTime.parse(event.timestamp);
      final local = utc.toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final eventDay = DateTime(local.year, local.month, local.day);
      final dayDiff = today.difference(eventDay).inDays;
      final t = DateFormat('h:mm a').format(local);
      if (dayDiff == 0) {
        timeStr = 'Today $t';
      } else if (dayDiff == 1) {
        timeStr = 'Yesterday $t';
      } else {
        timeStr = DateFormat('MMM d, y • h:mm a').format(local);
      }
    } catch (_) {
      timeStr = event.timestamp;
    }

    if (event.address != null && event.address!.isNotEmpty) {
      return '$verb · $timeStr · ${event.address}';
    }
    if (event.lat != null && event.lon != null) {
      return '$verb · $timeStr · '
          '${event.lat!.toStringAsFixed(5)}, ${event.lon!.toStringAsFixed(5)}';
    }
    return '$verb · $timeStr';
  }

  Future<void> _openInMaps(DrivingEvent event) async {
    Uri? uri;
    final label = Uri.encodeComponent(_buildMapLabel(event));

    if (event.lat != null && event.lon != null) {
      final lat = event.lat!;
      final lon = event.lon!;
      if (Platform.isIOS) {
        uri = Uri.parse('http://maps.apple.com/?ll=$lat,$lon&q=$label');
      } else {
        uri = Uri.parse('geo:$lat,$lon?q=$lat,$lon($label)');
      }
    } else if (event.address != null && event.address!.isNotEmpty) {
      if (Platform.isIOS) {
        uri = Uri.parse('http://maps.apple.com/?q=$label');
      } else {
        uri = Uri.parse('geo:0,0?q=$label');
      }
    }

    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No location data for this event')),
        );
      }
      return;
    }

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Maps app')),
        );
      }
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Activity Log?'),
        content: const Text('This will delete all trips and visits.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Clear not yet implemented — delete app data to reset')),
    );
  }

  Future<void> _editVisitLabel(DrivingEvent event) async {
    final controller = TextEditingController(text: event.label ?? '');
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Visit Label'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'e.g., Home, Work, Gym',
            labelText: 'Label',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newLabel == null || !mounted) return;

    await DrivingLogStore.instance.updateEventLabel(event.id, newLabel);
    _load(); // Reload to reflect changes
  }

  @override
  Widget build(BuildContext context) {
    final currentVisit = DrivingMonitorService.instance.currentVisit;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Ongoing visit banner
                if (currentVisit != null)
                  _OngoingVisitBanner(visitInfo: currentVisit),
                Expanded(
                  child: _events.isEmpty && currentVisit == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.directions_car_outlined,
                                  size: 64, color: Colors.grey[400]),
                              const SizedBox(height: 16),
                              Text(
                                'No events yet',
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 16),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Drive or stay still for 10+ min to trigger detection',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 13),
                              ),
                            ],
                          ),
                        )
                      : Builder(builder: (context) {
                          final rows = _buildRows();
                          return ListView.separated(
                            itemCount: rows.length,
                            separatorBuilder: (_, i) {
                              // Suppress divider when adjacent to a day header.
                              final afterHeader = rows[i] is _DaySectionRow;
                              final beforeHeader =
                                  (i + 1 < rows.length) && rows[i + 1] is _DaySectionRow;
                              if (afterHeader || beforeHeader) {
                                return const SizedBox.shrink();
                              }
                              return const Divider(height: 1);
                            },
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              if (row is _DaySectionRow) {
                                return _DayHeader(
                                  label: row.label,
                                  count: row.count,
                                  isExpandable: row.isExpandable,
                                  isExpanded: row.isExpanded,
                                  onTap: row.isExpandable
                                      ? () => setState(() {
                                            if (_expandedDays.contains(row.label)) {
                                              _expandedDays.remove(row.label);
                                            } else {
                                              _expandedDays.add(row.label);
                                            }
                                          })
                                      : null,
                                );
                              }
                              final event = row as DrivingEvent;
                              return Dismissible(
                                key: Key(event.id),
                                direction: DismissDirection.endToStart,
                                confirmDismiss: (direction) async {
                                  return await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Delete Event?'),
                                      content: Text(
                                        event.type == 'visit'
                                            ? 'Delete this visit?'
                                            : event.type == 'start'
                                                ? 'Delete this trip start?'
                                                : 'Delete this park event?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Delete',
                                              style: TextStyle(
                                                  color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                onDismissed: (direction) async {
                                  final messenger =
                                      ScaffoldMessenger.of(context);
                                  await DrivingLogStore.instance
                                      .deleteEvent(event.id);
                                  if (!mounted) return;
                                  setState(() {
                                    _events.removeWhere(
                                        (e) => e.id == event.id);
                                  });
                                  messenger.showSnackBar(
                                    const SnackBar(
                                        content: Text('Event deleted')),
                                  );
                                },
                                background: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Icon(Icons.delete,
                                      color: Colors.white),
                                ),
                                child: _EventTile(
                                  event: event,
                                  onOpenMap: () => _openInMaps(event),
                                  onEditLabel: event.type == 'visit'
                                      ? () => _editVisitLabel(event)
                                      : null,
                                ),
                              );
                            },
                          );
                        }),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day section row — used as a type-safe sentinel in the flat rows list
// ---------------------------------------------------------------------------

class _DaySectionRow {
  final String label;
  final int count;
  final bool isExpandable;
  final bool isExpanded;

  const _DaySectionRow({
    required this.label,
    required this.count,
    required this.isExpandable,
    required this.isExpanded,
  });
}

// ---------------------------------------------------------------------------
// Day section header
// ---------------------------------------------------------------------------

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.label,
    this.count = 0,
    this.isExpandable = false,
    this.isExpanded = true,
    this.onTap,
  });

  final String label;
  final int count;
  final bool isExpandable;
  final bool isExpanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey[500],
                letterSpacing: 0.4,
              ),
            ),
            if (isExpandable) ...[
              const SizedBox(width: 8),
              Text(
                '$count ${count == 1 ? 'event' : 'events'}',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
              const Spacer(),
              Icon(
                isExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: Colors.grey[400],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ongoing visit banner shown at the top when a visit is in progress
// ---------------------------------------------------------------------------

class _OngoingVisitBanner extends StatelessWidget {
  const _OngoingVisitBanner({required this.visitInfo});

  final Map<String, dynamic> visitInfo;

  @override
  Widget build(BuildContext context) {
    String sinceStr = '';
    try {
      final start = DateTime.parse(visitInfo['startTime'] as String).toLocal();
      sinceStr = DateFormat('h:mm a').format(start);
    } catch (_) {}

    final label = visitInfo['label'] as String?;
    final address = visitInfo['address'] as String?;

    // Build title: show label if available, otherwise generic text
    String title;
    if (label != null && label.isNotEmpty) {
      title = sinceStr.isEmpty ? 'Visiting $label' : 'Visiting $label since $sinceStr';
    } else {
      title = sinceStr.isEmpty ? 'Visiting this location…' : 'Visiting since $sinceStr';
    }

    return Container(
      color: Colors.indigo.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.location_on, color: Colors.indigo[600], size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.indigo[700],
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                if (address != null && address.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      address,
                      style: TextStyle(
                        color: Colors.indigo[600],
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Icon(Icons.circle, size: 8, color: Colors.indigo[400]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Event tile — handles start, park, and visit types
// ---------------------------------------------------------------------------

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.onOpenMap,
    this.onEditLabel,
  });

  final DrivingEvent event;
  final VoidCallback onOpenMap;
  final VoidCallback? onEditLabel;

  @override
  Widget build(BuildContext context) {
    final isStart = event.type == 'start';
    final isVisit = event.type == 'visit';

    final IconData icon;
    final Color iconColor;
    final String label;

    if (isVisit) {
      icon = Icons.location_on;
      iconColor = Colors.indigo[700]!;
      label = event.label != null ? 'Visit · ${event.label}' : 'Visit';
    } else if (isStart) {
      icon = Icons.directions_car;
      iconColor = Colors.green[700]!;
      label = 'Trip started';
    } else {
      icon = Icons.local_parking;
      iconColor = Colors.blue[700]!;
      label = 'Parked';
    }

    final timestamp = _formatTimestamp(event.timestamp);
    final hasLocation = event.lat != null || event.address != null;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: iconColor.withValues(alpha: 0.12),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: onEditLabel != null
          ? InkWell(
              onTap: onEditLabel,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.edit, size: 14, color: Colors.grey[600]),
                ],
              ),
            )
          : Text(label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isVisit ? _formatVisitTime(event) : timestamp,
            style: const TextStyle(fontSize: 12),
          ),
          if (event.address != null && event.address!.isNotEmpty)
            Text(
              event.address!,
              style: const TextStyle(fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          else
            Text(
              event.lat != null
                  ? '${event.lat!.toStringAsFixed(5)}, ${event.lon!.toStringAsFixed(5)}'
                  : 'No location',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: hasLocation
          ? IconButton(
              icon: const Icon(Icons.map_outlined),
              tooltip: 'Open in Maps',
              onPressed: onOpenMap,
            )
          : null,
      onTap: hasLocation ? onOpenMap : null,
    );
  }

  String _formatTimestamp(String iso) {
    try {
      final utc = DateTime.parse(iso);
      final local = utc.toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final eventDay = DateTime(local.year, local.month, local.day);
      final dayDiff = today.difference(eventDay).inDays;
      final timeStr = DateFormat('h:mm a').format(local);
      if (dayDiff == 0) return 'Today $timeStr';
      if (dayDiff == 1) return 'Yesterday $timeStr';
      if (dayDiff < 7) return '${dayDiff}d ago $timeStr';
      return DateFormat('MMM d, y • h:mm a').format(local);
    } catch (_) {
      return iso;
    }
  }

  String _formatVisitTime(DrivingEvent event) {
    try {
      final start = DateTime.parse(event.timestamp).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final eventDay = DateTime(start.year, start.month, start.day);
      final dayDiff = today.difference(eventDay).inDays;
      final startStr = DateFormat('h:mm a').format(start);

      String dayPrefix;
      if (dayDiff == 0) {
        dayPrefix = 'Today';
      } else if (dayDiff == 1) {
        dayPrefix = 'Yesterday';
      } else {
        dayPrefix = DateFormat('MMM d').format(start);
      }

      if (event.endTimestamp != null) {
        final end = DateTime.parse(event.endTimestamp!).toLocal();
        final endStr = DateFormat('h:mm a').format(end);
        final dur = event.durationMinutes ?? 0;
        final durStr = dur >= 60
            ? '${dur ~/ 60}h ${dur % 60}m'
            : '${dur}m';
        return '$dayPrefix $startStr – $endStr ($durStr)';
      }
      return '$dayPrefix $startStr';
    } catch (_) {
      return event.timestamp;
    }
  }
}
