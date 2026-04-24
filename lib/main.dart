import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'platform/background_services.dart';
import 'platform/web_audio_player.dart';
import 'config.dart';
import 'ui/main_settings_menu.dart';
import 'ui/onboarding_screen.dart';
import 'ui/chat_screen.dart';
import 'models/chat_message.dart';
import 'services/geo_time_tools.dart';
import 'services/memory_store.dart';
import 'services/calendar.dart';
import 'services/web_search.dart';
import 'services/gmail_client.dart';
import 'services/mls_client.dart';
import 'services/gcalendar_client.dart';
import 'services/gdrive_client.dart';
import 'services/map_navigation.dart';
import 'services/phone_call.dart';
import 'services/reminders.dart';
import 'services/conversation_store.dart';
import 'services/whatsapp_service.dart';
import 'services/fub_client.dart';
import 'services/conversation_logger.dart';
import 'services/contacts.dart';
import 'services/contact_alias_store.dart';
import 'services/place_alias_store.dart';




/// Main entry point (keeps app in portrait mode only)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background services (WorkManager + foreground task) on mobile only.
  if (!kIsWeb) await initBackgroundServices();

  // Ensure client_id exists before anything else (needed for OAuth in onboarding)
  await ClientIdStore.getOrCreate();

  // some initial setup
  await Config.loadSavedVoice();
  await Config.loadFubAgent();
  await Config.loadLastClient();
  await Config.loadFubAuthenticated();
  await Config.loadCustomFub();

  // Initialize reminders service
  await RemindersService.instance.init();

  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool? _hasCompletedOnboarding;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // On web, always skip onboarding — browser handles mic permission natively.
      _hasCompletedOnboarding = true;
    } else {
      _checkOnboardingStatus();
    }
  }

  Future<void> _checkOnboardingStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = prefs.getBool('hasCompletedOnboarding') ?? false;
    setState(() {
      _hasCompletedOnboarding = completed;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Show loading screen while checking onboarding status
    if (_hasCompletedOnboarding == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: (kIsWeb || _hasCompletedOnboarding!)
          ? const VoiceButtonPage()
          : const OnboardingScreen(),
      routes: {
        '/main': (context) => const VoiceButtonPage(),
        '/onboarding': (context) => const OnboardingScreen(),
      },
    );
  }
}

class VoiceButtonPage extends StatefulWidget {
  const VoiceButtonPage({super.key});

  @override
  State<VoiceButtonPage> createState() => _VoiceButtonPageState();
}


// On web, Config.serverUrl is '' so this becomes '/token' (relative to page origin).
final tokenServerUrl = '${Config.serverUrl}/token';

class _VoiceButtonPageState extends State<VoiceButtonPage> with WidgetsBindingObserver {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _mic;

  // Web search (reuse single instances)
  late final WebSearchClient _webSearchClient = WebSearchClient();
  late final WebSearchTool _webSearchTool = WebSearchTool(client: _webSearchClient);

  // MLS client — initialized alongside Gmail with the same client id.
  late MlsClient mlsClient;
  // Gmail client (multi-user): initialized with per-install client id.
  late final GmailClient gmailClient;
  // Google Calendar client — used on web always, on mobile when source == 'google'.
  late final GCalendarClient gCalendarClient;
  // Google Drive client — reads PDFs and Docs attached to calendar events.
  late final GDriveClient gDriveClient;
  String? _clientId;
  /// Always reads the current calendar source from SharedPreferences so that
  /// changes made in Extensions Settings take effect immediately without restart.
  Future<String> _getCalendarSource() async {
    if (kIsWeb) return 'google';
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('calendar_source') ?? 'apple';
  }
  // Deduplicate tool calls (Realtime may emit in_progress + completed, and can resend events).
  final Set<String> _handledToolCallIds = <String>{};

  // Message to inject into the session as soon as the data channel opens.
  String? _pendingUserMessage;

  // Audio player for thinking sound during long-running tool execution
  final AudioPlayer _thinkingSoundPlayer = AudioPlayer();

  // Conversation store for chat history
  ConversationStore? _conversationStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen for messages from foreground task handler (e.g. notification "Stop" button)
    if (!kIsWeb) {
      addForegroundCallback((data) {
        if (data is Map && data['action'] == 'stopVoice') {
          _disconnect();
        }
      });
    }

    // Pre-load thinking sound for instant playback
    _preloadThinkingSound();

