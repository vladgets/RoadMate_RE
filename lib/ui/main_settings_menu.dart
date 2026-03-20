import 'package:flutter/material.dart';
import 'memory_settings_screen.dart';
import 'reminders_screen.dart';
import 'voice_memories_screen.dart';
import 'developer_area_menu.dart';
import 'app_configuration_screen.dart';


class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // App Configuration submenu
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('App Configuration'),
            subtitle: const Text('Voice, auto-start, tutorial, and extensions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppConfigurationScreen()),
              );
            },
          ),
          const Divider(),

          // existing items unchanged
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Preferences'),
            subtitle: const Text('Edit user preferences (prompt)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => PreferencesSettingsScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const Text('Long-term Memory'),
            subtitle: const Text('View and manage stored memory'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MemorySettingsScreen()),
              );
            },
          ),
          // Reminders (view upcoming reminders)
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminders'),
            subtitle: const Text('View upcoming reminders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RemindersScreen()),
              );
            },
          ),
          // Voice Notes
          ListTile(
            leading: const Icon(Icons.mic_none_outlined),
            title: const Text('Voice Notes'),
            subtitle: const Text('Browse saved voice notes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VoiceMemoriesScreen()),
              );
            },
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.developer_mode),
            title: const Text('Developer'),
            subtitle: const Text('Debug tools and experimental features'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DeveloperAreaScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}


