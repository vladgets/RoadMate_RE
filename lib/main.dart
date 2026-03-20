import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
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
import 'services/map_navigation.dart';
import 'services/phone_call.dart';
import 'services/reminders.dart';
import 'services/youtube_client.dart';
import 'services/conversation_store.dart';
import 'services/photo_index_service.dart';
import 'services/voice_memory_store.dart';
import 'services/whatsapp_service.dart';
import 'services/screenshot_service.dart';
import 'services/app_control_service.dart';
import 'services/driving_log_store.dart';
import 'services/driving_monitor_service.dart';
import 'services/named_places_store.dart';
import 'ui/voice_memories_screen.dart';


// ---------------------------------------------------------------------------
// WorkManager background task dispatcher (must be a top-level function).
// Handles AI-generated reminder notifications when the app is in background.
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (taskName == 'ai_reminder') {
      await _handleAiReminderTask(inputData ?? {});
    }
    return true;
  });
}

/// Generates AI content and shows a notification, then reschedules if recurring.
Future<void> _handleAiReminderTask(Map<String, dynamic> inputData) async {
  try {
    final reminderId = (inputData['reminder_id'] as num?)?.toInt() ?? 0;
    final recurrence = (inputData['recurrence'] as String?) ?? '';
    final dayOfWeek = (inputData['day_of_week'] as num?)?.toInt() ?? 0;
    final scheduledIso = (inputData['scheduled_iso'] as String?) ?? '';
    final label = (inputData['text'] as String?) ?? 'Reminder';
    final aiPrompt = (inputData['ai_prompt'] as String?) ?? '';

    if (reminderId == 0) return;

    // Check if reminder is still scheduled (not canceled by user).
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('roadmate_reminders_v1');
    bool isCanceled = false;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List?;
        if (decoded != null) {
          for (final item in decoded) {
            if (item is Map && (item['id'] as num?)?.toInt() == reminderId) {
              isCanceled = (item['status'] as String?) == 'canceled';
              break;
            }
          }
        }
      } catch (_) {}
    }
    if (isCanceled) return;

    // Generate AI notification body.
    String notificationBody = label;
    if (aiPrompt.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('${_serverUrl()}/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'prompt': aiPrompt}),
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final content = (data['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) notificationBody = content;
        }
      } catch (e) {
        debugPrint('[AiReminder] Failed to generate content: $e');
      }
    }

    // Queue the reminder for chat history (fires regardless of whether user taps).
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('roadmate_pending_reminder_chat');
      final list = raw != null ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
      list.removeWhere((e) => (e['id'] as num?)?.toInt() == reminderId);
      list.add({'id': reminderId, 'title': label, 'body': notificationBody, 'fireTime': DateTime.now().toIso8601String()});
      await prefs.setString('roadmate_pending_reminder_chat', jsonEncode(list));
    } catch (_) {}

    // Show notification.
    final notifications = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const InitializationSettings(android: androidInit),
    );

    await notifications.show(
      reminderId,
      label,
      notificationBody,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'roadmate_reminders',
          'Reminders',
          channelDescription: 'RoadMate scheduled reminders',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode({'reminder_id': reminderId, 'title': label, 'body': notificationBody}),
    );

    // Reschedule for next occurrence if recurring.
    if (recurrence.isNotEmpty && scheduledIso.isNotEmpty) {
      try {
        final scheduledLocal = DateTime.parse(scheduledIso);
        final h = scheduledLocal.hour;
        final m = scheduledLocal.minute;
        final now = DateTime.now();

        DateTime nextOccurrence;
        if (recurrence == 'daily') {
          var next = DateTime(now.year, now.month, now.day, h, m);
          if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
          nextOccurrence = next;
        } else {
          // weekly
          final target = dayOfWeek > 0 ? dayOfWeek : scheduledLocal.weekday;
          var next = DateTime(now.year, now.month, now.day, h, m);
          while (next.weekday != target || !next.isAfter(now)) {
            next = next.add(const Duration(days: 1));
          }
          nextOccurrence = next;
        }

        final delay = nextOccurrence.difference(now);
        await Workmanager().registerOneOffTask(
          'ai_reminder_$reminderId',
          'ai_reminder',
          initialDelay: delay.isNegative ? Duration.zero : delay,
          inputData: inputData,
          constraints: Constraints(networkType: NetworkType.connected),
          existingWorkPolicy: ExistingWorkPolicy.replace,
        );
        debugPrint('[AiReminder] Rescheduled id=$reminderId in ${delay.inMinutes}m');
      } catch (e) {
        debugPrint('[AiReminder] Failed to reschedule: $e');
      }
    }
  } catch (e) {
    debugPrint('[AiReminder] Task error: $e');
  }
}

