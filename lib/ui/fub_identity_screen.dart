import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config.dart';

/// Screen for selecting the agent's FUB identity from the brokerage user list.
/// Can be used standalone (from Settings) or embedded inside onboarding.
class FubIdentityScreen extends StatefulWidget {
  /// If true, shows an AppBar with a back button (settings flow).
  /// If false, renders as a card widget for embedding in onboarding.
  final bool standalone;

  const FubIdentityScreen({super.key, this.standalone = true});

  @override
  State<FubIdentityScreen> createState() => _FubIdentityScreenState();
}

class _FubIdentityScreenState extends State<FubIdentityScreen> {
  List<_FubUser> _users = [];
  bool _loading = true;
  String? _error;

  /// Currently saved agent (persisted in SharedPreferences).
  String? _savedName;
  int? _savedId;

  /// Tapped but not yet saved.
  _FubUser? _pendingUser;

  /// Passcode gate state.
  bool _authenticated = false;
  bool _checkingPasscode = false;
  String? _passcodeError;
  final _passcodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _savedName = Config.fubAgentName;
    _savedId = Config.fubAgentId;
    _authenticated = Config.fubAuthenticated;
    if (_authenticated) {
      _loadUsers();
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _passcodeController.dispose();
    super.dispose();
  }

  Future<void> _submitPasscode() async {
    final passcode = _passcodeController.text.trim();
    if (passcode.isEmpty) return;
    setState(() {
      _checkingPasscode = true;
      _passcodeError = null;
    });
    final ok = await Config.verifyFubPasscode(passcode);
    if (!mounted) return;
    if (ok) {
      await Config.setFubAuthenticated(true);
      setState(() {
        _authenticated = true;
        _checkingPasscode = false;
        _loading = true;
      });
      _loadUsers();
    } else {
      setState(() {
        _checkingPasscode = false;
        _passcodeError = 'Incorrect passcode. Please try again.';
      });
    }
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('${Config.serverUrl}/fub/users');
      final headers = <String, String>{
        if (Config.clientId != null) 'x-client-id': Config.clientId!,
      };
      final resp = await http.get(uri, headers: headers);
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['ok'] == true) {
        final list = (body['users'] as List).map((u) => _FubUser(
          id: u['id'] as int,
          name: u['name'] as String,
        )).toList();
        list.sort((a, b) => a.name.compareTo(b.name));
        setState(() {
          _users = list;
          _loading = false;
        });
      } else {
        setState(() {
          _error = body['error']?.toString() ?? 'Failed to load agents';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Could not reach server. Check your connection.';
        _loading = false;
      });
    }
  }

  void _onTap(_FubUser user) {
    setState(() {
      if (_pendingUser?.id == user.id) {
        // Tapping the already-pending user deselects it
        _pendingUser = null;
      } else if (_savedId == user.id && _pendingUser == null) {
        // Tapping the already-saved user when nothing is pending — no-op
      } else {
        _pendingUser = user;
      }
    });
  }

  Future<void> _save() async {
    final user = _pendingUser;
    if (user == null) return;
    await Config.setFubAgent(user.name, user.id);
    setState(() {
      _savedName = user.name;
      _savedId = user.id;
      _pendingUser = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Identity saved as ${user.name}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    if (!widget.standalone) return content;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CRM Identity'),
      ),
      body: content,
    );
  }

  Widget _buildContent() {
    if (!_authenticated) {
      return _buildPasscodeGate();
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadUsers, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final hasPending = _pendingUser != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            hasPending
                ? 'Tap Save to confirm: ${_pendingUser!.name}'
                : (_savedName != null
                    ? 'Signed in as $_savedName'
                    : 'Select your name from the brokerage team:'),
            style: TextStyle(
              fontSize: 14,
              color: hasPending
                  ? Colors.orange.shade700
                  : (_savedName != null ? Colors.green.shade700 : Colors.grey.shade700),
              fontWeight: (hasPending || _savedName != null) ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _users.length,
            separatorBuilder: (context2, i2) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final user = _users[i];
              final isSaved = user.id == _savedId;
              final isPending = user.id == _pendingUser?.id;

              Widget? trailing;
              Color avatarColor;
              Color textColor;

              if (isPending) {
                trailing = Icon(Icons.radio_button_checked, color: Colors.orange.shade600);
                avatarColor = Colors.orange.shade400;
                textColor = Colors.orange.shade800;
              } else if (isSaved && !hasPending) {
                trailing = const Icon(Icons.check_circle, color: Colors.blue);
                avatarColor = Colors.blue;
                textColor = Colors.black;
              } else {
                trailing = null;
                avatarColor = Colors.grey.shade200;
                textColor = Colors.black87;
              }

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: avatarColor,
                  child: Text(
                    user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: (isPending || (isSaved && !hasPending)) ? Colors.white : Colors.grey.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(
                  user.name,
                  style: TextStyle(
                    fontWeight: (isPending || (isSaved && !hasPending)) ? FontWeight.bold : FontWeight.normal,
                    color: textColor,
                  ),
                ),
                trailing: trailing,
                onTap: () => _onTap(user),
              );
            },
          ),
        ),
        if (hasPending)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save Identity'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPasscodeGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Enter access code to view the agent list',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.black87),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _passcodeController,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Access code',
                border: const OutlineInputBorder(),
                errorText: _passcodeError,
              ),
              onSubmitted: (_) => _submitPasscode(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _checkingPasscode ? null : _submitPasscode,
                child: _checkingPasscode
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Unlock'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FubUser {
  final int id;
  final String name;
  const _FubUser({required this.id, required this.name});
}
