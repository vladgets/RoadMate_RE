import 'package:flutter/material.dart';
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

}
