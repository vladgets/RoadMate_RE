import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/photo_attachment.dart';
import '../../models/voice_memory.dart';
import '../../services/voice_memory_store.dart';
import 'collage_generator_screen.dart';

class MemorySelectionScreen extends StatefulWidget {
  final List<PhotoAttachment> selectedPhotos;

  const MemorySelectionScreen({
    super.key,
    required this.selectedPhotos,
  });

  @override
  State<MemorySelectionScreen> createState() => _MemorySelectionScreenState();
}

class _MemorySelectionScreenState extends State<MemorySelectionScreen> {
  final List<VoiceMemory> _selectedMemories = [];
  List<VoiceMemory> _allMemories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  Future<void> _loadMemories() async {
    await VoiceMemoryStore.instance.init();
    final memories = VoiceMemoryStore.instance.allMemories;
    setState(() {
      _allMemories = memories;
      _isLoading = false;
    });
  }

  void _toggleMemory(VoiceMemory memory) {
    setState(() {
      final isSelected = _selectedMemories.any((m) => m.id == memory.id);
      if (isSelected) {
        _selectedMemories.removeWhere((m) => m.id == memory.id);
      } else if (_selectedMemories.length < 3) {
        _selectedMemories.add(memory);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Memories'),
        actions: [
          TextButton(
            onPressed: _selectedMemories.isNotEmpty
                ? () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CollageGeneratorScreen(
                          photos: widget.selectedPhotos,
                          memories: _selectedMemories,
                        ),
                      ),
                    );
                  }
                : null,
            child: const Text('Generate'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Select 1-3 memories (${_selectedMemories.length}/3)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _allMemories.isEmpty
                    ? const Center(
                        child: Text('No voice memories yet.\nCreate some first!'),
                      )
                    : ListView.builder(
                        itemCount: _allMemories.length,
                        itemBuilder: (context, index) {
                          final memory = _allMemories[index];
                          final isSelected = _selectedMemories.any((m) => m.id == memory.id);

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (_) => _toggleMemory(memory),
                            title: Text(
                              memory.transcription.length > 80
                                  ? '${memory.transcription.substring(0, 80)}...'
                                  : memory.transcription,
                            ),
                            subtitle: Text(
                              '${memory.address ?? 'No location'} • ${DateFormat('MMM d, y').format(memory.createdAt)}',
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
