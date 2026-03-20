import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/calendar.dart';
import '../services/gmail_client.dart';
import '../services/youtube_client.dart';
import '../config.dart';

class ExtensionsSettingsScreen extends StatefulWidget {
  const ExtensionsSettingsScreen({super.key});

  @override
  State<ExtensionsSettingsScreen> createState() => _ExtensionsSettingsScreenState();
}

class _ExtensionsSettingsScreenState extends State<ExtensionsSettingsScreen> {
  bool _calendarEnabled = false;
  bool _calendarPermissionGranted = false;
  bool _loading = false;

  bool _gmailEnabled = false;
  bool _gmailAuthorized = false;
  bool _gmailChecking = false;
  String? _clientId;

  bool _youtubeEnabled = false;
  bool _youtubeAuthorized = false;
  bool _youtubeChecking = false;

  static const String _prefKeyCalendarEnabled = 'calendar_extension_enabled';
  static const String _prefKeyGmailEnabled = 'gmail_extension_enabled';
  static const String _prefKeyYoutubeEnabled = 'youtube_extension_enabled';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _calendarEnabled = prefs.getBool(_prefKeyCalendarEnabled) ?? false;
      _gmailEnabled = prefs.getBool(_prefKeyGmailEnabled) ?? false;
      _youtubeEnabled = prefs.getBool(_prefKeyYoutubeEnabled) ?? false;
      _clientId = prefs.getString(Config.prefKeyClientId);
    });
    await _checkCalendarPermissions();
    await _checkGmailAuthorization();
    await _checkYouTubeAuthorization();
  }

  YouTubeClient _youtubeClient() {
    return YouTubeClient(baseUrl: Config.serverUrl, clientId: _clientId);
  }

  Future<void> _checkYouTubeAuthorization() async {
    if (_clientId == null || _clientId!.isEmpty) {
      setState(() {
        _youtubeAuthorized = false;
      });
      return;
    }
    if (_youtubeChecking) return;
    setState(() {
      _youtubeChecking = true;
    });

    try {
      await _youtubeClient().getSubscriptionsFeed();
      if (mounted) {
        setState(() {
          _youtubeAuthorized = true;
        });
      }
    } catch (e) {
      final msg = e.toString();
      if (mounted) {
        setState(() {
          _youtubeAuthorized = !msg.contains('Not authorized');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _youtubeChecking = false;
        });
      }
    }
  }

  Future<void> _authorizeYouTubeInBrowser() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Client id is not initialized yet. Please restart the app.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    final uri = Uri.parse('${Config.serverUrl}/oauth/youtube/start?client_id=$_clientId');

    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open browser for YouTube authorization.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _toggleYouTube(bool value) async {
    if (_loading) return;

    setState(() {
      _loading = true;
      _youtubeEnabled = value;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyYoutubeEnabled, _youtubeEnabled);

      if (_youtubeEnabled) {
        await _checkYouTubeAuthorization();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  GmailClient _gmailClient() {
    return GmailClient(baseUrl: Config.serverUrl, clientId: _clientId);
  }

  Future<void> _checkGmailAuthorization() async {
    if (_clientId == null || _clientId!.isEmpty) {
      setState(() {
        _gmailAuthorized = false;
      });
      return;
    }
    if (_gmailChecking) return;
    setState(() {
      _gmailChecking = true;
    });

    try {
      // Lightweight probe: if the server isn't authorized, it should error with "Not authorized".
      await _gmailClient().searchStructured(
        unreadOnly: true,
        newerThanDays: 7,
        maxResults: 1,
      );
      if (mounted) {
        setState(() {
          _gmailAuthorized = true;
        });
      }
    } catch (e) {
      final msg = e.toString();
      if (mounted) {
        setState(() {
          // Treat "Not authorized" as expected initial state.
          _gmailAuthorized = !msg.contains('Not authorized');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _gmailChecking = false;
        });
      }
    }
  }

  Future<void> _authorizeGmailInBrowser() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Client id is not initialized yet. Please restart the app.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    final uri = Uri.parse('${Config.serverUrl}/oauth/google/start?client_id=$_clientId');

    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open browser for Gmail authorization.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _testGmail() async {
    try {
      await testGmailClient(_gmailClient());
      // Re-check status after test.
      await _checkGmailAuthorization();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gmail test completed. Check logs for details.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gmail test failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _toggleGmail(bool value) async {
    if (_loading) return;

    setState(() {
      _loading = true;
      _gmailEnabled = value;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyGmailEnabled, _gmailEnabled);

      if (_gmailEnabled) {
        // If enabling, immediately check auth so UI is informative.
        await _checkGmailAuthorization();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _checkCalendarPermissions() async {
    final hasPermission = await CalendarStore.hasPermissions();
    setState(() {
      _calendarPermissionGranted = hasPermission;
    });
  }

  Future<void> _toggleCalendar(bool value) async {
    if (_loading) return;

    setState(() {
      _loading = true;
    });

    try {
      if (value) {
        // Request permissions when enabling
        final granted = await CalendarStore.requestPermissions();
        setState(() {
          _calendarPermissionGranted = granted;
          _calendarEnabled = granted; // Only enable if permission granted
        });

        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Calendar permission is required to enable this feature'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } else {
        setState(() {
          _calendarEnabled = false;
        });
      }

      // Save state
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyCalendarEnabled, _calendarEnabled);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Extensions'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.calendar_today),
            title: const Text('Calendar'),
            subtitle: Text(
              _calendarPermissionGranted
                  ? 'Access to calendar data enabled'
                  : 'Calendar permission not granted',
            ),
            trailing: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Switch(
                    value: _calendarEnabled,
                    onChanged: _toggleCalendar,
                  ),
          ),
          
          if (!_calendarPermissionGranted && _calendarEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Please grant calendar permission in system settings to use this feature.',
                style: TextStyle(
                  color: Colors.orange.shade700,
                  fontSize: 12,
                ),
              ),
            ),
          
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Gmail'),
            subtitle: Text(
              _clientId == null || _clientId!.isEmpty
                  ? 'Client id not initialized'
                  : (_gmailChecking
                      ? 'Checking authorization…'
                      : (_gmailAuthorized
                          ? 'Authorized on server'
                          : 'Not authorized (tap Authorize)')),
            ),
            trailing: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _gmailEnabled ? _authorizeGmailInBrowser : null,
                        child: const Text('Authorize'),
                      ),
                      TextButton(
                        onPressed: _gmailEnabled ? _testGmail : null,
                        child: const Text('Test'),
                      ),
                      Switch(
                        value: _gmailEnabled,
                        onChanged: _toggleGmail,
                      ),
                    ],
                  ),
          ),
          if (_gmailEnabled && !_gmailAuthorized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _clientId == null || _clientId!.isEmpty
                    ? 'Client id not initialized yet. Restart the app.'
                    : 'Authorize Gmail in a browser: ${Config.serverUrl}/oauth/google/start?client_id=$_clientId',
                style: TextStyle(
                  color: Colors.orange.shade700,
                  fontSize: 12,
                ),
              ),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('YouTube'),
            subtitle: Text(
              _clientId == null || _clientId!.isEmpty
                  ? 'Client id not initialized'
                  : (_youtubeChecking
                      ? 'Checking authorization…'
                      : (_youtubeAuthorized
                          ? 'Authorized on server'
                          : 'Not authorized (tap Authorize)')),
            ),
            trailing: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _youtubeEnabled ? _authorizeYouTubeInBrowser : null,
                        child: const Text('Authorize'),
                      ),
                      Switch(
                        value: _youtubeEnabled,
                        onChanged: _toggleYouTube,
                      ),
                    ],
                  ),
          ),
          if (_youtubeEnabled && !_youtubeAuthorized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _clientId == null || _clientId!.isEmpty
                    ? 'Client id not initialized yet. Restart the app.'
                    : 'Authorize YouTube in a browser: ${Config.serverUrl}/oauth/youtube/start?client_id=$_clientId',
                style: TextStyle(
                  color: Colors.orange.shade700,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
