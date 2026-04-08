import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/calendar.dart';
import '../services/gmail_client.dart';
import '../services/gcalendar_client.dart';
import '../config.dart';

class ExtensionsSettingsScreen extends StatefulWidget {
  const ExtensionsSettingsScreen({super.key});

  @override
  State<ExtensionsSettingsScreen> createState() => _ExtensionsSettingsScreenState();
}

class _ExtensionsSettingsScreenState extends State<ExtensionsSettingsScreen> {
  bool _loading = false;
  String? _clientId;

  // ── Apple Calendar (mobile only) ─────────────────────────────────────────
  bool _appleCalendarEnabled = false;
  bool _appleCalendarPermissionGranted = false;

  // ── Google Calendar ──────────────────────────────────────────────────────
  bool _gCalendarEnabled = false;
  bool _gCalendarAuthorized = false;
  bool _gCalendarChecking = false;

  // ── Calendar source (mobile only) ────────────────────────────────────────
  // 'apple' | 'google'
  String _calendarSource = 'apple';

  // ── Gmail ────────────────────────────────────────────────────────────────
  bool _gmailEnabled = false;
  bool _gmailAuthorized = false;
  bool _gmailChecking = false;

  static const String _prefKeyAppleCalendarEnabled = 'calendar_extension_enabled';
  static const String _prefKeyGCalendarEnabled = 'gcalendar_extension_enabled';
  static const String _prefKeyGmailEnabled = 'gmail_extension_enabled';
  static const String _prefKeyCalendarSource = 'calendar_source';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  GmailClient _gmailClient() =>
      GmailClient(baseUrl: Config.serverUrl, clientId: _clientId);

