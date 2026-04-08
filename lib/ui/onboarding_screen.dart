import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config.dart';
import 'fub_identity_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> with WidgetsBindingObserver {
  bool _microphoneGranted = false;
  bool _locationGranted = false;
  bool _calendarGranted = false;
  bool _notificationsGranted = false;

  String? _selectedAgentName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialPermissions();
    _selectedAgentName = Config.fubAgentName;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkInitialPermissions();
    }
  }

  Future<void> _checkInitialPermissions() async {
    final mic = await Permission.microphone.status;
    final loc = await Permission.location.status;
    final cal = await Permission.calendarFullAccess.status;
    final notif = await Permission.notification.status;

    setState(() {
      _microphoneGranted = mic.isGranted;
      _locationGranted = loc.isGranted;
      _calendarGranted = cal.isGranted;
      _notificationsGranted = notif.isGranted;
    });
  }

  Future<void> _requestPermission(
    Permission permission,
    void Function(bool) onResult,
  ) async {
    var status = await permission.request();
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      status = await permission.status;
    }
    onResult(status.isGranted);
  }

  Future<void> _requestMicrophone() async {
    await _requestPermission(Permission.microphone, (granted) {
      setState(() => _microphoneGranted = granted);
    });
  }

  Future<void> _requestLocation() async {
    await _requestPermission(Permission.location, (granted) {
      setState(() => _locationGranted = granted);
    });
  }

  Future<void> _requestCalendar() async {
    await _requestPermission(Permission.calendarFullAccess, (granted) {
      setState(() => _calendarGranted = granted);
    });
  }

  Future<void> _requestNotifications() async {
    await _requestPermission(Permission.notification, (granted) {
      setState(() => _notificationsGranted = granted);
    });
  }

  Future<void> _openCrmIdentity() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FubIdentityScreen(standalone: true)),
    );
    // Refresh displayed name after returning
    setState(() => _selectedAgentName = Config.fubAgentName);
  }

  Future<void> _completeOnboarding() async {
    if (!_microphoneGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission is required to use RoadMate'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasCompletedOnboarding', true);

    if (mounted) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed('/main');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),

              // Welcome
              const Text(
                '👋 Welcome to RoadMate',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your AI voice assistant built for real estate agents — manage clients, schedule showings, and stay on top of your CRM, all hands-free.',
                style: TextStyle(fontSize: 18, color: Colors.grey, height: 1.4),
              ),

              const SizedBox(height: 48),

              // Permissions
              const Text(
                'Permissions',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Grant access to the features you want RoadMate to help with:',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 24),

              _buildPermissionTile(
                icon: Icons.mic,
                title: 'Microphone',
                subtitle: 'Required — voice is how you talk to RoadMate',
                isGranted: _microphoneGranted,
                isRequired: true,
                onTap: _requestMicrophone,
              ),
              _buildPermissionTile(
                icon: Icons.location_on,
                title: 'Location',
                subtitle: 'Navigate to properties and client addresses',
                isGranted: _locationGranted,
                isRequired: false,
                onTap: _requestLocation,
              ),
              _buildPermissionTile(
                icon: Icons.calendar_today,
                title: 'Calendar',
                subtitle: 'Manage showings, closings, and appointments',
                isGranted: _calendarGranted,
                isRequired: false,
                onTap: _requestCalendar,
              ),
              _buildPermissionTile(
                icon: Icons.notifications,
                title: 'Notifications',
                subtitle: 'Get reminders for follow-ups and deadlines',
                isGranted: _notificationsGranted,
                isRequired: false,
                onTap: _requestNotifications,
              ),

              const SizedBox(height: 48),

              // CRM Identity
              const Text(
                'Who are you?',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Set your CRM identity so RoadMate knows which agent you are.',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 16),

              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _selectedAgentName != null
                        ? Colors.green
                        : Colors.grey.shade300,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  leading: CircleAvatar(
                    backgroundColor: _selectedAgentName != null
                        ? Colors.green
                        : Colors.grey.shade200,
                    child: _selectedAgentName != null
                        ? Text(
                            _selectedAgentName![0].toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          )
                        : Icon(Icons.person_outline,
                            color: Colors.grey.shade500),
                  ),
                  title: Text(
                    _selectedAgentName ?? 'Select your name',
                    style: TextStyle(
                      fontWeight: _selectedAgentName != null
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: _selectedAgentName != null
                          ? null
                          : Colors.grey,
                    ),
                  ),
                  subtitle: Text(_selectedAgentName != null
                      ? 'Tap to change'
                      : 'You can also set this later in Settings'),
                  trailing: _selectedAgentName != null
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : const Icon(Icons.chevron_right),
                  onTap: _openCrmIdentity,
                ),
              ),

              const SizedBox(height: 48),

              // Example commands
              const Text(
                'Try saying:',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildExampleCommand('"Who are my most recent clients?"'),
              _buildExampleCommand('"Add a note for Sarah — showed two properties today"'),
              _buildExampleCommand('"What\'s on my schedule tomorrow?"'),
              _buildExampleCommand('"Navigate to 742 Evergreen Terrace"'),
              _buildExampleCommand('"Remind me to follow up with John at 5 PM"'),

              const SizedBox(height: 48),

              // Get Started button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _completeOnboarding,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    Navigator.of(context).canPop() ? 'Done' : 'Get Started',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'You can connect Gmail, Google Calendar, and your CRM later in Settings',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
    required bool isRequired,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(
          color: isGranted ? Colors.green : Colors.grey.shade300,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon,
            color: isGranted ? Colors.green : Colors.grey, size: 28),
        title: Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            if (isRequired) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Required',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle),
        trailing: isGranted
            ? const Icon(Icons.check_circle, color: Colors.green)
            : TextButton(onPressed: onTap, child: const Text('Grant')),
      ),
    );
  }

  Widget _buildExampleCommand(String command) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic, color: Colors.blue, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(command,
                style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic)),
          ),
        ],
      ),
    );
  }
}
