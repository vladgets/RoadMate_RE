import 'package:flutter/material.dart';
import 'memory_settings_screen.dart';
import 'reminders_screen.dart';
import 'voice_memories_screen.dart';

class MyDataScreen extends StatelessWidget {
  const MyDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Data')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Preferences'),
            subtitle: const Text('Edit user preferences (prompt)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PreferencesSettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const Text('Long-term Memory'),
            subtitle: const Text('View and manage stored memory'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MemorySettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminders'),
            subtitle: const Text('View upcoming reminders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RemindersScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.mic_none_outlined),
            title: const Text('Voice Notes'),
            subtitle: const Text('Browse saved voice notes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VoiceMemoriesScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
