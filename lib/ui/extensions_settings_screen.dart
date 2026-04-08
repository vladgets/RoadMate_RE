import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/calendar.dart';
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

  // ── Shared Google connection status ──────────────────────────────────────
  bool _googleConnected = false;
  bool _googleChecking = false;

  // ── Per-service toggles ──────────────────────────────────────────────────
  bool _gmailEnabled = false;
  bool _gCalendarEnabled = false;

  // ── Apple Calendar (mobile only) ─────────────────────────────────────────
  bool _appleCalendarEnabled = false;
  bool _appleCalendarPermissionGranted = false;

  // ── Calendar source (mobile only): 'apple' | 'google' ───────────────────
  String _calendarSource = 'apple';

  static const _prefGmailEnabled = 'gmail_extension_enabled';
  static const _prefGCalendarEnabled = 'gcalendar_extension_enabled';
  static const _prefAppleCalendarEnabled = 'calendar_extension_enabled';
  static const _prefCalendarSource = 'calendar_source';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  GCalendarClient _gClient() =>
      GCalendarClient(baseUrl: Config.serverUrl, clientId: _clientId);

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _gmailEnabled = prefs.getBool(_prefGmailEnabled) ?? false;
      _gCalendarEnabled = prefs.getBool(_prefGCalendarEnabled) ?? false;
      _appleCalendarEnabled = prefs.getBool(_prefAppleCalendarEnabled) ?? false;
      _calendarSource = prefs.getString(_prefCalendarSource) ?? 'apple';
      _clientId = prefs.getString(Config.prefKeyClientId);
    });

    if (_isIOS) await _checkAppleCalendarPermissions();
    await _checkGoogleConnection();
  }

  // ── Google connection ─────────────────────────────────────────────────────

  Future<void> _checkGoogleConnection() async {
    if (_clientId == null || _clientId!.isEmpty) {
      if (mounted) setState(() => _googleConnected = false);
      return;
    }
    if (_googleChecking) return;
    if (mounted) setState(() => _googleChecking = true);
    try {
      final connected = await _gClient().isAuthorized();
      if (mounted) setState(() => _googleConnected = connected);
    } catch (_) {
      if (mounted) setState(() => _googleConnected = false);
    } finally {
      if (mounted) setState(() => _googleChecking = false);
    }
  }

  Future<void> _authorizeGoogleInBrowser() async {
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
        content: Text('Could not open browser for Google authorization.'),
        backgroundColor: Colors.red,
      ));
    }
  }

  // ── Per-service toggles ───────────────────────────────────────────────────

  Future<void> _toggleGmail(bool value) async {
    setState(() => _gmailEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefGmailEnabled, value);
  }

  Future<void> _toggleGCalendar(bool value) async {
    setState(() => _gCalendarEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefGCalendarEnabled, value);

    // On web always keep calendar_source = 'google'
    if (kIsWeb && value) {
      await prefs.setString(_prefCalendarSource, 'google');
      if (mounted) setState(() => _calendarSource = 'google');
    }
  }

  // ── Apple Calendar ────────────────────────────────────────────────────────

  Future<void> _checkAppleCalendarPermissions() async {
    final has = await CalendarStore.hasPermissions();
    if (mounted) setState(() => _appleCalendarPermissionGranted = has);
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
      await prefs.setBool(_prefAppleCalendarEnabled, _appleCalendarEnabled);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Calendar source ───────────────────────────────────────────────────────

  Future<void> _setCalendarSource(String source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCalendarSource, source);
    if (mounted) setState(() => _calendarSource = source);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Widget _spinner() => const SizedBox(
      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

  @override
  Widget build(BuildContext context) {
    final googleServices = _googleConnected
        ? 'Gmail and Google Calendar available'
        : (_googleChecking ? 'Checking…' : 'Not connected — tap Connect');

    return Scaffold(
      appBar: AppBar(title: const Text('Extensions')),
      body: ListView(
        children: [
          // ── Google Account ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('Google Account'),
            subtitle: Text(
              _clientId == null || _clientId!.isEmpty
                  ? 'Client id not initialized'
                  : googleServices,
            ),
            trailing: _googleChecking
                ? _spinner()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _authorizeGoogleInBrowser,
                        child: Text(_googleConnected ? 'Reconnect' : 'Connect'),
                      ),
                      if (_googleConnected)
                        TextButton(
                          onPressed: _checkGoogleConnection,
                          child: const Text('Refresh'),
                        ),
                    ],
                  ),
          ),
          if (_googleConnected)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Google account is connected.',
                style: TextStyle(color: Colors.green.shade700, fontSize: 12),
              ),
            ),
          if (!_googleConnected && !_googleChecking)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _clientId == null || _clientId!.isEmpty
                    ? 'Client id not initialized yet. Restart the app.'
                    : 'Connect your Google account to enable Gmail and Google Calendar.',
                style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
              ),
            ),

          // ── Gmail toggle (only meaningful when Google is connected) ────────
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.mail_outline),
            title: const Text('Gmail'),
            subtitle: Text(_googleConnected
                ? 'Read emails by voice'
                : 'Connect Google account first'),
            value: _gmailEnabled,
            onChanged: _googleConnected ? _toggleGmail : null,
          ),

          // ── Google Calendar toggle ────────────────────────────────────────
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.event_note),
            title: const Text('Google Calendar'),
            subtitle: Text(_googleConnected
                ? 'Read and create calendar events'
                : 'Connect Google account first'),
            value: _gCalendarEnabled,
            onChanged: _googleConnected ? _toggleGCalendar : null,
          ),

          // ── Apple Calendar (iOS only) ─────────────────────────────────────
          if (_isIOS) ...[
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.calendar_today),
              title: const Text('Apple Calendar'),
              subtitle: Text(_appleCalendarPermissionGranted
                  ? 'Read device calendar events'
                  : 'Tap to grant calendar permission'),
              value: _appleCalendarEnabled,
              onChanged: _loading ? null : _toggleAppleCalendar,
            ),
            if (!_appleCalendarPermissionGranted && _appleCalendarEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Grant calendar permission in iOS Settings.',
                  style: TextStyle(color: Colors.orange.shade700, fontSize: 12),
                ),
              ),
          ],

          // ── Calendar source selector (mobile, when both enabled) ───────────
          if (_isIOS && _appleCalendarEnabled && _gCalendarEnabled) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Active calendar source',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'apple',
                    label: Text('Apple'),
                    icon: Icon(Icons.calendar_today, size: 16),
                  ),
                  ButtonSegment(
                    value: 'google',
                    label: Text('Google'),
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
                    ? 'RoadMate reads and writes events via your Google account.'
                    : 'RoadMate reads and writes events from your iPhone\'s Calendar app.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
