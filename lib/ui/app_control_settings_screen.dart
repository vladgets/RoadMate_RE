import 'dart:io';
import 'package:flutter/material.dart';
import '../services/app_control_service.dart';

class AppControlSettingsScreen extends StatefulWidget {
  const AppControlSettingsScreen({super.key});

  @override
  State<AppControlSettingsScreen> createState() => _AppControlSettingsScreenState();
}

class _AppControlSettingsScreenState extends State<AppControlSettingsScreen>
    with WidgetsBindingObserver {
  bool _accessibilityEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check only on resumed — not on inactive, which fires during brief
  // interruptions (notification shade, screen dim) and causes false negatives.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    if (!mounted) return;
    final enabled = await AppControlService.instance.isAccessibilityEnabled();
    if (!mounted) return;
    setState(() {
      _accessibilityEnabled = enabled;
      _loading = false;
    });
    if (enabled) {
      AppControlService.instance.startListening();
    }
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      // Show explanation before redirecting
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enable App Voice Control'),
          content: const Text(
            'RoadMate will be able to tap buttons in other apps on your behalf '
            'when you ask by voice.\n\n'
            'No data from other apps is stored or transmitted.\n\n'
            'You will be taken to Android Accessibility Settings. '
            'Find "RoadMate" in the list and enable it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await AppControlService.instance.openAccessibilitySettings();
        // Re-check immediately after returning from system settings
        await _checkStatus();
      }
    } else {
      AppControlService.instance.stopListening();
      // The user must disable it manually in Android Accessibility Settings.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('To fully disable, remove RoadMate from Android Accessibility Settings.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Control'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (!isAndroid)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'App Voice Control is only available on Android.',
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  )
                else ...[
                  SwitchListTile(
                    secondary: Icon(
                      Icons.accessibility_new,
                      color: _accessibilityEnabled ? Colors.green : Colors.grey,
                    ),
                    title: const Text('Enable App Voice Control'),
                    subtitle: Text(
                      _accessibilityEnabled
                          ? 'Active — RoadMate can tap buttons in other apps'
                          : 'Permission required — tap to open Accessibility Settings',
                    ),
                    value: _accessibilityEnabled,
                    onChanged: _onToggle,
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          _accessibilityEnabled
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: _accessibilityEnabled ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _accessibilityEnabled ? 'Status: Active' : 'Status: Permission required',
                          style: TextStyle(
                            color: _accessibilityEnabled ? Colors.green : Colors.red,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('How it works'),
                    subtitle: Text(
                      'Say "confirm", "yes", "skip", "dismiss", or "tap OK in Waze" while '
                      'another app has a button on screen. RoadMate will find and tap it for you.',
                    ),
                    isThreeLine: true,
                  ),
                  const ListTile(
                    leading: Icon(Icons.security),
                    title: Text('Privacy'),
                    subtitle: Text(
                      'RoadMate only taps buttons you explicitly request. '
                      'No data from other apps is stored or transmitted.',
                    ),
                    isThreeLine: true,
                  ),
                ],
              ],
            ),
    );
  }
}
