import 'package:flutter/material.dart';
import 'memory_settings_screen.dart';
import 'contact_aliases_screen.dart';
import 'place_aliases_screen.dart';
import 'reminders_screen.dart';
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
          const Divider(),
          ListTile(
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const Text('Long-term Memory'),
            subtitle: const Text('View and manage stored memory'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MemorySettingsScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.contacts_outlined),
            title: const Text('Contact Aliases'),
            subtitle: const Text('Spoken names mapped to phone contacts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ContactAliasesScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: const Text('Place Aliases'),
            subtitle: const Text('Spoken place names mapped to addresses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlaceAliasesScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminders'),
            subtitle: const Text('View upcoming reminders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RemindersScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
