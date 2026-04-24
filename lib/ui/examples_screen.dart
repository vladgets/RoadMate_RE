import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/tip_of_day.dart';
import '../services/reminders.dart';

class ExamplesScreen extends StatefulWidget {
  const ExamplesScreen({super.key});

  @override
  State<ExamplesScreen> createState() => _ExamplesScreenState();
}

class _ExamplesScreenState extends State<ExamplesScreen> {
  bool _tipEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _tipEnabled = prefs.getBool('tip_of_day_enabled') ?? true;
    });
  }

  Future<void> _setTipEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tip_of_day_enabled', value);
    setState(() => _tipEnabled = value);

    if (!value) {
      // Cancel the scheduled tip reminder when disabled.
      final oldId = prefs.getInt('tip_of_day_reminder_id');
      if (oldId != null) {
        try {
          await RemindersService.instance.cancelReminder(oldId);
        } catch (_) {}
        await prefs.remove('tip_of_day_reminder_id');
        await prefs.remove('tip_of_day_scheduled_date');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Example Commands')),
      body: ListView(
        children: [
          // Tip of Day toggle
          SwitchListTile(
            secondary: const Icon(Icons.lightbulb_outline),
            title: const Text('Daily Tip Notification'),
            subtitle: const Text('Receive a command example every morning at 7am'),
            value: _tipEnabled,
            onChanged: _setTipEnabled,
          ),
          const Divider(),

          // Section header
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Things you can ask RoadMate',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black54,
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Tip list
          ...kTipPool.map((tip) => _TipTile(tip: tip)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _TipTile extends StatelessWidget {
  const _TipTile({required this.tip});
  final String tip;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
      title: Text(
        tip,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }
}
