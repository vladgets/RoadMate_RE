import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../services/youtube_client.dart';

class YouTubeHistoryScreen extends StatefulWidget {
  const YouTubeHistoryScreen({super.key});

  @override
  State<YouTubeHistoryScreen> createState() => _YouTubeHistoryScreenState();
}

class _YouTubeHistoryScreenState extends State<YouTubeHistoryScreen> {
  bool _loading = true;
  List<YouTubeSubscriptionVideo> _videos = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final clientId = prefs.getString(Config.prefKeyClientId);

      if (clientId == null || clientId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'Client id not initialized. Please restart the app.';
        });
        return;
      }

      final client = YouTubeClient(baseUrl: Config.serverUrl, clientId: clientId);
      final videos = await client.getSubscriptionsFeed();

      if (!mounted) return;
      setState(() {
        _videos = videos;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _formatDate(BuildContext context, DateTime dt) {
    final loc = MaterialLocalizations.of(context);
    return loc.formatMediumDate(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube history'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Failed to load videos:\n$_error',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : (_videos.isEmpty
                  ? const Center(
                      child: Text(
                        'No videos from subscriptions in the last month.\nAuthorize YouTube in Extensions first.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _videos.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final v = _videos[index];
                        final dateStr = _formatDate(context, v.publishedAt);
                        return ListTile(
                          leading: const Icon(Icons.play_circle_outline),
                          title: Text(
                            v.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('$dateStr\n${v.url}'),
                          onTap: ()  async {
                            await openYoutubeVideo(v.url, startSeconds: 0, autoplay: true);
                          },
                        );
                      },
                    ))),
    );
  }
}