String _serverUrl() => 'https://roadmate-flutter.onrender.com';

/// Main entry point (keets app in portrait mode only)
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize WorkManager for AI-generated reminder background tasks (Android only).
  if (Platform.isAndroid) {
    await Workmanager().initialize(callbackDispatcher);
  }

  // Initialize port for communication between TaskHandler and UI (must be called
  // before addTaskDataCallback so sendDataToMain can find the ReceivePort).
  FlutterForegroundTask.initCommunicationPort();

  // Initialize foreground service for voice mode
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'roadmate_voice_channel',
      channelName: 'RoadMate Voice Assistant',
      channelDescription: 'Keeps voice assistant active when screen is locked',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );

  // some initial setup
  await Config.loadSavedVoice();

  // Initialize reminders service
  await RemindersService.instance.init();

  // Initialize photo index service and start background indexing
  await PhotoIndexService.instance.init();
  PhotoIndexService.instance.buildIndexInBackground();
  PhotoIndexService.instance.startChangeListener();

  // Initialize voice memory store
  await VoiceMemoryStore.instance.init();

  // Initialize driving log store and start background activity monitoring
  await DrivingLogStore.instance.init();
  await DrivingMonitorService.instance.start();

  // Auto-start accessibility listener if already enabled
  if (await AppControlService.instance.isAccessibilityEnabled()) {
    AppControlService.instance.startListening();
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const MyApp());
}

/// Foreground task callback (required by flutter_foreground_task)
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(VoiceForegroundTaskHandler());
}

/// Handler for foreground task
class VoiceForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Called when the foreground service starts
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Called periodically - we don't need to do anything here
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Called when the foreground service is destroyed
  }

  @override
  void onNotificationButtonPressed(String id) {
    // Handle notification button presses (e.g., "Stop" button)
    if (id == 'stop') {
      FlutterForegroundTask.sendDataToMain({'action': 'stopVoice'});
    }
  }

  @override
  void onNotificationPressed() {
    // Handle notification tap - bring app to foreground
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    // Handle notification dismissal
  }
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
    _checkOnboardingStatus();
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
      home: _hasCompletedOnboarding!
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


// final String tokenServerUrl = "http://10.0.2.2:3000/token";
const tokenServerUrl = '${Config.serverUrl}/token';

class _VoiceButtonPageState extends State<VoiceButtonPage> with WidgetsBindingObserver {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _mic;

  // Web search (reuse single instances)
  late final WebSearchClient _webSearchClient = WebSearchClient();
  late final WebSearchTool _webSearchTool = WebSearchTool(client: _webSearchClient);

  // Gmail client (multi-user): initialized with per-install client id.
  late final GmailClient gmailClient;
  String? _clientId;
  // YouTube client
  late final YouTubeClient youtubeClient;

  // Deduplicate tool calls (Realtime may emit in_progress + completed, and can resend events).
  final Set<String> _handledToolCallIds = <String>{};

  // Audio player for thinking sound during long-running tool execution
  final AudioPlayer _thinkingSoundPlayer = AudioPlayer();