    // Initialize conversation store (SharedPreferences-based, works on all platforms)
    ConversationStore.create().then((store) async {
      _conversationStore = store;
      // Create a new session on every app launch
      if (!store.hasSessions) {
        await store.createNewSession();
      }

      // Drain reminders that fired since last app open and add to chat.
      // This works even if the user never tapped the notification (e.g. while driving).
      final fired = await RemindersService.instance.drainFiredReminders();
      for (final r in fired) {
        if (r.body.isNotEmpty) {
          final text = r.title != 'Reminder' ? '🔔 ${r.title}\n${r.body}' : '🔔 ${r.body}';
          await store.addMessageToActiveSession(ChatMessage.assistant(text));
        }
      }

      // Also handle tap while app is running (instant feedback, no duplicate
      // since drainFiredReminders already removed it from the queue).
      RemindersService.onNotificationTap = (title, body) {
        final text = title != 'Reminder' ? '🔔 $title\n$body' : '🔔 $body';
        _conversationStore?.addMessageToActiveSession(ChatMessage.assistant(text));
        if (mounted) setState(() {});
      };

      if (!mounted) return;
      setState(() {});

      // On web, chat is the primary screen — navigate there instantly (no animation).
      // Back button on ChatScreen returns to the voice screen.
      if (kIsWeb) {
        Navigator.of(context).push(PageRouteBuilder(
          pageBuilder: (_, _, _) => ChatScreen(
            conversationStore: store,
            toolExecutor: executeTool,
            clientId: _clientId,
            agentName: Config.fubAgentName,
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ));
      }
    });

    // Ensure we have a stable client id for Gmail/Calendar token storage on the server.
    ClientIdStore.getOrCreate().then((cid) async {
      _clientId = cid;
      Config.clientId = cid;
      gmailClient = GmailClient(baseUrl: Config.serverUrl, clientId: cid);
      gCalendarClient = GCalendarClient(baseUrl: Config.serverUrl, clientId: cid);
      gDriveClient = GDriveClient(baseUrl: Config.serverUrl, clientId: cid);
      mlsClient = MlsClient(baseUrl: Config.serverUrl, clientId: cid);
      debugPrint('[ClientId] $cid');

      // Fetch and cache the user's own email address (used by gmail_send_email tool).
      final prefs = await SharedPreferences.getInstance();
      var cachedEmail = prefs.getString('user_gmail_email');
      if (cachedEmail != null && cachedEmail.isNotEmpty) {
        Config.userEmail = cachedEmail;
        debugPrint('[Gmail] User email (cached): $cachedEmail');
      } else {
        try {
          final email = await gmailClient.fetchUserEmail();
          if (email != null && email.isNotEmpty) {
            Config.userEmail = email;
            await prefs.setString('user_gmail_email', email);
            debugPrint('[Gmail] User email (fetched): $email');
          }
        } catch (e) {
          debugPrint('[Gmail] Could not fetch user email: $e');
        }
      }

      if (mounted) setState(() {});
    });

     // disable for now
     // initFcm();

    // Auto-start microphone session on app launch (if enabled in settings).
    // This will trigger the mic permission prompt (if not granted yet).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_connected || _connecting) return;

      // Check if auto-start is enabled (default: false)
      final prefs = await SharedPreferences.getInstance();
      final autoStart = prefs.getBool('autoStartVoice') ?? false;

      if (autoStart) {
        _connect();
      }

    });
  }

  bool _connecting = false;
  bool _connected = false;
  bool _navigatedAway = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    // Stop before dispose so MediaCodec drains its pending callbacks cleanly.
    // Disposing a looping player without stopping first sends native callbacks
    // to the already-dead EventHandler thread, producing a harmless but noisy
    // "sending message to a Handler on a dead thread" warning.
    _thinkingSoundPlayer.stop().whenComplete(_thinkingSoundPlayer.dispose);
    _webSearchClient.close();
    _disconnect();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Execute a tool by name and return the result
  /// This can be called from chat screen for tool execution
  Future<Map<String, dynamic>> executeTool(String toolName, dynamic args) async {
    debugPrint('>>> Executing tool from chat: $toolName with args: $args');

    final toolHandler = _tools[toolName];
    if (toolHandler == null) {
      debugPrint('>>> Tool not found: $toolName');
      return {'error': 'Unknown tool: $toolName'};
    }

    try {
      final result = await toolHandler(args);
      debugPrint('>>> Tool execution result: $result');
      return result;
    } catch (e) {
      debugPrint('>>> Tool execution error: $e');
      return {'error': e.toString()};
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stop thinking sound when app goes to background
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _stopThinkingSound();
    }

    // When app returns to foreground, auto-start mic session if not connected.
    // Don't reconnect if user navigated to another screen (chat, notes, etc.)
    if (state == AppLifecycleState.resumed) {
      if (!mounted) return;
      if (_navigatedAway) return;
      if (_connected || _connecting) return;

      // Check if auto-start is enabled
      SharedPreferences.getInstance().then((prefs) {
        final autoStart = prefs.getBool('autoStartVoice') ?? false;
        if (autoStart && mounted && !_connected && !_connecting) {
          _connect();
        }
      });
    }
  }

  Future<void> _toggle() async {
    if (_connecting) return;
    if (_connected) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<void> _connect() async {
    if (_connecting || _connected) return;

    setState(() {
      _connecting = true;
      _error = null;
      _status = "Requesting token…";
    });

    try {
      // 1) Get ephemeral key from your backend
      final tokenResp = await http.get(Uri.parse(tokenServerUrl));
      if (tokenResp.statusCode != 200) {
        final preview = tokenResp.body.length > 200 ? tokenResp.body.substring(0, 200) : tokenResp.body;
        throw Exception('Token server returned HTTP ${tokenResp.statusCode}: $preview');
      }
      final tokenJson = jsonDecode(tokenResp.body) as Map<String, dynamic>;
      final ephemeralKey = tokenJson['value'] as String?;
      if (ephemeralKey == null) {
        final serverError = tokenJson['error']?['message'] ?? tokenJson['error'] ?? tokenJson.toString();
        throw Exception('Token server error: $serverError');
      }

      setState(() => _status = "Creating peer connection…");

      // 2) Create PeerConnection
      _pc = await createPeerConnection({
        // Start minimal. If you see ICE failures on some networks,
        // add a STUN server:
        // 'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]
      });

      // 3) Remote audio track will arrive here.
      // On mobile, WebRTC audio generally plays via native audio output automatically.
      _pc!.onTrack = (RTCTrackEvent e) async {
        if (e.track.kind == 'audio') {
          if (kIsWeb) {
            // On web, browser doesn't auto-play remote tracks — attach to <audio>.
            attachRemoteAudio(e.streams.isNotEmpty ? e.streams.first : null);
          } else {
            // Force loudspeaker on iOS.
            await Helper.setSpeakerphoneOn(true);
          }
          setState(() => _status = "Assistant connected. Talk!");
        }
      };

      // 4) Local mic stream
      setState(() => _status = "Opening microphone…");
      _mic = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      final audioTrack = _mic!.getAudioTracks().first;
      await _pc!.addTrack(audioTrack, _mic!);

      // 5) Data channel (optional but useful for session updates / events)
      _dc = await _pc!.createDataChannel("oai-events", RTCDataChannelInit());

      _dc!.onDataChannelState = (RTCDataChannelState state) {
        debugPrint("DataChannel state: $state");
        if (state == RTCDataChannelState.RTCDataChannelOpen && _pendingUserMessage != null) {
          final msg = _pendingUserMessage!;
          _pendingUserMessage = null;
          Future.delayed(const Duration(milliseconds: 300), () => _injectUserMessage(msg));
        }
      };

      _dc!.onMessage = (RTCDataChannelMessage msg) {
        // You can log JSON events here for debugging.
        // debugPrint("OAI event: ${msg.text}");

        // Best-effort parse and route.
        handleOaiEvent(msg.text);
      };

      // 6) Offer/Answer SDP exchange
      setState(() => _status = "Creating offer…");
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await _pc!.setLocalDescription(offer);

      setState(() => _status = "Calling OpenAI Realtime…");
      final answerSdp = await _createCallAndGetAnswerSdp(
        ephemeralKey: ephemeralKey,
        offerSdp: offer.sdp!,
      );

      await _pc!.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));

      // Enable wakelock to keep microphone active even when screen is locked
      await WakelockPlus.enable();

      // Start foreground service to prevent Android from killing the app
      if (!kIsWeb) await startForegroundService();

      setState(() {
        _connected = true;
        _status = "Connected. Talk!";
      });

    } catch (e) {
      await _disconnect();
      setState(() {
        _error = e.toString();
        _status = null;
      });
    } finally {
      setState(() => _connecting = false);
    }
  }

  Future<String> _createCallAndGetAnswerSdp({
    required String ephemeralKey,
    required String offerSdp,
  }) async {
    final uri = Uri.parse("https://api.openai.com/v1/realtime/calls");
    final req = http.MultipartRequest("POST", uri);

    // IMPORTANT: use the ephemeral key here (NOT your real API key).
    req.headers['Authorization'] = "Bearer $ephemeralKey";

    // Ensure user email is loaded before building system prompt (guards against timing race).
    if (Config.userEmail == null) {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('user_gmail_email');
      if (cached != null && cached.isNotEmpty) {
        Config.userEmail = cached;
      } else if (_clientId != null) {
        // Not in local cache — fetch from server (e.g. web after rebuild, or first launch).
        try {
          final email = await gmailClient.fetchUserEmail();
          if (email != null && email.isNotEmpty) {
            Config.userEmail = email;
            await prefs.setString('user_gmail_email', email);
          }
        } catch (_) {}
      }
    }

    final instructions = await Config.buildSystemPromptWithPreferences();
    debugPrint('[SystemPrompt] fubAgentName=${Config.fubAgentName} userEmail=${Config.userEmail}');
    debugPrint('[SystemPrompt] first 300 chars: ${instructions.substring(0, instructions.length.clamp(0, 300))}');

    // Optional session override; can be minimal if you already set it in /token.
    req.fields['session'] = jsonEncode({
      "type": "realtime",
      "model": Config.model,
      "instructions": instructions,
      "tools": Config.tools,
      "tool_choice": "auto",
      "audio": {
        "input": {
          "turn_detection": {"type": "server_vad"},
          "transcription": {"model": "gpt-4o-mini-transcribe"}
        },
        "output": {"voice": Config.voice},
      }
    });

    req.fields['sdp'] = offerSdp;

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode != 200 && streamed.statusCode != 201) {
      throw Exception("OpenAI create call failed ${streamed.statusCode}: $body");
    }
    return body; // SDP answer
  }

  Future<void> _disconnect() async {
    // Upload voice session transcript before disconnecting
    if (_conversationStore != null) {
      try {
        final session = _conversationStore!.activeSession;
        ConversationLogger.upload(
          clientId: _clientId,
          sessionStart: session.createdAt.toUtc().toIso8601String(),
          messages: session.messages,
          agentName: Config.fubAgentName,
        );
      } catch (_) {}
    }

    // Stop thinking sound if it's playing (non-blocking)
    _stopThinkingSound();
    detachRemoteAudio();

    try {
      await _dc?.close();
      await _pc?.close();

      final tracks = _mic?.getTracks() ?? [];
      for (final t in tracks) {
        await t.stop();
      }
      await _mic?.dispose();
    } catch (_) {
      // ignore cleanup errors
    } finally {
      // Disable wakelock when disconnecting
      await WakelockPlus.disable();

      // Stop foreground service
      if (!kIsWeb) await stopForegroundService();

      _dc = null;
      _pc = null;
      _mic = null;
      // Clear handled tool calls so a new session can reuse call ids safely.
      _handledToolCallIds.clear();

      if (mounted) {
        setState(() {
          _connected = false;
          _connecting = false;
          _status = "Disconnected.";
        });
      }
    }
  }


  /// Simple implementation of tool handling for now
  void handleOaiEvent(String text) {
    Map<String, dynamic> evt;

    // Parse JSON
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      evt = decoded;
    } catch (_) {
      return; // Ignore non-JSON messages
    }

    // debugPrint("Event: $evt");
    final evtType = evt['type']?.toString();

    if (evtType == 'error') {
      debugPrint('🛑 Realtime server error: ${jsonEncode(evt)}');
      return;
    }

    // User and Assistant messages logging
    if (evtType == 'conversation.item.input_audio_transcription.completed') {
      final transcript = evt['transcript'];
      if (transcript is String && transcript.trim().isNotEmpty) {
        debugPrint('🧑 User said: ${transcript.trim()}');
        // Save to conversation store
        _conversationStore?.addMessageToActiveSession(ChatMessage.userVoice(transcript.trim()));
      }
      return;
    }

    if (evtType == 'response.output_audio_transcript.done') {
      final transcript = evt['transcript'];
      if (transcript is String && transcript.trim().isNotEmpty) {
        debugPrint('🤖 Assistant said: ${transcript.trim()}');
        // Save to conversation store
        _conversationStore?.addMessageToActiveSession(ChatMessage.assistant(transcript.trim()));
      }
      return;
    }

    // From here on we only handle events that include a conversation item.
    final item = evt['item'];
    if (item is! Map<String, dynamic>) return;

    // We only care about function/tool calls
    if (item['type'] != 'function_call') return;

    // Realtime often emits in_progress events with empty arguments and then a completed event.
    // Only execute when completed.
    final status = item['status'];
    if (status != 'completed') {
      debugPrint(">>> Function call event (ignored, status=$status): {name: ${item['name']}, call_id: ${item['call_id'] ?? item['id']}}");
      return;
    }

    final callId = (item['call_id'] ?? item['id'])?.toString();
    final name = item['name']?.toString();
    final arguments = item['arguments'];

    if (callId == null || name == null) return;

    // Deduplicate: sometimes the same completed call is delivered more than once.
    if (_handledToolCallIds.contains(callId)) {
      debugPrint(">>> Function call event (duplicate ignored): $name (call_id=$callId)");
      return;
    }
    _handledToolCallIds.add(callId);

    debugPrint(">>> Function call event (completed): $item");

    _executeToolCallFromEvent({
      'call_id': callId,
      'name': name,
      'arguments': arguments,
    });
  }

