import 'package:flutter/material.dart';
import '../config.dart';
import 'fub_identity_screen.dart';
import 'custom_brokerage_screen.dart';

/// Top-level CRM Identity menu with two options:
/// 1. RB Brokerage — the existing passcode-gated agent list.
/// 2. Custom Brokerage — enter a personal FUB API key.
class CrmIdentityMenuScreen extends StatefulWidget {
  const CrmIdentityMenuScreen({super.key});

  @override
  State<CrmIdentityMenuScreen> createState() => _CrmIdentityMenuScreenState();
}

class _CrmIdentityMenuScreenState extends State<CrmIdentityMenuScreen> {
  String? _fubAgentName;
  String? _customSubdomain;

  @override
  void initState() {
    super.initState();
    _fubAgentName = Config.fubAgentName;
    _customSubdomain = Config.customFubSubdomain;
  }

  void _refresh() {
    setState(() {
      _fubAgentName = Config.fubAgentName;
      _customSubdomain = Config.customFubSubdomain;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasCustomKey = Config.customFubApiKey != null && Config.customFubApiKey!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('CRM Identity')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.business),
            title: const Text('RB Brokerage'),
            subtitle: Text(
              (!hasCustomKey && _fubAgentName != null)
                  ? 'Active — signed in as $_fubAgentName'
                  : 'Select your name from the NJ Residence team',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!hasCustomKey && _fubAgentName != null)
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const FubIdentityScreen(standalone: true),
                ),
              );
              _refresh();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('Custom Brokerage'),
            subtitle: Text(
              hasCustomKey
                  ? 'Active — connected to ${_customSubdomain ?? 'custom FUB account'}'
                  : 'Connect your own Follow Up Boss account',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasCustomKey)
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const CustomBrokerageScreen(),
                ),
              );
              _refresh();
            },
          ),
        ],
      ),
    );
  }
}
