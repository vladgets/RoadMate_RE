import 'dart:async';
import 'package:activity_recognition_flutter/activity_recognition_flutter.dart';
import 'package:flutter/material.dart';
import 'youtube_history_screen.dart';
import 'driving_log_screen.dart';
import 'activity_settings_screen.dart';
import '../services/photo_index_service.dart';
import '../services/driving_monitor_service.dart';
import '../config.dart';


class DeveloperAreaScreen extends StatefulWidget {
  const DeveloperAreaScreen({super.key});

  @override
  State<DeveloperAreaScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<DeveloperAreaScreen> {
  bool _greetingEnabled = false;
  String _greetingPhrase = "Hello, how can I help you?";

  @override
  void initState() {
    super.initState();
    _loadGreetingSettings();
  }

  Future<void> _loadGreetingSettings() async {
    final enabled = await Config.getInitialGreetingEnabled();
    final phrase = await Config.getInitialGreetingPhrase();
    setState(() {
      _greetingEnabled = enabled;
      _greetingPhrase = phrase;
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer Area'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Activity Log'),
            subtitle: const Text('Trips, visits, and parking events'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DrivingLogScreen()),
              );
            },
          ),
          const _ActivityFeed(),
          const Divider(),
          // Activity settings
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Activity Settings'),
            subtitle: const Text('Visit threshold, POI lookup'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ActivitySettingsScreen()),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.video_library),
            title: const Text('YouTube history'),
            subtitle: const Text('Videos from subscriptions (last month)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const YouTubeHistoryScreen()),
              );
            },
          ),
          const Divider(),
          Builder(
            builder: (context) {
              final stats = PhotoIndexService.instance.getStats();
              final indexed = stats['indexed'] as int;
              final total = stats['total'] as int;
              final withTimestamps = stats['withTimestamps'] as int;
              final withLocation = stats['withLocation'] as int;

              final subtitle = indexed == 0
                  ? 'Not indexed yet'
                  : '$indexed indexed ($withTimestamps with timestamps, $withLocation with location)';
              return ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Photo Album Index'),
                subtitle: Text(subtitle),
                onTap: () {
                  // Show detailed stats dialog
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Photo Index Details'),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Total photos in album: $total'),
                            Text('Photos indexed: $indexed'),
                            Text('Photos with timestamps: $withTimestamps'),
                            Text('Photos with location: $withLocation'),
                            const SizedBox(height: 16),
                            if (stats['oldestPhoto'] != null)
                              Text('Oldest photo: ${_formatDate(stats['oldestPhoto'] as String)}'),
                            if (stats['newestPhoto'] != null)
                              Text('Newest photo: ${_formatDate(stats['newestPhoto'] as String)}'),
                            if (stats['last_indexed'] != null)
                              Text('\nLast indexed: ${_formatDate(stats['last_indexed'] as String)}'),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                },
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Rebuild Index',
                  onPressed: () async {
                    // Show confirmation dialog
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Rebuild Photo Index?'),
                        content: const Text(
                          'This will rebuild the entire photo index. '
                          'Only camera photos will be included. '
                          'This may take a few minutes.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Rebuild'),
                          ),
                        ],
                      ),
                    );

                    if (confirm != true) return;

                    // Show progress dialog
                    if (!context.mounted) return;
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) => const AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(width: 20),
                            Text('Rebuilding index...'),
                          ],
                        ),
                      ),
                    );

                    // Rebuild index
                    final result = await PhotoIndexService.instance.buildIndex(forceRebuild: true);

                    // Close progress dialog
                    if (!context.mounted) return;
                    Navigator.pop(context);

                    // Show result
                    if (!context.mounted) return;
                    final message = result['ok'] == true
                        ? 'Index rebuilt successfully!\n${result['indexed']} photos indexed'
                        : 'Failed to rebuild index: ${result['error']}';

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(message)),
                    );

                    // Refresh UI
                    setState(() {});
                  },
                ),
              );
            },
          ),
          const Divider(),
          // Initial greeting settings
          SwitchListTile(
            secondary: const Icon(Icons.waving_hand),
            title: const Text('Initial Greeting'),
            subtitle: Text(_greetingEnabled ? 'Assistant greets you on connect' : 'Disabled'),
            value: _greetingEnabled,
            onChanged: (bool value) async {
              setState(() => _greetingEnabled = value);
              await Config.setInitialGreetingEnabled(value);
            },
          ),
          if (_greetingEnabled)
            ListTile(
              leading: const SizedBox(width: 24), // Indent to align with switch
              title: const Text('Greeting Phrase'),
              subtitle: Text(_greetingPhrase),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final controller = TextEditingController(text: _greetingPhrase);
                final result = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Edit Greeting Phrase'),
                    content: TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        hintText: 'Enter greeting phrase',
                      ),
                      maxLines: 2,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, controller.text),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );

                if (result != null && result.isNotEmpty) {
                  setState(() => _greetingPhrase = result);
                  await Config.setInitialGreetingPhrase(result);
                }
              },
            ),
        ],
      ),
    );
  }

  String _formatDate(String isoString) {
    try {
      final date = DateTime.parse(isoString);
      final now = DateTime.now();
      final diff = now.difference(date);

      if (diff.inDays == 0) {
        return 'Today ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
      } else if (diff.inDays == 1) {
        return 'Yesterday ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
      } else if (diff.inDays < 7) {
        return '${diff.inDays} days ago';
      } else {
        return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
    } catch (e) {
      return isoString;
    }
  }
}

