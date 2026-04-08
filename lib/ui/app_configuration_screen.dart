import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'flic_settings_screen.dart';
import 'onboarding_screen.dart';

class AppConfigurationScreen extends StatefulWidget {
  const AppConfigurationScreen({super.key});

  @override
  State<AppConfigurationScreen> createState() => _AppConfigurationScreenState();
}

class _AppConfigurationScreenState extends State<AppConfigurationScreen> {
  bool _autoStartVoice = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStartVoice = prefs.getBool('autoStartVoice') ?? false;
    });
  }

  Future<void> _setAutoStartVoice(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoStartVoice', value);
    setState(() {
      _autoStartVoice = value;
    });
  }

  String _voiceLabel(String v) {
    if (v == Config.femaleVoice) return 'Female (marin)';
    if (v == Config.maleVoice) return 'Male (echo)';
    return v;
  }

  Future<void> _pickVoice() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('Voice'),
          children: [
            RadioGroup<String>(
              groupValue: Config.voice,
              onChanged: (val) => Navigator.of(context).pop(val),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final v in Config.supportedVoices)
                    RadioListTile<String>(
                      value: v,
                      title: Text(_voiceLabel(v)),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );

    if (selected == null || selected == Config.voice) return;

    await Config.setVoice(selected);
    if (!mounted) return;
    setState(() {});

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Voice saved. It will apply on the next connection.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Configuration'),
      ),
      body: ListView(
        children: [
          // Voice picker
          ListTile(
            leading: const Icon(Icons.record_voice_over),
            title: const Text('Voice'),
            subtitle: Text(_voiceLabel(Config.voice)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickVoice,
          ),
          const Divider(),

          // Auto-start voice toggle
          SwitchListTile(
            secondary: const Icon(Icons.mic),
            title: const Text('Auto-start Voice'),
            subtitle: const Text('Activate microphone automatically on app launch'),
            value: _autoStartVoice,
            onChanged: _setAutoStartVoice,
          ),
          const Divider(),

          // Tutorial
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Tutorial'),
            subtitle: const Text('View getting started guide'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              );
            },
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: const Text('Flic Button'),
            subtitle: const Text('Set up Flic Bluetooth button for voice'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FlicSettingsScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}