  GCalendarClient _gCalendarClient() =>
      GCalendarClient(baseUrl: Config.serverUrl, clientId: _clientId);

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _appleCalendarEnabled = prefs.getBool(_prefKeyAppleCalendarEnabled) ?? false;
      _gCalendarEnabled = prefs.getBool(_prefKeyGCalendarEnabled) ?? false;
      _gmailEnabled = prefs.getBool(_prefKeyGmailEnabled) ?? false;
      _calendarSource = prefs.getString(_prefKeyCalendarSource) ?? 'apple';
      _clientId = prefs.getString(Config.prefKeyClientId);
    });

    if (!kIsWeb) await _checkAppleCalendarPermissions();
    await _checkGCalendarAuthorization();
    await _checkGmailAuthorization();
  }

  // ── Apple Calendar ────────────────────────────────────────────────────────

  Future<void> _checkAppleCalendarPermissions() async {
    final hasPermission = await CalendarStore.hasPermissions();
    if (mounted) setState(() => _appleCalendarPermissionGranted = hasPermission);
  }

  Future<void> _toggleAppleCalendar(bool value) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      if (value) {
        final granted = await CalendarStore.requestPermissions();
        setState(() {
          _appleCalendarPermissionGranted = granted;
          _appleCalendarEnabled = granted;
        });
        if (!granted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Calendar permission is required to enable this feature'),
            backgroundColor: Colors.orange,
          ));
        }
      } else {
        setState(() => _appleCalendarEnabled = false);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyAppleCalendarEnabled, _appleCalendarEnabled);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Google Calendar ───────────────────────────────────────────────────────

  Future<void> _checkGCalendarAuthorization() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) setState(() => _gCalendarAuthorized = false);
      return;
    }
    if (_gCalendarChecking) return;
    if (mounted) setState(() => _gCalendarChecking = true);
    try {
      final authorized = await _gCalendarClient().isAuthorized();
      if (mounted) setState(() => _gCalendarAuthorized = authorized);
    } catch (_) {
      if (mounted) setState(() => _gCalendarAuthorized = false);
    } finally {
      if (mounted) setState(() => _gCalendarChecking = false);
    }
  }

  Future<void> _authorizeGCalendarInBrowser() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Client id not initialized. Restart the app.'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }
    final uri = Uri.parse(
        '${Config.serverUrl}/oauth/google/calendar/start?client_id=$_clientId');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open browser for Google Calendar authorization.'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _toggleGCalendar(bool value) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _gCalendarEnabled = value;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyGCalendarEnabled, _gCalendarEnabled);
      if (_gCalendarEnabled) await _checkGCalendarAuthorization();

      // On web, Google Calendar is the only option — always set source to 'google'.
      if (kIsWeb && _gCalendarEnabled) {
        await prefs.setString(_prefKeyCalendarSource, 'google');
        if (mounted) setState(() => _calendarSource = 'google');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Calendar source (mobile only) ─────────────────────────────────────────

  Future<void> _setCalendarSource(String source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyCalendarSource, source);
    if (mounted) setState(() => _calendarSource = source);
  }

  // ── Gmail ─────────────────────────────────────────────────────────────────

  Future<void> _checkGmailAuthorization() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) setState(() => _gmailAuthorized = false);
      return;
    }
    if (_gmailChecking) return;
    if (mounted) setState(() => _gmailChecking = true);
    try {
      await _gmailClient().searchStructured(
          unreadOnly: true, newerThanDays: 7, maxResults: 1);
      if (mounted) setState(() => _gmailAuthorized = true);
    } catch (e) {
      if (mounted) {
        setState(() => _gmailAuthorized = !e.toString().contains('Not authorized'));
      }
    } finally {
      if (mounted) setState(() => _gmailChecking = false);
    }
  }

  Future<void> _authorizeGmailInBrowser() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Client id not initialized. Restart the app.'),
          backgroundColor: Colors.red,
        ));
      }
      return;
    }
    final uri = Uri.parse(
        '${Config.serverUrl}/oauth/google/start?client_id=$_clientId');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open browser for Gmail authorization.'),
        backgroundColor: Colors.red,
      ));
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
      if (_gmailEnabled) await _checkGmailAuthorization();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Widget _spinner() => const SizedBox(
      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Extensions')),
      body: ListView(
        children: [
          // ── Apple Calendar section (mobile only) ──────────────────────────
          if (!kIsWeb) ...[
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('Apple Calendar'),
              subtitle: Text(
                _appleCalendarPermissionGranted
                    ? 'Access to device calendar enabled'
                    : 'Calendar permission not granted',
              ),
              trailing: _loading
                  ? _spinner()
                  : Switch(
                      value: _appleCalendarEnabled,
                      onChanged: _toggleAppleCalendar,
                    ),
            ),
            if (!_appleCalendarPermissionGranted && _appleCalendarEnabled)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'Grant calendar permission in iOS Settings to use this feature.',
                  style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
                ),
              ),
            const Divider(height: 1),
          ],

          // ── Google Calendar section ────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.event_note),
            title: const Text('Google Calendar'),
            subtitle: Text(
              _clientId == null || _clientId!.isEmpty
                  ? 'Client id not initialized'
                  : (_gCalendarChecking
                      ? 'Checking authorization…'
                      : (_gCalendarAuthorized
                          ? 'Authorized'
                          : 'Not authorized — tap Authorize')),
            ),
            trailing: _loading
                ? _spinner()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed:
                            _gCalendarEnabled ? _authorizeGCalendarInBrowser : null,
                        child: const Text('Authorize'),
                      ),
                      if (!kIsWeb)
                        TextButton(
                          onPressed: _gCalendarEnabled
                              ? _checkGCalendarAuthorization
                              : null,
                          child: const Text('Refresh'),
                        ),
                      Switch(
                        value: _gCalendarEnabled,
                        onChanged: _toggleGCalendar,
                      ),
                    ],
                  ),
          ),
          if (_gCalendarEnabled && !_gCalendarAuthorized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _clientId == null || _clientId!.isEmpty
                    ? 'Client id not initialized yet. Restart the app.'
                    : 'Open the Authorize link in your browser, sign in with Google, then return here.',
                style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
              ),
            ),
          if (_gCalendarEnabled && _gCalendarAuthorized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Google Calendar is connected.',
                style: TextStyle(color: Colors.green.shade700, fontSize: 12),
              ),
            ),

          // ── Calendar source selector (mobile only, shown when both are set up) ──
          if (!kIsWeb && _appleCalendarEnabled && _gCalendarEnabled) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Calendar source',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'apple',
                    label: Text('Apple Calendar'),
                    icon: Icon(Icons.calendar_today, size: 16),
                  ),
                  ButtonSegment(
                    value: 'google',
                    label: Text('Google Calendar'),
                    icon: Icon(Icons.event_note, size: 16),
                  ),
                ],
                selected: {_calendarSource},
                onSelectionChanged: (s) => _setCalendarSource(s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                _calendarSource == 'google'
                    ? 'RoadMate will read and write events via your Google account.'
                    : 'RoadMate will read and write events from your iPhone\'s Calendar app.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          ],

          // Show a hint if only Google Calendar is enabled (no source selector needed)
          if (!kIsWeb && !_appleCalendarEnabled && _gCalendarEnabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'Using Google Calendar as the calendar source.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          ],

          const Divider(height: 1),

          // ── Gmail section ─────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Gmail'),
            subtitle: Text(
              _clientId == null || _clientId!.isEmpty
                  ? 'Client id not initialized'
                  : (_gmailChecking
                      ? 'Checking authorization…'
                      : (_gmailAuthorized
                          ? 'Authorized'
                          : 'Not authorized — tap Authorize')),
            ),
            trailing: _loading
                ? _spinner()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed:
                            _gmailEnabled ? _authorizeGmailInBrowser : null,
                        child: const Text('Authorize'),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _clientId == null || _clientId!.isEmpty
                    ? 'Client id not initialized yet. Restart the app.'
                    : 'Open the Authorize link in your browser, sign in with Google, then return here.',
                style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
              ),
            ),
          if (_gmailEnabled && _gmailAuthorized)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Gmail is connected.',
                style: TextStyle(color: Colors.green.shade700, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