/// Resolves agent name for FUB queries.
  /// If the model passes 'me' or omits the agent, substitute the identified agent
  /// so requests are always scoped to the current user, not the API key owner.
  String? _resolveFubAgent(String? raw) {
    if (raw == null || raw == 'me') return Config.fubAgentName ?? raw;
    return raw;
  }

  /// Saves the resolved FUB contact as the last active client if the result
  /// contains a valid person identity. Called after single-person operations.
  void _maybeUpdateLastClient(Map<String, dynamic> result) {
    if (result['ok'] != true) return;
    final rawId = result['personId'] ?? result['person_id'];
    final id = rawId is num ? rawId.toInt() : int.tryParse(rawId?.toString() ?? '');
    final name = result['resolvedName'] as String? ?? result['name'] as String?;
    if (id != null && id > 0 && name != null && name.isNotEmpty) {
      Config.setLastClient(name, id);
    }
  }

  /// Returns the stored agent ID when available (preferred over name).
  /// Only returns null if no agent is identified.
  int? _resolveFubAgentId(String? rawName) {
    // If model is asking for the whole team, don't scope to an ID
    if (rawName == 'all') return null;
    return Config.fubAgentId;
  }

/// Tool handlers map
 late final Map<String, Future<Map<String, dynamic>> Function(dynamic args)> _tools = {
   'get_current_location': (_) async {
     return await getCurrentLocation(); 
   },
  // Long-term memory tools
  'memory_append': (args) async {
    return await MemoryStore.toolAppend(args);
  },
  'memory_fetch': (_) async {
    return await MemoryStore.toolRead();
  },
  // Calendar tools — Apple Calendar only on iOS when user chose it;
  // all other platforms (web, Android) always use Google Calendar.
  'get_calendar_data': (args) async {
    final src = await _getCalendarSource();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && src == 'apple') {
      return await CalendarStore.toolGetCalendarData(args);
    }
    return await gCalendarClient.toolGetCalendarData(args);
  },
  'create_calendar_event': (args) async {
    final src = await _getCalendarSource();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && src == 'apple') {
      return await CalendarStore.toolCreateCalendarEvent(args);
    }
    return await gCalendarClient.toolCreateCalendarEvent(args);
  },
  'update_calendar_event': (args) async {
    final src = await _getCalendarSource();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && src == 'apple') {
      return await CalendarStore.toolUpdateCalendarEvent(args);
    }
    return await gCalendarClient.toolUpdateCalendarEvent(args);
  },
  'delete_calendar_event': (args) async {
    final src = await _getCalendarSource();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && src == 'apple') {
      return await CalendarStore.toolDeleteCalendarEvent(args);
    }
    return await gCalendarClient.toolDeleteCalendarEvent(args);
  },
  // Time and date tool
  'get_current_time': (_) async {
    return await getCurrentTime(); 
  },
  // Web search tool
  'web_search': (args) async {
    return await _webSearchTool.call(args);
  },
  'open_url': (args) async {
    final url = args is Map ? (args['url'] as String?) : null;
    if (url == null || url.isEmpty) {
      return {'ok': false, 'error': 'No URL provided'};
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return {'ok': false, 'error': 'Invalid URL: $url'};
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return launched
        ? {'ok': true, 'url': url}
        : {'ok': false, 'error': 'Could not open URL: $url'};
  },
  'gmail_search': (args) async {
    // If client id / gmail client isn't ready yet, fail fast with a clear error.
    if (_clientId == null) {
      throw Exception('Gmail is not initialized yet (client id missing). Try again in a second.');
    }
    return await GmailSearchTool(client: gmailClient).call(args);
  },
  'gmail_read_email': (args) async {
    if (_clientId == null) {
      throw Exception('Gmail is not initialized yet (client id missing). Try again in a second.');
    }
    return await GmailReadEmailTool(client: gmailClient).call(args);
  },
  'gmail_send_email': (args) async {
    if (_clientId == null) {
      throw Exception('Gmail is not initialized yet (client id missing). Try again in a second.');
    }
    return await GmailSendEmailTool(client: gmailClient).call(args);
  },
  'mls_search': (args) async {
    if (_clientId == null) {
      return {'ok': false, 'error': 'Not initialized yet. Try again in a second.'};
    }
    final address = args['address'] as String? ?? '';
    if (address.isEmpty) return {'ok': false, 'error': 'Missing address'};
    return await mlsClient.searchProperty(address);
  },
  'send_disclosure': (args) async {
    if (_clientId == null) {
      return {'ok': false, 'error': 'Not initialized yet. Try again in a second.'};
    }
    final toEmail = args['to_email'] as String? ?? '';
    final subject = args['subject'] as String? ?? '';
    final body = args['body'] as String? ?? '';
    if (toEmail.isEmpty) return {'ok': false, 'error': 'Missing to_email'};
    if (subject.isEmpty) return {'ok': false, 'error': 'Missing subject'};
    if (body.isEmpty) return {'ok': false, 'error': 'Missing body'};
    return await mlsClient.sendDisclosure(
      toEmail: toEmail,
      subject: subject,
      body: body,
      docName: args['doc_name'] as String?,
      address: args['address'] as String?,
    );
  },
  'check_showingtime': (args) async {
    if (_clientId == null) {
      return {'ok': false, 'error': 'Not initialized yet. Try again in a second.'};
    }
    return await mlsClient.checkShowingTime(address: args['address'] as String?);
  },
  'read_drive_file': (args) async {
    if (_clientId == null) {
      return {'ok': false, 'error': 'Not initialized yet. Try again in a second.'};
    }
    return await gDriveClient.toolReadDriveFile(args);
  },
  // traffic ETA tool
  'traffic_eta': (args) async {
    return await handleTrafficEtaToolCall(args);
  },
  // open maps route tool
  'navigate_to_destination': (args) async {
    return await handleOpenMapsRouteToolCall(args);
  },
  // phone call tool — disconnect session before handing off to the dialer
  'call_phone': (args) async {
    final personId = (args is Map && args['person_id'] != null)
        ? (args['person_id'] as num).toInt()
        : null;
    final contactName = (args is Map) ? args['contact_name'] as String? ?? '' : '';

    // Always stop the session when placing a call
    unawaited(_disconnect());

    if (personId != null) {
      // FUB contact — open FUB app via universal link for calling with transcription
      final uri = Uri.parse(
        'https://${Config.activeFubSubdomain}.followupboss.com/2/people/view/$personId',
      );
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return {'ok': true, 'status': 'opening_fub', 'contact_name': contactName, 'person_id': personId};
    }

    // Fallback: native dialer for non-FUB contacts
    return await handlePhoneCallTool(args);
  },
  // Reminders tools (local notifications)
  'reminder_create': (args) async {
    return await RemindersService.instance.toolCreate(args);
  },
  'reminder_list': (_) async {
    return await RemindersService.instance.toolList();
  },
  'reminder_cancel': (args) async {
    return await RemindersService.instance.toolCancel(args);
  },
  // WhatsApp tools
  'send_whatsapp_message': (args) async {
    return await WhatsAppService.instance.toolSendWhatsAppMessage(args);
  },
  'stop_session': (_) async {
    // Let the model finish speaking before disconnecting
    Future.delayed(const Duration(milliseconds: 3500), _disconnect);
    return {'ok': true};
  },
  // Follow Up Boss CRM tools
  'fub_update_task': (args) async {
    final taskId = (args is Map && args['task_id'] != null) ? (args['task_id'] as num).toInt() : null;
    if (taskId == null) return {'ok': false, 'error': 'task_id is required'};
    final description = (args is Map) ? args['description'] as String? : null;
    final dueDate = (args is Map) ? args['due_date'] as String? : null;
    final taskType = (args is Map) ? args['task_type'] as String? : null;
    final isCompleted = (args is Map && args['is_completed'] != null) ? args['is_completed'] as bool? : null;
    return await FubClient().updateTask(
      taskId: taskId,
      description: description,
      dueDate: dueDate,
      taskType: taskType,
      isCompleted: isCompleted,
    );
  },
  'create_appointment': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final title = (args is Map) ? args['title'] as String? ?? '' : '';
    final start = (args is Map) ? args['start'] as String? ?? '' : '';
    final end = (args is Map) ? args['end'] as String? : null;
    final location = (args is Map) ? args['location'] as String? : null;
    final description = (args is Map) ? args['description'] as String? : null;
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final result = await FubClient().createAppointment(
      title: title,
      start: start,
      end: end,
      location: location,
      description: description,
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw) ?? 'me',
      personId: personId,
      clientName: clientName,
    );
    _maybeUpdateLastClient(result);
    return result;
  },
  'fub_create_task': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final description = (args is Map) ? args['description'] as String? ?? '' : '';
    final dueDate = (args is Map) ? args['due_date'] as String? ?? '' : '';
    final taskType = (args is Map) ? args['task_type'] as String? ?? '' : '';
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final result = await FubClient().createTask(
      description: description,
      dueDate: dueDate,
      taskType: taskType,
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw) ?? 'me',
      personId: personId,
      clientName: clientName,
    );
    _maybeUpdateLastClient(result);
    return result;
  },
  'fub_get_person_tasks': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final status = (args is Map) ? args['status'] as String? ?? 'all' : 'all';
    return await FubClient().getPersonTasks(
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
      personId: personId,
      clientName: clientName,
      status: status,
    );
  },
  'fub_get_tasks': (args) async {
    final dueDate = (args is Map) ? args['due_date'] as String? : null;
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    return await FubClient().getTasks(
      dueDate: dueDate,
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
    );
  },
  'fub_get_recent_contacts': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final limit = (args is Map && args['limit'] != null) ? (args['limit'] as num).toInt() : 5;
    final days = (args is Map && args['days'] != null) ? (args['days'] as num).toInt() : null;
    return await FubClient().getRecentContacts(
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
      limit: limit,
      days: days,
    );
  },
  'fub_search_contacts': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final query = (args is Map) ? args['query'] as String? ?? '' : '';
    final limit = (args is Map && args['limit'] != null) ? (args['limit'] as num).toInt() : 10;
    return await FubClient().searchContacts(
      query: query,
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
      limit: limit,
    );
  },
  'fub_get_person_details': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final result = await FubClient().getPersonDetails(
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
      personId: personId,
      clientName: clientName,
    );
    _maybeUpdateLastClient(result);
    return result;
  },
  'fub_get_sources': (_) async {
    return await FubClient().getSources();
  },
  'fub_get_lenders': (_) async {
    return await FubClient().getLenders();
  },
  'fub_update_person': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final stage = (args is Map) ? args['stage'] as String? : null;
    final name = (args is Map) ? args['name'] as String? : null;
    final backgroundInfo = (args is Map) ? args['background_info'] as String? : null;
    final source = (args is Map) ? args['source'] as String? : null;
    final lender = (args is Map) ? args['lender'] as String? : null;
    final assignedTo = (args is Map) ? args['assigned_to'] as String? : null;
    final collaborators = (args is Map && args['collaborators'] is Map) ? Map<String, dynamic>.from(args['collaborators'] as Map) : null;
    final tags = (args is Map && args['tags'] is Map) ? Map<String, dynamic>.from(args['tags'] as Map) : null;
    final phonesRaw = (args is Map && args['phones'] is List) ? args['phones'] as List : null;
    final phones = phonesRaw?.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final emailsRaw = (args is Map && args['emails'] is List) ? args['emails'] as List : null;
    final emails = emailsRaw?.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final address = (args is Map && args['address'] is Map) ? Map<String, dynamic>.from(args['address'] as Map) : null;
    final result = await FubClient().updatePerson(
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw),
      personId: personId,
      clientName: clientName,
      stage: stage,
      name: name,
      backgroundInfo: backgroundInfo,
      source: source,
      lender: lender,
      assignedTo: assignedTo,
      collaborators: collaborators,
      tags: tags,
      phones: phones,
      emails: emails,
      address: address,
    );
    _maybeUpdateLastClient(result);
    return result;
  },
  'fub_get_stages': (_) async {
    return await FubClient().getStages();
  },
  'fub_create_note': (args) async {
    final raw = (args is Map) ? args['agent_name'] as String? : null;
    final body = (args is Map) ? args['body'] as String? ?? '' : '';
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final clientName = (args is Map) ? args['client_name'] as String? : null;
    final result = await FubClient().createNote(
      body: body,
      agentId: _resolveFubAgentId(raw),
      agentName: _resolveFubAgent(raw) ?? 'me',
      personId: personId,
      clientName: clientName,
    );
    _maybeUpdateLastClient(result);
    return result;
  },
  'fub_open_contact': (args) async {
    final personId = (args is Map && args['person_id'] != null)
        ? (args['person_id'] as num).toInt()
        : null;
    final contactName = (args is Map) ? args['contact_name'] as String? ?? '' : '';
    if (personId == null) {
      return {'ok': false, 'error': 'person_id is required'};
    }
    final uri = Uri.parse(
      'https://${Config.activeFubSubdomain}.followupboss.com/2/people/view/$personId',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return {'ok': true, 'person_id': personId, 'contact_name': contactName};
  },
  // Unified SMS tool — handles personal contacts and FUB CRM clients
  'send_sms': (args) async {
    final message = args is Map ? (args['message'] as String?) ?? '' : '';
    if (message.isEmpty) return {'ok': false, 'error': 'message is required'};

    String phone = args is Map ? (args['phone_number'] as String?) ?? '' : '';
    String name = args is Map ? (args['contact_name'] as String?) ?? '' : '';
    final personId = (args is Map && args['person_id'] != null) ? (args['person_id'] as num).toInt() : null;
    final raw = args is Map ? args['agent_name'] as String? : null;

    // 1. Phone number provided directly — use it
    // 2. FUB person_id provided — resolve via FUB
    if (phone.isEmpty && personId != null) {
      final result = await FubClient().sendText(
        message: message,
        agentId: _resolveFubAgentId(raw),
        agentName: _resolveFubAgent(raw) ?? 'me',
        personId: personId,
        clientName: null,
      );
      _maybeUpdateLastClient(result);
      if (result['ok'] == true) {
        phone = (result['phone_number'] as String?) ?? '';
        name = name.isNotEmpty ? name : (result['contact_name'] as String? ?? '');
      } else {
        return result;
      }
    }

    // 3. Contact name only — resolve from device contacts/aliases
    if (phone.isEmpty) {
      if (name.isEmpty) return {'ok': false, 'error': 'contact_name or phone_number is required'};
      final lookup = await ContactsService.searchContacts({'name': name});
      if (lookup['ok'] != true || (lookup['found'] as int? ?? 0) == 0) {
        // Try FUB as last resort
        final fubResult = await FubClient().sendText(
          message: message,
          agentId: _resolveFubAgentId(raw),
          agentName: _resolveFubAgent(raw) ?? 'me',
          personId: null,
          clientName: name,
        );
        _maybeUpdateLastClient(fubResult);
        if (fubResult['ok'] == true) {
          phone = (fubResult['phone_number'] as String?) ?? '';
        } else {
          return {'ok': false, 'error': 'Could not find "$name" in your contacts or CRM.'};
        }
      } else {
        final contacts = lookup['contacts'] as List;
        if (contacts.length > 1) {
          return {'ok': false, 'needs_clarification': true, 'matches': contacts,
            'message': 'Multiple contacts match "$name". Please clarify which one.'};
        }
        final phones = contacts.first['phones'] as List;
        if (phones.isEmpty) return {'ok': false, 'error': 'No phone number found for "$name".'};
        phone = phones.first['number'] as String;
        name = contacts.first['name'] as String;
      }
    }

    final clean = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    final smsUri = Uri(scheme: 'sms', path: clean, queryParameters: {'body': message});
    try {
      await launchUrl(smsUri, mode: LaunchMode.externalApplication);
      return {'ok': true, 'status': 'SMS app opened', 'to': name.isNotEmpty ? name : phone};
    } catch (e) {
      return {'ok': false, 'error': 'Could not open SMS app: $e'};
    }
  },
  // Place alias tools
  'remember_place': (args) async {
    return await PlaceAliasStore.toolRemember(args);
  },
  'forget_place': (args) async {
    return await PlaceAliasStore.toolForget(args);
  },
  'list_place_aliases': (_) async {
    return await PlaceAliasStore.toolList();
  },
  // Contact alias tools
  'remember_contact': (args) async {
    return await ContactAliasStore.toolRemember(args);
  },
  'forget_contact': (args) async {
    return await ContactAliasStore.toolForget(args);
  },
  'list_contact_aliases': (_) async {
    return await ContactAliasStore.toolList();
  },
  // Device contacts tool
  'search_contacts': (args) async {
    return await ContactsService.searchContacts(args);
  },
  // Feedback tool
  'submit_feedback': (args) async {
    final text = args is Map ? (args['text'] as String?) ?? '' : '';
    if (text.isEmpty) return {'ok': false, 'error': 'No feedback text provided'};
    try {
      final base = Config.serverUrl.isNotEmpty
          ? Config.serverUrl
          : '${Uri.base.scheme}://${Uri.base.host}${Uri.base.port != 80 && Uri.base.port != 443 ? ":${Uri.base.port}" : ""}';
      final uri = Uri.parse('$base/feedback');
      final platform = ConversationLogger.platformName;
      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': _clientId ?? '',
          'platform': platform,
          'text': text,
        }),
      );
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  },
};

  /// Extracts tool name + arguments from an event, runs the handler,
  /// and sends the tool output back to the model over the data channel.
  Future<void> _executeToolCallFromEvent(Map<String, dynamic> evt) async {
    final String? callId = evt['call_id'];
    final String? toolName = evt['name'];
    if (callId == null || toolName == null || toolName.isEmpty) return;

    dynamic args = evt['arguments'];
    if (args == '') {
      args = {};
    }
    else if (args is String) {
      args = jsonDecode(args);
    }

    final toolHandler = _tools[toolName];
    if (toolHandler == null) return;

    // List of tools that typically take longer and should have thinking sound
    final longRunningTools = {
      'web_search',
      'gmail_search',
      'gmail_read_email',
      'gmail_send_email',
      'read_drive_file',
      'traffic_eta',
      'mls_search',
      'send_disclosure',
      'check_showingtime',
    };

    // Start thinking sound for long-running tools
    final shouldPlaySound = longRunningTools.contains(toolName);
    if (shouldPlaySound) {
      _playThinkingSound(); // Fire and forget - don't await
    }

    try {
      final Map<String, dynamic> result = await toolHandler(args);
      await _sendToolOutput(callId: callId, name: toolName, output: result);
    } catch (e) {
      debugPrint('>>> Tool execution error ($toolName): $e');
      await _sendToolOutput(
        callId: callId,
        name: toolName,
        output: {'error': e.toString()},
      );
    } finally {
      // Stop thinking sound after tool completes
      if (shouldPlaySound) {
        _stopThinkingSound(); // Fire and forget - don't await
      }
    }
  }

  /// Pre-loads thinking sound during initialization for instant playback
  Future<void> _preloadThinkingSound() async {
    try {
      await _thinkingSoundPlayer.setAsset('assets/sounds/thinking.mp3');
      await _thinkingSoundPlayer.setLoopMode(LoopMode.one);
      await _thinkingSoundPlayer.setVolume(0.3); // Subtle volume
      debugPrint('>>> Thinking sound pre-loaded successfully');
    } catch (e) {
      debugPrint('>>> Error pre-loading thinking sound: $e');
      // Fail silently - sound is optional
    }
  }

  /// Plays the pre-loaded thinking sound (non-blocking)
  void _playThinkingSound() {
    _thinkingSoundPlayer.play().catchError((e) {
      debugPrint('>>> Error playing thinking sound: $e');
      // Fail silently - sound is optional
    });
  }

  /// Stops the thinking sound (non-blocking)
  void _stopThinkingSound() {
    _thinkingSoundPlayer.stop().catchError((e) {
      debugPrint('>>> Error stopping thinking sound: $e');
    });
  }

  /// Sends tool output back to the model.
  ///
  /// The Realtime API expects a "tool output" / "function_call_output" item.
  /// If your logs show a different required shape, adjust here (this is the single place).
  /// Inject a text message as the user and trigger an AI response.
  void _injectUserMessage(String text) {
    final dc = _dc;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return;
    dc.send(RTCDataChannelMessage(jsonEncode({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [{'type': 'input_text', 'text': text}],
      },
    })));
    dc.send(RTCDataChannelMessage(jsonEncode({'type': 'response.create'})));
  }

  /// Activate session (if needed) then inject the feedback prompt.
  Future<void> _startFeedback() async {
    const prompt = 'Can I submit a feedback to developers?';
    if (_connected && _dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _injectUserMessage(prompt);
    } else {
      _pendingUserMessage = prompt;
      if (!_connecting && !_connected) await _connect();
    }
  }

  Future<void> _sendToolOutput({
    required String callId,
    required String name,
    required Map<String, dynamic> output,
  }) async {
    final dc = _dc;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return;

    final payload = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'function_call_output',
        'call_id': callId,
        // 'name': name,
        'output': jsonEncode(output),
      },
    };

    dc.send(RTCDataChannelMessage(jsonEncode(payload)));

    // Ask the model to continue after receiving the tool output.
    dc.send(RTCDataChannelMessage(jsonEncode({'type': 'response.create'})));
    debugPrint('>>> Sent tool output: $name (call_id=$callId)');
    debugPrint(jsonEncode(payload));
  }

  /// UI part
  @override
  Widget build(BuildContext context) {
    final isBusy = _connecting;
    final label = _connected ? "Tap to stop" : "Tap to talk";
    final icon = _connected ? Icons.stop_circle : Icons.mic;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: (Config.fubAgentName ?? Config.customFubUserName) != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (Config.fubAgentName ?? Config.customFubUserName)!,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    'Real Estate Assistant',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              _navigatedAway = true;
              await _disconnect();
              if (!mounted) return;
              // ignore: use_build_context_synchronously
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              setState(() {}); // refresh agent name after returning from settings
              _navigatedAway = false;
            },
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Chat',
        backgroundColor: Colors.white12,
        foregroundColor: Colors.white,
        elevation: 0,
        onPressed: () async {
          if (_conversationStore == null) return;
          _navigatedAway = true;
          await _disconnect();
          if (!mounted) return;
          // ignore: use_build_context_synchronously
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                conversationStore: _conversationStore!,
                toolExecutor: executeTool,
                clientId: _clientId,
                agentName: Config.fubAgentName,
              ),
            ),
          );
          _navigatedAway = false;
        },
        child: const Icon(Icons.keyboard_outlined),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _status ?? (isBusy ? "Working…" : "Ready."),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 36),
                    GestureDetector(
                      onTap: isBusy ? null : _toggle,
                      child: Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _connected ? Colors.redAccent : Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.25),
                              blurRadius: 24,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        child: Icon(
                          icon,
                          size: 72,
                          color: _connected ? Colors.white : Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      label,
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isBusy ? "Connecting…" : (_connected ? "Speak now" : "Not connected"),
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // Feedback button — bottom-right corner
            Positioned(
              bottom: 16,
              right: 16,
              child: Tooltip(
                message: 'Send feedback',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _startFeedback,
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.08),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.rate_review_outlined,
                        color: Colors.white54,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

