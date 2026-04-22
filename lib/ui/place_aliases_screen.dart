import 'package:flutter/material.dart';
import '../services/place_alias_store.dart';

class PlaceAliasesScreen extends StatefulWidget {
  const PlaceAliasesScreen({super.key});

  @override
  State<PlaceAliasesScreen> createState() => _PlaceAliasesScreenState();
}

class _PlaceAliasesScreenState extends State<PlaceAliasesScreen> {
  List<Map<String, String>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await PlaceAliasStore.readAll();
    setState(() {
      _entries = data.entries
          .map((e) => {'alias': e.key, 'address': e.value})
          .toList()
            ..sort((a, b) => a['alias']!.compareTo(b['alias']!));
      _loading = false;
    });
  }

  Future<void> _delete(String alias) async {
    await PlaceAliasStore.toolForget({'alias': alias});
    await _load();
  }

  Future<void> _showEditDialog({Map<String, String>? existing}) async {
    final aliasCtrl = TextEditingController(text: existing?['alias'] ?? '');
    final addressCtrl = TextEditingController(text: existing?['address'] ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add Place' : 'Edit Place'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(
                labelText: 'Spoken name / alias',
                hintText: 'e.g. Home, Office, Gym',
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addressCtrl,
              decoration: const InputDecoration(
                labelText: 'Full address',
                hintText: '123 Main St, New York, NY',
              ),
              textCapitalization: TextCapitalization.words,
              maxLines: 2,
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
      final address = addressCtrl.text.trim();
      if (alias.isNotEmpty && address.isNotEmpty) {
        if (existing != null && existing['alias'] != alias) {
          await PlaceAliasStore.toolForget({'alias': existing['alias']});
        }
        await PlaceAliasStore.toolRemember({'alias': alias, 'address': address});
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Place Aliases'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        tooltip: 'Add place',
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No place aliases yet.\nSay "remember Home as 123 Main St" or tap + to add one.',
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
                      leading: const CircleAvatar(child: Icon(Icons.place)),
                      title: Text(e['alias']!, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(e['address']!),
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
                                  title: const Text('Delete place?'),
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
