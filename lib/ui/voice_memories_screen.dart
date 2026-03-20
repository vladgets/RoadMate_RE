import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/voice_memory.dart';
import '../services/voice_memory_store.dart';
import 'photo_picker_sheet.dart';
import 'widgets/photo_thumbnail.dart';

class VoiceMemoriesScreen extends StatefulWidget {
  const VoiceMemoriesScreen({super.key});

  @override
  State<VoiceMemoriesScreen> createState() => _VoiceMemoriesScreenState();
}

class _VoiceMemoriesScreenState extends State<VoiceMemoriesScreen> {
  bool _loading = true;
  List<VoiceMemory> _memories = [];
  List<VoiceMemory> _filtered = [];
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await VoiceMemoryStore.instance.init();
    if (!mounted) return;
    setState(() {
      _memories = VoiceMemoryStore.instance.allMemories;
      _applyFilter();
      _loading = false;
    });
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _applyFilter());
    });
  }

  void _applyFilter() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _filtered = _memories;
    } else {
      _filtered = VoiceMemoryStore.instance.search(
        text: query,
        limit: 200,
      );
    }
  }

  Future<void> _deleteMemory(VoiceMemory memory) async {
    await VoiceMemoryStore.instance.deleteMemory(memory.id);
    if (!mounted) return;
    setState(() {
      _memories = VoiceMemoryStore.instance.allMemories;
      _applyFilter();
    });
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: const Text('Are you sure you want to delete this note? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showDetail(VoiceMemory memory) {
    // State kept outside the builder so it survives setSheetState rebuilds
    var editing = false;
    TextEditingController? editController;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          // Resolve the latest version of the memory from the store
          final live = VoiceMemoryStore.instance.allMemories
              .firstWhere((m) => m.id == memory.id, orElse: () => memory);

          Future<void> attachPhotos() async {
            final selected = await PhotoPickerSheet.show(
              context,
              initialSelected: live.linkedPhotoIds,
            );
            if (selected == null) return;
            await VoiceMemoryStore.instance.linkPhotos(live.id, selected);
            setSheetState(() {});
            if (mounted) {
              setState(() {
                _memories = VoiceMemoryStore.instance.allMemories;
                _applyFilter();
              });
            }
          }

          Future<void> removePhoto(String photoId) async {
            final updated = List<String>.from(live.linkedPhotoIds)..remove(photoId);
            await VoiceMemoryStore.instance.linkPhotos(live.id, updated);
            setSheetState(() {});
            if (mounted) {
              setState(() {
                _memories = VoiceMemoryStore.instance.allMemories;
                _applyFilter();
              });
            }
          }

          void startEdit() {
            editController = TextEditingController(text: live.transcription);
            setSheetState(() => editing = true);
          }

          Future<void> saveEdit() async {
            final newText = editController?.text.trim() ?? '';
            if (newText.isEmpty) return;
            await VoiceMemoryStore.instance.editMemory(live.id, newText);
            editController?.dispose();
            editController = null;
            setSheetState(() => editing = false);
            if (mounted) {
              setState(() {
                _memories = VoiceMemoryStore.instance.allMemories;
                _applyFilter();
              });
            }
          }

          void cancelEdit() {
            editController?.dispose();
            editController = null;
            setSheetState(() => editing = false);
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            builder: (context, scrollController) => Padding(
              padding: const EdgeInsets.all(20),
              child: ListView(
                controller: scrollController,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Date/time
                  Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Text(
                        _formatDateTime(live.createdAt),
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  if (live.address != null || (live.latitude != null && live.longitude != null)) ...[
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: (live.latitude != null && live.longitude != null)
                          ? () => _openInMaps(live.latitude!, live.longitude!, live.address)
                          : null,
                      child: Row(
                        children: [
                          Icon(
                            Icons.location_on,
                            size: 16,
                            color: (live.latitude != null && live.longitude != null)
                                ? Colors.blue.shade600
                                : Colors.grey.shade600,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (live.address != null)
                                  Text(
                                    live.address!,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: (live.latitude != null && live.longitude != null)
                                          ? Colors.blue.shade600
                                          : Colors.grey.shade600,
                                    ),
                                  ),
                                if (live.latitude != null && live.longitude != null)
                                  Text(
                                    '${live.latitude!.toStringAsFixed(4)}, ${live.longitude!.toStringAsFixed(4)}  •  tap to open map',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.blue.shade400,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Attach photos row
                  Row(
                    children: [
                      Icon(Icons.photo_library_outlined, size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Text(
                        live.linkedPhotoIds.isEmpty
                            ? 'No photos attached'
                            : '${live.linkedPhotoIds.length} photo${live.linkedPhotoIds.length == 1 ? '' : 's'}',
                        style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: attachPhotos,
                        icon: const Icon(Icons.add_photo_alternate, size: 18),
                        label: const Text('Attach'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  // Photo thumbnails strip (in detail sheet)
                  if (live.linkedPhotoIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 88,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: live.linkedPhotoIds.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 4),
                        itemBuilder: (_, i) {
                          final photoId = live.linkedPhotoIds[i];
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              PhotoThumbnail(assetId: photoId, size: 80),
                              Positioned(
                                top: -4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () => removePhoto(photoId),
                                  child: Container(
                                    width: 20,
                                    height: 20,
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close, size: 13, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  // Transcription header with edit toggle
                  Row(
                    children: [
                      Text(
                        'Note',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade500,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const Spacer(),
                      if (!editing)
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          tooltip: 'Edit note',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: startEdit,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Read or edit view
                  if (editing) ...[
                    TextField(
                      controller: editController,
                      maxLines: null,
                      autofocus: true,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: cancelEdit,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: saveEdit,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ] else
                    SelectableText(
                      live.transcription,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAddDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Voice Note'),
        content: TextField(
          controller: textController,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Write your note...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final text = textController.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(context);
              await VoiceMemoryStore.instance.createMemory(transcription: text);
              if (!mounted) return;
              setState(() {
                _memories = VoiceMemoryStore.instance.allMemories;
                _applyFilter();
              });
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _openInMaps(double lat, double lon, String? label) async {
    final encodedLabel = Uri.encodeComponent(label ?? 'Note location');
    final Uri uri;
    if (Platform.isIOS) {
      uri = Uri.parse('http://maps.apple.com/?ll=$lat,$lon&q=$encodedLabel');
    } else {
      uri = Uri.parse('geo:$lat,$lon?q=$lat,$lon($encodedLabel)');
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _formatDateTime(DateTime dt) {
    final loc = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final dateStr = loc.formatMediumDate(dt);
    final timeStr = loc.formatTimeOfDay(
      TimeOfDay.fromDateTime(dt),
      alwaysUse24HourFormat: use24h,
    );
    return '$dateStr at $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Notes'),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search notes...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
          // List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.auto_stories,
                              size: 64,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _searchController.text.isNotEmpty
                                  ? 'No notes match your search'
                                  : 'No voice notes yet',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            if (_searchController.text.isEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Tell your assistant to save a note,\nor tap + to add one manually.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade400,
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final memory = _filtered[index];
                          return _MemoryListItem(
                            memory: memory,
                            formattedTime: _formatDateTime(memory.createdAt),
                            onTap: () => _showDetail(memory),
                            onDelete: () => _deleteMemory(memory),
                            onConfirmDelete: () => _confirmDelete(context),
                            onLocationTap: (memory.latitude != null && memory.longitude != null)
                                ? () => _openInMaps(memory.latitude!, memory.longitude!, memory.address)
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        tooltip: 'Add memory',
        child: const Icon(Icons.edit_note),
      ),
    );
  }
}

class _MemoryListItem extends StatelessWidget {
  final VoiceMemory memory;
  final String formattedTime;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Future<bool?> Function() onConfirmDelete;
  final VoidCallback? onLocationTap;

  const _MemoryListItem({
    required this.memory,
    required this.formattedTime,
    required this.onTap,
    required this.onDelete,
    required this.onConfirmDelete,
    this.onLocationTap,
  });

  @override
  Widget build(BuildContext context) {
    // Truncate transcription for title
    final titleText = memory.transcription.length > 100
        ? '${memory.transcription.substring(0, 100)}...'
        : memory.transcription;

    return Dismissible(
      key: Key(memory.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => onConfirmDelete(),
      onDismissed: (_) => onDelete(),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: Colors.blue.shade50,
                child: Icon(Icons.auto_stories, color: Colors.blue.shade700, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titleText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (memory.address != null) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: onLocationTap,
                        child: Row(
                          children: [
                            Icon(
                              Icons.location_on_outlined,
                              size: 14,
                              color: onLocationTap != null ? Colors.blue.shade400 : Colors.grey.shade500,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                memory.address!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: onLocationTap != null ? Colors.blue.shade600 : Colors.grey.shade600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      formattedTime,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    // Photo thumbnail strip
                    if (memory.linkedPhotoIds.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 52,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: memory.linkedPhotoIds.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 4),
                          itemBuilder: (_, i) => PhotoThumbnail(
                            assetId: memory.linkedPhotoIds[i],
                            size: 48,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
