import 'package:flutter/material.dart';
import '../services/contact_alias_store.dart';

class ContactAliasesScreen extends StatefulWidget {
  const ContactAliasesScreen({super.key});

  @override
  State<ContactAliasesScreen> createState() => _ContactAliasesScreenState();
}

class _ContactAliasesScreenState extends State<ContactAliasesScreen> {
  List<Map<String, String>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await ContactAliasStore.toolList();
    final raw = (result['aliases'] as List?) ?? [];
    setState(() {
      _entries = raw.map((e) => {
        'alias': e['alias'] as String,
        'name': e['name'] as String,
        'phone': e['phone'] as String,
      }).toList()
        ..sort((a, b) => a['alias']!.compareTo(b['alias']!));
      _loading = false;
    });
  }

  Future<void> _delete(String alias) async {
    await ContactAliasStore.toolForget({'alias': alias});
    await _load();
  }

  Future<void> _showEditDialog({Map<String, String>? existing}) async {
    final aliasCtrl = TextEditingController(text: existing?['alias'] ?? '');
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final phoneCtrl = TextEditingController(text: existing?['phone'] ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add Alias' : 'Edit Alias'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(labelText: 'Spoken name / alias', hintText: 'e.g. Mom, Dad, John'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Contact name (in address book)'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phoneCtrl,
              decoration: const InputDecoration(labelText: 'Phone number', hintText: '+1...'),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved == true) {
      final alias = aliasCtrl.text.trim();
      final name = nameCtrl.text.trim();
      final phone = phoneCtrl.text.trim();
      if (alias.isNotEmpty && name.isNotEmpty && phone.isNotEmpty) {
        if (existing != null && existing['alias'] != alias) {
          await ContactAliasStore.toolForget({'alias': existing['alias']});
        }
        await ContactAliasStore.toolRemember({'alias': alias, 'name': name, 'phone': phone});
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Aliases'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        tooltip: 'Add alias',
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No contact aliases yet.\nSay "remember that Mom is Jane Smith" or tap + to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final e = _entries[i];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(e['alias']!, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${e['name']}  ·  ${e['phone']}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _showEditDialog(existing: e),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            tooltip: 'Delete',
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete alias?'),
                                  content: Text('Remove "${e['alias']}"?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                                  ],
                                ),
                              );
                              if (ok == true) await _delete(e['alias']!);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
