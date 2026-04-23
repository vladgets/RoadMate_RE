import 'package:flutter/material.dart';
import 'my_data_screen.dart';
import 'app_configuration_screen.dart';
import 'extensions_settings_screen.dart';
import 'crm_identity_menu_screen.dart';
import '../config.dart';


class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _fubAgentName;

  @override
  void initState() {
    super.initState();
    _fubAgentName = Config.fubAgentName;
  }

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
          // Extensions (Google Calendar, Gmail, etc.)
          ListTile(
            leading: const Icon(Icons.extension),
            title: const Text('Extensions'),
            subtitle: const Text('Google Calendar, Gmail, and other integrations'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ExtensionsSettingsScreen()),
              );
            },
          ),
          const Divider(),

          // App Configuration submenu
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('App Configuration'),
            subtitle: const Text('Voice, auto-start, and tutorial'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppConfigurationScreen()),
              );
            },
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('CRM Identity'),
            subtitle: Text(_fubAgentName != null
                ? 'Signed in as $_fubAgentName'
                : 'Not set — tap to identify yourself'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CrmIdentityMenuScreen()),
              );
              setState(() => _fubAgentName = Config.fubAgentName);
            },
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('My Data'),
            subtitle: const Text('Preferences, memory, and reminders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyDataScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}


