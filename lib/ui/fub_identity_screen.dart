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
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    _selectedName = Config.fubAgentName;
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('${Config.serverUrl}/fub/users');
      final resp = await http.get(uri);
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

  Future<void> _select(_FubUser user) async {
    await Config.setFubAgent(user.name, user.id);
    setState(() => _selectedName = user.name);
    if (widget.standalone && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Identity set to ${user.name}')),
      );
    }
  }

  Future<void> _clear() async {
    await Config.clearFubAgent();
    setState(() => _selectedName = null);
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    if (!widget.standalone) return content;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CRM Identity'),
        actions: [
          if (_selectedName != null)
            TextButton(
              onPressed: _clear,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildContent() {
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            _selectedName != null
                ? 'Signed in as $_selectedName'
                : 'Select your name from the brokerage team:',
            style: TextStyle(
              fontSize: 14,
              color: _selectedName != null ? Colors.green.shade700 : Colors.grey.shade700,
              fontWeight: _selectedName != null ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _users.length,
            separatorBuilder: (context2, i2) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final user = _users[i];
              final selected = user.name == _selectedName;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: selected ? Colors.blue : Colors.grey.shade200,
                  child: Text(
                    user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.grey.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(user.name,
                    style: TextStyle(fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                trailing: selected ? const Icon(Icons.check_circle, color: Colors.blue) : null,
                onTap: () => _select(user),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FubUser {
  final int id;
  final String name;
  const _FubUser({required this.id, required this.name});
}
