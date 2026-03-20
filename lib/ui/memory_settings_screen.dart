import 'package:flutter/material.dart';
import '../services/memory_store.dart';

class TextFileSettingsScreen extends StatefulWidget {
  final String title;
  final Future<String> Function() read;
  final Future<void> Function(String) write;

  const TextFileSettingsScreen({
    super.key,
    required this.title,
    required this.read,
    required this.write,
  });

  @override
  State<TextFileSettingsScreen> createState() => _TextFileSettingsScreenState();
}

class _TextFileSettingsScreenState extends State<TextFileSettingsScreen> {
  String _memoryText = '';
  bool _loading = true;

  final TextEditingController _controller = TextEditingController();
  bool _editing = false;
  String _lastLoadedText = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final text = await widget.read();
    setState(() {
      _memoryText = text;
      _loading = false;

      // Only update the editor if the user isn't actively editing.
      if (!_editing) {
        _controller.text = text;
        _lastLoadedText = text;
      }      
    });
  }

  Future<void> _toggleEdit() async {
    setState(() {
      _editing = !_editing;
      if (_editing) {
        _controller.text = _memoryText;
        _lastLoadedText = _memoryText;
      }
    });
  }

  Future<void> _saveEdits() async {
    await widget.write(_controller.text);
    setState(() {
      _editing = false;
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: _editing ? 'Cancel edit' : 'Edit',
            onPressed: _toggleEdit,
            icon: Icon(_editing ? Icons.close : Icons.edit),
          ),
          IconButton(            
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      if (_editing)
                        ElevatedButton.icon(
                          onPressed: _controller.text == _lastLoadedText ? null : _saveEdits,
                          icon: const Icon(Icons.save),
                          label: const Text('Save'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                                        child: _editing
                        ? TextField(
                            controller: _controller,
                            maxLines: null,
                            expands: true,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              hintText: 'Edit memory file contents…',
                            ),
                            style: const TextStyle(fontSize: 14, height: 1.3),
                            onChanged: (_) {
                              // Trigger rebuild so Save button enabled state updates.
                              setState(() {});
                            },
                          )
                        : SingleChildScrollView(
                            child: SelectableText(
                              _memoryText.isEmpty ? '(memory is empty)' : _memoryText,
                              style: const TextStyle(fontSize: 14, height: 1.3),
                            ),
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}


class MemorySettingsScreen extends StatelessWidget {
  const MemorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TextFileSettingsScreen(
      title: 'Long-term Memory',
      read: MemoryStore.readAll,
      write: MemoryStore.writeAll,
    );
  }
}

class PreferencesSettingsScreen extends StatelessWidget {
  const PreferencesSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TextFileSettingsScreen(
      title: 'User Preferences',
      read: PreferencesStore.readAll,
      write: PreferencesStore.writeAll,
    );
  }
}