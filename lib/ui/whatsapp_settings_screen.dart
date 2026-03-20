import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/whatsapp_baileys_service.dart';

class WhatsAppSettingsScreen extends StatefulWidget {
  const WhatsAppSettingsScreen({super.key});

  @override
  State<WhatsAppSettingsScreen> createState() => _WhatsAppSettingsScreenState();
}

class _WhatsAppSettingsScreenState extends State<WhatsAppSettingsScreen> {
  static const _pollInterval = Duration(seconds: 3);
  static const _waGreen = Color(0xFF25D366);

  WhatsAppBaileysStatus _status = WhatsAppBaileysStatus.disconnected();
  bool _loading = true;
  bool _actionInProgress = false;
  Timer? _pollTimer;

  // Pairing-by-code state
  final _phoneController = TextEditingController();
  String? _pairingCode;
  String? _pairingError;
  bool _requestingCode = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _phoneController.dispose();
    super.dispose();
  }

  // ── Polling ───────────────────────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _refresh(silent: true));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    final s = await WhatsAppBaileysService.instance.getStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      _loading = false;
      // If pairingCode appeared on server, show it.
      if (s.pairingCode != null && _pairingCode == null) {
        _pairingCode = s.pairingCode;
      }
    });
    if (!s.connected) {
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _requestCode() async {
    final phone = _phoneController.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.length < 7) {
      setState(() => _pairingError = 'Enter a valid phone number with country code');
      return;
    }

    setState(() {
      _requestingCode = true;
      _pairingCode = null;
      _pairingError = null;
    });

    _startPolling();
    try {
      final code = await WhatsAppBaileysService.instance.requestPairingCode(phone);
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _pairingCode = code;
        _pairingError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _pairingError = e.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Disconnect WhatsApp?'),
        content: const Text(
          'Your session will be removed from the server. '
          'You will need to pair again to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _actionInProgress = true);
    await WhatsAppBaileysService.instance.disconnect();
    setState(() {
      _actionInProgress = false;
      _pairingCode = null;
      _pairingError = null;
    });
    _stopPolling();
    await _refresh(silent: true);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Auto-Send'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildStatusCard(),
                const SizedBox(height: 16),
                if (_status.connected) _buildConnectedInfo(),
                if (!_status.connected) _buildPairingSection(),
              ],
            ),
    );
  }

  // ── Status card ───────────────────────────────────────────────────────────

  Widget _buildStatusCard() {
    final connected = _status.connected;
    final color = connected ? Colors.green.shade600 : Colors.grey.shade500;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              connected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: color,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'WhatsApp Auto-Send',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    connected
                        ? 'Connected${_status.phone != null ? " · +${_status.phone}" : ""}'
                        : 'Not connected',
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (connected)
              TextButton(
                onPressed: _actionInProgress ? null : _disconnect,
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Disconnect'),
              ),
          ],
        ),
      ),
    );
  }

  // ── Connected info ────────────────────────────────────────────────────────

  Widget _buildConnectedInfo() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.green),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'RoadMate can now send WhatsApp messages automatically. '
              'The session lives on the server and reconnects after restarts.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  // ── Pairing section ───────────────────────────────────────────────────────

  Widget _buildPairingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Error card
        if (_status.lastError != null) ...[
          _buildErrorCard(_status.lastError!),
          const SizedBox(height: 16),
        ],

        // ── Phone number input + Get code button ──
        if (_pairingCode == null) ...[
          const Text(
            'Enter your WhatsApp phone number to get a pairing code:',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Phone number',
              hintText: '+1 555 123 4567',
              prefixIcon: const Icon(Icons.phone),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => _requestCode(),
          ),
          if (_pairingError != null) ...[
            const SizedBox(height: 8),
            _buildErrorCard(_pairingError!),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _requestingCode ? null : _requestCode,
              icon: _requestingCode
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.key),
              label: Text(_requestingCode ? 'Requesting code…' : 'Get pairing code'),
              style: FilledButton.styleFrom(
                backgroundColor: _waGreen,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],

        // ── Code display ──
        if (_pairingCode != null) ...[
          const Text(
            'Enter this code in WhatsApp:',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _pairingCode!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Code copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: _waGreen.withAlpha(15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _waGreen, width: 2),
              ),
              child: Column(
                children: [
                  Text(
                    _pairingCode!,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.copy, size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                        'Tap to copy',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Instructions
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How to enter the code in WhatsApp:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                SizedBox(height: 8),
                _Step(n: '1', text: 'Open WhatsApp on your phone'),
                _Step(n: '2', text: 'Tap ⋮  →  Linked devices'),
                _Step(n: '3', text: 'Tap "Link a device"'),
                _Step(n: '4', text: 'Tap "Link with phone number" (bottom of screen)'),
                _Step(n: '5', text: 'Enter your number, then type the code above'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                'Waiting for confirmation…',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _pairingCode = null;
                  _pairingError = null;
                }),
                child: const Text('Try again'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildErrorCard(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade400, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red.shade700, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final String n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
              color: Color(0xFF25D366),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(n,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