  // Conversation store for chat history
  ConversationStore? _conversationStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen for messages from foreground task handler (e.g. notification "Stop" button)
    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data is Map && data['action'] == 'stopVoice') {
        _disconnect();
      }
    });

    // Pre-load thinking sound for instant playback
    _preloadThinkingSound();

    // Initialize conversation store and create new session on app launch
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

      if (mounted) setState(() {});
    });

    // Ensure we have a stable client id for Gmail token storage on the server.
    ClientIdStore.getOrCreate().then((cid) {
      _clientId = cid;
      gmailClient = GmailClient(baseUrl: Config.serverUrl, clientId: cid);
      youtubeClient = YouTubeClient(baseUrl: Config.serverUrl, clientId: cid);
      debugPrint('[ClientId] $cid');
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

      // Listen for voice trigger events from the Quick Settings tile.
      debugPrint('[VoicePage] Registering voice trigger listener (Quick Settings tile)');
      AppControlService.instance.startListeningForButtonEvents(
        // Tile tapped while inactive → start voice
        () {
          debugPrint('[VoicePage] Tile START trigger — connected=$_connected connecting=$_connecting');
          if (!_connected && !_connecting) _connect();
          _minimizeWhenFgsReady();
        },
        onStop: () {
          // Tile tapped while active → stop voice
          debugPrint('[VoicePage] Tile STOP trigger — connected=$_connected');
          if (_connected || _connecting) _disconnect();
          AppControlService.moveToBackground();
        },
      );
    });
  }

  bool _connecting = false;
  bool _connected = false;
  bool _navigatedAway = false;
  String? _status;
  String? _error;

  /// Waits until the foreground service has called startForeground(), then
  /// sends the app to the background. This satisfies Android 14+'s rule that
  /// a microphone-type FGS must call startForeground() while the app is still
  /// in the foreground — a fixed delay is unreliable on slow networks because
  /// _startForegroundService() is called after the HTTP token fetch.
  Future<void> _minimizeWhenFgsReady() async {
    // If already running (e.g. reconnect after tile was used before), go now.
    if (await FlutterForegroundTask.isRunningService) {
      await AppControlService.moveToBackground();
      return;
    }
    // Poll every 100 ms until the service starts (max 10 s).
    for (var i = 0; i < 100; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (await FlutterForegroundTask.isRunningService) {
        await AppControlService.moveToBackground();
        return;
      }
    }
    // Timed out — minimize anyway (connection may have failed).
    await AppControlService.moveToBackground();
  }

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
      final tokenJson = jsonDecode(tokenResp.body) as Map<String, dynamic>;
      final ephemeralKey = tokenJson['value'] as String;

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
          // Force loudspeaker on iOS
          await Helper.setSpeakerphoneOn(true);

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
      await _startForegroundService();

      setState(() {
        _connected = true;
        _status = "Connected. Talk!";
      });
      AppControlService.setTileActive(true);

      // Send initial greeting if enabled
      final greetingEnabled = await Config.getInitialGreetingEnabled();
      if (greetingEnabled) {
        final greetingPhrase = await Config.getInitialGreetingPhrase();
        // Wait a bit for the connection to fully stabilize
        await Future.delayed(const Duration(milliseconds: 500));
        await _sendInitialGreeting(greetingPhrase);
      }
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

    final instructions = await Config.buildSystemPromptWithPreferences();

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
    // Stop thinking sound if it's playing (non-blocking)
    _stopThinkingSound();

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

      // Deactivate tile before stopping the FGS — the OS may call
      // onStartListening when the FGS notification is removed, so the static
      // flag must be false by then or the tile briefly re-shows as active.
      await AppControlService.setTileActive(false);

      // Stop foreground service
      await _stopForegroundService();

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

  /// Start foreground service to keep microphone active when screen is locked.
  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      return; // Already running
    }
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'RoadMate Voice Assistant',
      notificationText: 'Voice mode is active',
      notificationButtons: [
        const NotificationButton(id: 'stop', text: 'Stop'),
      ],
      callback: startCallback,
    );
  }

  /// Stop foreground service when voice mode ends.
  Future<void> _stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
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
  // Calendar tools
  'get_calendar_data': (args) async {
    return await CalendarStore.toolGetCalendarData(args);
  },
  'create_calendar_event': (args) async {
    return await CalendarStore.toolCreateCalendarEvent(args);
  },
  'update_calendar_event': (args) async {
    return await CalendarStore.toolUpdateCalendarEvent(args);
  },
  'delete_calendar_event': (args) async {
    return await CalendarStore.toolDeleteCalendarEvent(args);
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
    final result = await handlePhoneCallTool(args);
    unawaited(_disconnect());
    return result;
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
  // YouTube tools
  'youtube_subscriptions_feed': (_) async {
    return await youtubeClient.getSubscriptionsFeedTool();
  },
  'youtube_open_video': (args) async {
    return await openYoutubeVideoTool(args);
  },
  // Photo album search tool
  'search_photos': (args) async {
    return await PhotoIndexService.instance.toolSearchPhotos(args);
  },
  'rebuild_photo_index': (_) async {
    final result = await PhotoIndexService.instance.buildIndex(forceRebuild: true);
    return result;
  },
  // Voice note tools
  'save_voice_note': (args) async {
    return await VoiceMemoryStore.instance.toolSaveMemory(args);
  },
  'search_voice_notes': (args) async {
    return await VoiceMemoryStore.instance.toolSearchMemories(args);
  },
  // WhatsApp tools
  'take_screenshot': (args) async {
    return await ScreenshotService.instance.takeScreenshot();
  },
  'send_whatsapp_message': (args) async {
    return await WhatsAppService.instance.toolSendWhatsAppMessage(args);
  },
  // App voice control tools (Android only)
  'tap_ui_button': (args) async {
    return await AppControlService.instance.toolTapUiButton(args);
  },
  'get_foreground_app': (args) async {
    return await AppControlService.instance.toolGetForegroundApp(args);
  },
  'launch_app': (args) async {
    return await AppControlService.instance.toolLaunchApp(args);
  },
  'type_text': (args) async {
    return await AppControlService.instance.toolTypeText(args);
  },
  // Driving log tool
  'get_driving_log': (args) async {
    return await DrivingLogStore.instance.toolGetDrivingLog(args);
  },
  // Place visits tools
  'get_place_visits': (args) async {
    return await DrivingLogStore.instance.toolGetPlaceVisits(args);
  },
  'save_named_place': (args) async {
    final location = await getCurrentLocation();
    return await NamedPlacesStore.instance.toolSaveNamedPlace(args, location);
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
      'traffic_eta',
      'youtube_get_subscriptions_feed',
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

  /// Send initial greeting as a user instruction
  Future<void> _sendInitialGreeting(String phrase) async {
    final dc = _dc;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return;

    debugPrint('>>> Sending greeting instruction: $phrase');

    // Send user message instructing the assistant to say the exact phrase
    final userMsg = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {
            'type': 'input_text',
            'text': 'Your first message should be exactly: "$phrase" (say nothing else)',
          }
        ],
      },
    };
    dc.send(RTCDataChannelMessage(jsonEncode(userMsg)));

    // Trigger response
    dc.send(RTCDataChannelMessage(jsonEncode({'type': 'response.create'})));
    debugPrint('>>> Triggered greeting response');
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
        leading: IconButton(
          tooltip: 'Voice Notes',
          icon: const Icon(Icons.auto_stories),
          onPressed: () async {
            _navigatedAway = true;
            await _disconnect();
            if (!mounted) return;
            // ignore: use_build_context_synchronously
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VoiceMemoriesScreen()),
            );
            _navigatedAway = false;
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Chat',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: _conversationStore == null
                ? null
                : () async {
                    _navigatedAway = true;
                    await _disconnect();

                    if (!mounted) return;

                    // ignore: use_build_context_synchronously
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(
                          conversationStore: _conversationStore!,
                          toolExecutor: executeTool,
                        ),
                      ),
                    );
                    _navigatedAway = false;
                  },
          ),
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
              _navigatedAway = false;
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
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
      ),
    );
  }
}

