import 'package:flutter/material.dart';
import '../../models/photo_attachment.dart';
import '../../models/voice_memory.dart';
import '../../services/collage_api_client.dart';
import '../../services/collage_composer.dart';
import 'collage_preview_screen.dart';

class CollageGeneratorScreen extends StatefulWidget {
  final List<PhotoAttachment> photos;
  final List<VoiceMemory> memories;

  const CollageGeneratorScreen({
    super.key,
    required this.photos,
    required this.memories,
  });

  @override
  State<CollageGeneratorScreen> createState() => _CollageGeneratorScreenState();
}

class _CollageGeneratorScreenState extends State<CollageGeneratorScreen> {
  String _status = 'Analyzing photos and memories...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _generateCollage();
  }

  Future<void> _generateCollage() async {
    try {
      setState(() {
        _status = 'Analyzing photos and memories...';
      });

      await Future.delayed(const Duration(seconds: 1));

      setState(() {
        _status = 'Generating AI background with DALL-E 3...';
      });

      // Call API
      final response = await CollageApiClient.instance.generateBackground(
        photos: widget.photos,
        memories: widget.memories,
        style: 'scrapbook',
      );

      setState(() {
        _status = 'Creating your collage...';
      });

      // Generate composition
      final composition = CollageComposer.instance.generateComposition(
        backgroundUrl: response.backgroundUrl ?? '',
        photos: widget.photos,
        memories: widget.memories,
        theme: response.theme,
        colors: response.colors,
        layoutStyle: 'scrapbook',
      );

      // Navigate to preview
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => CollagePreviewScreen(
              composition: composition,
              usedFallback: response.fallback,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to generate collage: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Creating Collage'),
      ),
      body: Center(
        child: _errorMessage != null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(_errorMessage!),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(
                    _status,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('This may take 20-30 seconds...'),
                ],
              ),
      ),
    );
  }
}