// ---------------------------------------------------------------------------
// Live activity sensor feed — shows raw events from the sensor pipeline
// regardless of confidence, so you can verify detection without driving.
// ---------------------------------------------------------------------------

class _ActivityFeed extends StatefulWidget {
  const _ActivityFeed();

  @override
  State<_ActivityFeed> createState() => _ActivityFeedState();
}

class _ActivityFeedState extends State<_ActivityFeed> {
  static const _maxEvents = 5;
  final List<ActivityEvent> _events = [];
  StreamSubscription<ActivityEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = DrivingMonitorService.instance.rawEvents.listen((event) {
      setState(() {
        _events.insert(0, event);
        if (_events.length > _maxEvents) _events.removeLast();
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  static IconData _iconFor(ActivityType type) {
    switch (type) {
      case ActivityType.inVehicle:  return Icons.directions_car;
      case ActivityType.onBicycle:  return Icons.directions_bike;
      case ActivityType.onFoot:
      case ActivityType.walking:    return Icons.directions_walk;
      case ActivityType.running:    return Icons.directions_run;
      case ActivityType.still:      return Icons.pause_circle_outline;
      case ActivityType.tilting:    return Icons.screen_rotation;
      default:                      return Icons.help_outline;
    }
  }

  static Color _colorFor(ActivityType type) {
    switch (type) {
      case ActivityType.inVehicle:  return Colors.blue;
      case ActivityType.still:      return Colors.grey;
      case ActivityType.onFoot:
      case ActivityType.walking:    return Colors.green;
      case ActivityType.running:    return Colors.orange;
      default:                      return Colors.purple;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.sensors, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Text('Live Activity Feed',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(width: 8),
              Text('(walk around to test)',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
            ],
          ),
        ),
        if (_events.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Waiting for sensor events…',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          for (final e in _events)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  Icon(_iconFor(e.type), size: 18, color: _colorFor(e.type)),
                  const SizedBox(width: 8),
                  Text(e.typeString,
                      style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: _colorFor(e.type))),
                  const SizedBox(width: 6),
                  Text('${e.confidence}%',
                      style: const TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text(
                    '${e.timeStamp.hour.toString().padLeft(2, '0')}:${e.timeStamp.minute.toString().padLeft(2, '0')}:${e.timeStamp.second.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 8),
      ],
    );
  }
}
