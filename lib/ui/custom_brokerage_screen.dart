import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config.dart';

/// Screen for connecting a personal Follow Up Boss account via API key.
/// The key and subdomain are stored locally and sent to the server so it can
/// proxy FUB requests using the agent's own credentials.
class CustomBrokerageScreen extends StatefulWidget {
  const CustomBrokerageScreen({super.key});

  @override
  State<CustomBrokerageScreen> createState() => _CustomBrokerageScreenState();
}

class _CustomBrokerageScreenState extends State<CustomBrokerageScreen> {
  final _apiKeyController = TextEditingController();
  final _subdomainController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Show current custom key (masked) and subdomain if already set
    if (Config.customFubApiKey != null) {
      final key = Config.customFubApiKey!;
      _apiKeyController.text = key.length > 8
          ? '${key.substring(0, 4)}...${key.substring(key.length - 4)}'
          : key;
    }
    if (Config.customFubSubdomain != null) {
      _subdomainController.text = Config.customFubSubdomain!;
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _subdomainController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final apiKey = _apiKeyController.text.trim();
    final subdomain = _subdomainController.text.trim().toLowerCase();

    if (apiKey.isEmpty) {
      setState(() => _error = 'API key is required');
      return;
    }
    if (subdomain.isEmpty) {
      setState(() => _error = 'Subdomain is required');
      return;
    }
    // Don't re-submit if the key is masked (unchanged)
    if (apiKey.contains('...') && Config.customFubApiKey != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No changes to save')),
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final clientId = Config.clientId;
      if (clientId == null) {
        setState(() {
          _error = 'Device ID not ready. Please restart the app.';
          _saving = false;
        });
        return;
      }

      final uri = Uri.parse('${Config.serverUrl}/fub/register_custom_key');
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-client-id': clientId,
        },
        body: jsonEncode({'api_key': apiKey, 'subdomain': subdomain}),
      );
      final body = jsonDecode(resp.body) as Map<String, dynamic>;

      if (body['ok'] == true) {
        final userName = body['name'] as String?;
        await Config.setCustomFub(apiKey, subdomain, userName: userName);
        await Config.clearFubAgent(); // remove any previously selected RB Brokerage identity
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected as ${userName ?? subdomain}')),
        );
      } else {
        setState(() {
          _error = body['error']?.toString() ?? 'Failed to validate API key';
          _saving = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Could not reach server. Check your connection.';
        _saving = false;
      });
    }
  }

  Future<void> _disconnect() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect'),
        content: const Text(
          'Remove your custom FUB account? The app will fall back to the default RB Brokerage connection.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final clientId = Config.clientId;
      if (clientId != null) {
        await http.delete(
          Uri.parse('${Config.serverUrl}/fub/register_custom_key'),
          headers: {'x-client-id': clientId},
        );
      }
    } catch (_) {}

    await Config.clearCustomFub();
    if (!mounted) return;
    setState(() {
      _apiKeyController.clear();
      _subdomainController.clear();
      _error = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Custom account disconnected')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = Config.customFubApiKey != null && Config.customFubApiKey!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Custom Brokerage')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isConnected) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade600),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Config.customFubUserName != null
                                ? 'Connected as ${Config.customFubUserName}'
                                : 'Connected',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade800,
                            ),
                          ),
                          if (Config.customFubSubdomain != null)
                            Text(
                              '${Config.customFubSubdomain}.followupboss.com',
                              style: TextStyle(fontSize: 13, color: Colors.green.shade700),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _disconnect,
                      child: const Text('Disconnect', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            Text(
              isConnected ? 'Update credentials' : 'Connect your Follow Up Boss account',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Find your API key in Follow Up Boss under Admin → API.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'FUB API Key',
                hintText: 'Paste your API key here',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _subdomainController,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Account Subdomain',
                hintText: 'e.g. smithrealty',
                helperText: 'The part before .followupboss.com in your FUB URL',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.domain_outlined),
              ),
              onSubmitted: (_) => _save(),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade600, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.link),
                label: Text(_saving ? 'Validating...' : (isConnected ? 'Update' : 'Connect')),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
