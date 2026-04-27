import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../config.dart';
import 'flic_settings_screen.dart';
import 'examples_screen.dart';

class AppConfigurationScreen extends StatefulWidget {
  const AppConfigurationScreen({super.key});

  @override
  State<AppConfigurationScreen> createState() => _AppConfigurationScreenState();
}

class _AppConfigurationScreenState extends State<AppConfigurationScreen> {
  bool _autoStartVoice = false;
  String? _phoneNumber;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStartVoice = prefs.getBool('autoStartVoice') ?? false;
      _phoneNumber = Config.registeredPhoneNumber ?? prefs.getString(Config.prefKeyPhoneNumber);
    });
  }

  Future<void> _setAutoStartVoice(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoStartVoice', value);
    setState(() => _autoStartVoice = value);
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

  Future<void> _editPhoneNumber() async {
    final controller = TextEditingController(text: _phoneNumber ?? '');

    final result = await showDialog<_PhoneDialogResult>(
      context: context,
      builder: (ctx) => _PhoneNumberDialog(controller: controller, hasExisting: _phoneNumber != null),
    );

    if (result == null || !mounted) return;

    if (result == _PhoneDialogResult.remove) {
      await _unregisterPhone();
      return;
    }

    final number = controller.text.trim();
    if (number.isEmpty) return;
    await _registerPhone(number);
  }

  Future<void> _registerPhone(String number) async {
    final clientId = Config.clientId;
    if (clientId == null) {
      _showSnack('Client ID not available. Please restart the app.');
      return;
    }

    try {
      final uri = Uri.parse('${Config.serverUrl}/phone/register');
      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'client_id': clientId, 'phone_number': number}),
      );
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['ok'] == true) {
        final saved = body['phone_number'] as String? ?? number;
        await Config.setRegisteredPhone(saved);
        if (!mounted) return;
        setState(() => _phoneNumber = saved);
        _showSnack('Phone number registered. Calls from $saved will now identify you.');
      } else {
        _showSnack('Error: ${body['error'] ?? 'Unknown error'}');
      }
    } catch (e) {
      _showSnack('Could not reach server: $e');
    }
  }

  Future<void> _unregisterPhone() async {
    await Config.setRegisteredPhone(null);
    if (!mounted) return;
    setState(() => _phoneNumber = null);
    _showSnack('Phone number removed.');
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
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

          // Phone number for call identification
          ListTile(
            leading: const Icon(Icons.phone_in_talk),
            title: const Text('Phone Number for Calls'),
            subtitle: _phoneNumber != null
                ? Row(
                    children: [
                      const Icon(Icons.check_circle, size: 14, color: Colors.green),
                      const SizedBox(width: 4),
                      Text(_phoneNumber!, style: const TextStyle(color: Colors.green)),
                    ],
                  )
                : const Text('Not registered — tap to set up'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editPhoneNumber,
          ),
          const Divider(),

          // Examples
          ListTile(
            leading: const Icon(Icons.lightbulb_outline),
            title: const Text('Example Commands'),
            subtitle: const Text('Things you can ask RoadMate'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ExamplesScreen()),
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

enum _PhoneDialogResult { save, remove }

class _PhoneNumberDialog extends StatefulWidget {
  final TextEditingController controller;
  final bool hasExisting;
  const _PhoneNumberDialog({required this.controller, required this.hasExisting});

  @override
  State<_PhoneNumberDialog> createState() => _PhoneNumberDialogState();
}

class _PhoneNumberDialogState extends State<_PhoneNumberDialog> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Phone Number for Calls'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Register your phone number so RoadMate can identify you when you call the assistant number.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: widget.controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s()]'))],
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+1 (555) 000-0000',
              prefixIcon: Icon(Icons.phone),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        if (widget.hasExisting)
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(_PhoneDialogResult.remove),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () {
                  if (widget.controller.text.trim().isEmpty) return;
                  setState(() => _saving = true);
                  Navigator.of(context).pop(_PhoneDialogResult.save);
                },
          child: const Text('Register'),
        ),
      ],
    );
  }
}
