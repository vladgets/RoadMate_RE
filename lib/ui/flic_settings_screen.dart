import 'dart:io';
import 'package:flutter/material.dart';

class FlicSettingsScreen extends StatelessWidget {
  const FlicSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flic Button Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Flic Bluetooth Button',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Configure your Flic button using the Flic app. '
            'Once set up, pressing the button activates RoadMate voice without opening the app.',
          ),
          const SizedBox(height: 24),
          if (Platform.isAndroid) ..._androidSteps() else ..._iosSteps(),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          _holdSection(),
        ],
      ),
    );
  }

  List<Widget> _androidSteps() => [
        _sectionHeader('Single Press — Start Voice (background)'),
        const SizedBox(height: 8),
        _step(1, 'Open the Flic app and select your button.'),
        _step(2, 'Tap "Click" → choose "Send Intent" from the action list.'),
        _step(3, 'Set Target to "Activity" (not Broadcast or Service).'),
        _step(4, 'Fill in the Action field:', child: _codeCard('com.example.road_mate_flutter.TRIGGER_VOICE')),
        _step(5, 'Scroll down and fill in the Package field:', child: _codeCard('com.example.road_mate_flutter')),
        _step(6, 'Fill in the Class field:', child: _codeCard('com.example.road_mate_flutter.MainActivity')),
        _step(7, 'Leave all other fields (Categories, MIME, Data, Extras) empty.'),
        _step(8, 'Tap the save icon (top right). Voice will now start in the background.'),
      ];

  List<Widget> _iosSteps() => [
        _sectionHeader('Single Press — Start Voice'),
        const SizedBox(height: 8),
        _step(1, 'Open the Flic app and select your button.'),
        _step(2, 'Tap "Click" (single press) → "App Link".'),
        _step(3, 'Enter the following URL:', child: _urlCard('roadmate://voice')),
        _step(4, 'Tap Save. The button will open RoadMate and start voice mode.'),
      ];

  Widget _holdSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('Hold Press — Bring App to Foreground'),
          const SizedBox(height: 8),
          _step(1, 'In the Flic app, tap "Hold".'),
          _step(2, 'Choose "Launch App" from the action list (scroll down if needed).'),
          _step(3, 'Select RoadMate from the installed apps list.'),
          _step(4, 'Tap the save icon. Holding the button will open RoadMate.'),
        ],
      );

  Widget _sectionHeader(String title) => Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      );

  Widget _step(int n, String text, {Widget? child}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 12,
              child: Text('$n', style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text),
                  if (child != null) ...[const SizedBox(height: 8), child],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _urlCard(String url) => _codeCard(url);

  Widget _codeCard(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: Colors.white,
          ),
        ),
      );
}
