import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_accessibility_service/accessibility_event.dart';
import 'package:flutter_accessibility_service/constants.dart';
import 'package:flutter_accessibility_service/flutter_accessibility_service.dart';

class AppControlService {
  static final AppControlService instance = AppControlService._();
  AppControlService._();

  StreamSubscription<AccessibilityEvent>? _sub;

  // ── Voice trigger EventChannel (Quick Settings tile) ───────────────────────

  static const _voiceTriggerChannel =
      EventChannel('roadmate/accessibility_button');

  StreamSubscription<dynamic>? _buttonSub;
  VoidCallback? _onVoiceStart;
  VoidCallback? _onVoiceStop;

  /// Start listening for voice trigger events from the Quick Settings tile.
  /// [onStart] is called when the tile is tapped while inactive (start voice).
  /// [onStop] is called when the tile is tapped while active (stop voice).
  /// Safe to call multiple times — re-entrant calls are ignored.
  void startListeningForButtonEvents(VoidCallback onStart, {VoidCallback? onStop}) {
    _onVoiceStart = onStart;
    _onVoiceStop = onStop;
    _startButtonChannel();
  }

  void _startButtonChannel() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_buttonSub != null) return;
    debugPrint('[AppControl] opening voice trigger EventChannel');
    try {
      _buttonSub = _voiceTriggerChannel
          .receiveBroadcastStream()
          .listen(
        (event) {
          debugPrint('[AppControl] voice trigger event: $event');
          if (event == 'double_tap' || event == 'flic_tap') {
            _onVoiceStart?.call();
          } else if (event == 'stop_voice') {
            _onVoiceStop?.call();
          }
        },
        onError: (e) => debugPrint('[AppControl] voice trigger error: $e'),
        onDone: () {
          debugPrint('[AppControl] voice trigger stream closed — will re-subscribe on next call');
          _buttonSub = null;
        },
      );
      debugPrint('[AppControl] voice trigger EventChannel subscribed');
    } catch (e) {
      debugPrint('[AppControl] voice trigger open error: $e');
    }
  }

  // ── Background navigation ───────────────────────────────────────────────────

  static const _navigationChannel = MethodChannel('roadmate/navigation');

  /// Sends the app to the background without finishing the Activity.
  static Future<void> moveToBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await _navigationChannel.invokeMethod<void>('moveToBackground');
    } catch (e) {
      debugPrint('[AppControl] moveToBackground error: $e');
    }
  }

  // ── QS tile state ───────────────────────────────────────────────────────────

  static const _tileChannel = MethodChannel('roadmate/tile');

  /// Tells the Quick Settings tile whether voice is currently active.
  /// The tile updates its visual state (selected/unselected) and toggles
  /// between start/stop on the next tap.
  static Future<void> setTileActive(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _tileChannel.invokeMethod<void>('setActive', {'active': active});
      debugPrint('[AppControl] setTileActive: $active');
    } catch (e) {
      debugPrint('[AppControl] setTileActive error: $e');
    }
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  /// When each package last received typeWindowStateChanged (focus signal).
  final Map<String, DateTime> _lastFocusTime = {};

  /// When each package last received any rich content event (activity signal).
  final Map<String, DateTime> _lastActivityTime = {};

  /// Last few typeWindowStateChanged events per package.
  final Map<String, List<AccessibilityEvent>> _windowEventsByPkg = {};
  static const _maxWindowEvents = 5;

  /// Recent rich content events per package.
  /// 8 events gives enough coverage for complex screens (Google Maps, etc.).
  /// Staleness is handled by eviction: typeWindowStateChanged clears this
  /// buffer for that package, and _evictStalePackages() removes non-foreground
  /// packages before every query.
  final Map<String, List<AccessibilityEvent>> _contentEventsByPkg = {};
  static const _maxContentEvents = 8;

  bool get isListening => _sub != null;

  // ── Own package ────────────────────────────────────────────────────────────

  static const _ownPackage = 'com.example.road_mate_flutter';

  // ── Ignored packages ───────────────────────────────────────────────────────

  static const _systemPackages = {
    'com.android.systemui', 'android',
    'com.android.launcher', 'com.android.launcher2', 'com.android.launcher3',
    'com.google.android.apps.nexuslauncher',
    'com.miui.home', 'com.sec.android.app.launcher',
    'com.huawei.android.launcher', 'com.oneplus.launcher',
  };

  bool _ignore(String pkg) =>
      pkg.isEmpty || pkg == _ownPackage || _systemPackages.contains(pkg);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void startListening() {
    if (!Platform.isAndroid || _sub != null) return;
    try {
      _sub = FlutterAccessibilityService.accessStream.listen(
        _onEvent,
        onError: (e) => debugPrint('[AppControl] stream error: $e'),
      );
    } catch (e) {
      debugPrint('[AppControl] startListening error: $e');
    }
  }

  void _onEvent(AccessibilityEvent event) {
    final pkg = event.packageName ?? '';
    if (_ignore(pkg)) return;

    final isRich = event.subNodes != null && event.subNodes!.isNotEmpty;
    final nodeCount = isRich ? event.subNodes!.length : 0;

    if (event.eventType == EventType.typeWindowStateChanged) {
      _lastFocusTime[pkg] = DateTime.now();
      // New screen/window for this package — clear stale content events so
      // buttons from the previous screen don't bleed into the new one.
      _contentEventsByPkg.remove(pkg);
      debugPrint('[AppControl] FOCUS pkg=$pkg rich=$isRich nodes=$nodeCount '
          'focused=${event.isFocused} active=${event.isActive}');
      if (isRich) {
        final list = _windowEventsByPkg.putIfAbsent(pkg, () => []);
        list.add(event);
        if (list.length > _maxWindowEvents) list.removeAt(0);
      }
    } else if (isRich) {
      // Track activity timestamp so switching apps is detected even when
      // typeWindowStateChanged never fires (e.g. Google Maps).
      _lastActivityTime[pkg] = DateTime.now();
      final list = _contentEventsByPkg.putIfAbsent(pkg, () => []);
      list.add(event);
      if (list.length > _maxContentEvents) list.removeAt(0);
      debugPrint('[AppControl] CONTENT pkg=$pkg nodes=$nodeCount buf=${list.length}');
    }
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
    _lastFocusTime.clear();
    _lastActivityTime.clear();
    _windowEventsByPkg.clear();
    _contentEventsByPkg.clear();
  }

  // ── Permission helpers ─────────────────────────────────────────────────────

  Future<bool> isAccessibilityEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      return await FlutterAccessibilityService.isAccessibilityPermissionEnabled();
    } catch (e) {
      debugPrint('[AppControl] isAccessibilityEnabled error: $e');
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      const intent = AndroidIntent(action: 'android.settings.ACCESSIBILITY_SETTINGS');
      await intent.launch();
    } catch (e) {
      debugPrint('[AppControl] openAccessibilitySettings error: $e');
    }
  }

  // ── Foreground detection ───────────────────────────────────────────────────

  /// The foreground app = package that had the most recent event of any type.
  ///
  /// Priority:
  /// 1. typeWindowStateChanged (focus) timestamps — strongest signal
  /// 2. Content event timestamps — fallback for apps that never fire focus
  ///    events (e.g. Google Maps only fires typeWindowContentChanged)
  ///
  /// Both maps are merged and the most-recent timestamp wins, ensuring that
  /// switching from Maps to Facebook is detected correctly even if Maps later
  /// sends a background content update.
  String? get foregroundPackage {
    // Merge focus times and activity times, most-recent per package wins.
    // Focus events beat activity events of the same age by the bonus below.
    final combined = <String, DateTime>{};

    // Add activity timestamps first (lower priority)
    for (final e in _lastActivityTime.entries) {
      combined[e.key] = e.value;
    }

    // Add focus timestamps with a small bonus so they beat same-second
    // content events (focus = stronger foreground signal).
    for (final e in _lastFocusTime.entries) {
      final boosted = e.value.add(const Duration(seconds: 5));
      final existing = combined[e.key];
      if (existing == null || boosted.isAfter(existing)) {
        combined[e.key] = boosted;
      }
    }

    if (combined.isEmpty) return null;
    return combined.entries
        .reduce((a, b) => a.value.isAfter(b.value) ? a : b)
        .key;
  }

  /// All cached events for the foreground app: window events + content events.
  /// Only returns events for the CURRENT foreground package — never mixes
  /// events from different apps.
  List<AccessibilityEvent> get _foregroundEvents {
    final pkg = foregroundPackage;
    if (pkg == null) return [];
    return [
      ...(_windowEventsByPkg[pkg] ?? []),
      ...(_contentEventsByPkg[pkg] ?? []),
    ];
  }

  /// Wipe stale cached events for any package that is no longer foreground.
  /// Call before reading screen content to ensure old-app data is gone.
  void _evictStalePackages() {
    final current = foregroundPackage;
    if (current == null) return;
    _windowEventsByPkg.removeWhere((k, _) => k != current);
    _contentEventsByPkg.removeWhere((k, _) => k != current);
  }

  // ── Ensure events ──────────────────────────────────────────────────────────

  Future<bool> _ensureEvents({Duration timeout = const Duration(milliseconds: 800)}) async {
    debugPrint('[AppControl] _ensureEvents: foreground=$foregroundPackage '
        'events=${_foregroundEvents.length}');
    if (_foregroundEvents.isNotEmpty) return true;
    debugPrint('[AppControl] _ensureEvents: waiting up to ${timeout.inMilliseconds}ms...');
    try {
      final event = await FlutterAccessibilityService.accessStream
          .firstWhere((e) {
            final pkg = e.packageName ?? '';
            if (_ignore(pkg)) return false;
            return e.subNodes != null && e.subNodes!.isNotEmpty;
          })
          .timeout(timeout);
      final pkg = event.packageName ?? '';
      debugPrint('[AppControl] _ensureEvents: got event from pkg=$pkg');
      _lastActivityTime[pkg] = DateTime.now();
      _contentEventsByPkg.putIfAbsent(pkg, () => []).add(event);
      return true;
    } catch (e) {
      debugPrint('[AppControl] _ensureEvents: timeout/error: $e');
      return false;
    }
  }

  // ── Node helpers ───────────────────────────────────────────────────────────

  /// Whether a node is interactively tappable.
  /// Checks isClickable flag, actions list (Google Maps leaves isClickable=null
  /// but has actionClick in actions), and isLongClickable as a last resort.
  bool _isTappable(AccessibilityEvent node) {
    if (node.isClickable == true) return true;
    if (node.isLongClickable == true) return true;
    if (node.actions?.contains(NodeAction.actionClick) == true) return true;
    if (node.actions?.contains(NodeAction.actionLongClick) == true) return true;
    return false;
  }

  /// Extracts a human-readable label from a node.
  /// Tries text first; falls back to the resource-id name portion of nodeId.
  /// E.g. nodeId "com.google.android.apps.maps:id/restaurants_chip"
  ///   → "restaurants chip"
  String? _nodeLabel(AccessibilityEvent node) {
    final t = (node.text ?? '').trim();
    if (t.isNotEmpty) return t;

    final id = node.nodeId ?? '';
    final slash = id.lastIndexOf('/');
    if (slash < 0 || slash == id.length - 1) return null;
    final name = id.substring(slash + 1).replaceAll('_', ' ').trim();
    // Skip generic container names that aren't useful button labels
    if (_genericIds.contains(name)) return null;
    return name.isEmpty ? null : name;
  }

  static const _genericIds = {
    'root', 'content', 'container', 'layout', 'frame', 'view',
    'list', 'recycler', 'scroll', 'coordinator', 'drawer',
    'toolbar', 'action bar', 'nav bar', 'status bar',
  };

  // ── Tree search ────────────────────────────────────────────────────────────

  AccessibilityEvent? _searchTree(
    AccessibilityEvent node,
    String exact,
    String lower,
    int pass,
    AccessibilityEvent? nearestTappable,
  ) {
    final tappable = _isTappable(node) ? node : nearestTappable;
    final label = _nodeLabel(node) ?? '';
    if (label.isNotEmpty) {
      final matches = switch (pass) {
        0 => label == exact,
        1 => label.toLowerCase() == lower,
        2 => label.toLowerCase().contains(lower),
        _ => false,
      };
      if (matches) return tappable ?? node;
    }
    for (final child in node.subNodes ?? []) {
      final result = _searchTree(child, exact, lower, pass, tappable);
      if (result != null) return result;
    }
    return null;
  }

  AccessibilityEvent? _findTappableNode(AccessibilityEvent root, String target) {
    final exact = target.trim();
    final lower = exact.toLowerCase();
    for (final pass in [0, 1, 2]) {
      final r = _searchTree(root, exact, lower, pass, null);
      if (r != null) return r;
    }
    return null;
  }

  // ── Screen content ─────────────────────────────────────────────────────────

  Map<String, List<String>> _getScreenContent() {
    final events = _foregroundEvents;
    if (events.isEmpty) return {'buttons': [], 'text': []};

    final buttons = <String>{};
    final allText = <String>{};

    void visit(AccessibilityEvent node) {
      final label = _nodeLabel(node);
      if (label != null) {
        allText.add(label);
        if (_isTappable(node)) buttons.add(label);
      }
      // Clickable container: treat all child text as button labels
      if (_isTappable(node)) {
        void grab(AccessibilityEvent n) {
          final s = _nodeLabel(n);
          if (s != null) buttons.add(s);
          for (final c in n.subNodes ?? []) { grab(c); }
        }
        for (final child in node.subNodes ?? []) { grab(child); }
      }
      for (final child in node.subNodes ?? []) { visit(child); }
    }

    for (final event in events) { visit(event); }

    debugPrint('[AppControl] _getScreenContent: '
        'allText=${allText.length} buttons=${buttons.length}');

    return {'buttons': buttons.toList(), 'text': allText.toList()};
  }

  // ── Tap ────────────────────────────────────────────────────────────────────

  Future<bool> tapButtonByText(String text) async {
    if (!Platform.isAndroid) return false;
    if (!await _ensureEvents()) return false;
    _evictStalePackages();

    for (final event in _foregroundEvents.reversed) {
      final match = _findTappableNode(event, text);
      if (match == null) continue;
      try {
        final ok = await FlutterAccessibilityService.performAction(
            match, NodeAction.actionClick);
        if (ok) return true;
        debugPrint('[AppControl] performAction=false mapId=${match.mapId} '
            'nodeId=${match.nodeId}');
      } catch (e) {
        debugPrint('[AppControl] performAction error: $e');
      }
    }
    return false;
  }

  // ── Tool handlers ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> toolTapUiButton(dynamic args) async {
    final String? buttonText = args['button_text'] as String?;
    final String? appHint = args['app_hint'] as String?;

    if (buttonText == null || buttonText.trim().isEmpty) {
      return {'ok': false, 'error': 'button_text is required'};
    }
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'App control is only supported on Android'};
    }
    final enabled = await isAccessibilityEnabled();
    if (!enabled) {
      return {
        'ok': false,
        'error': 'Accessibility permission not granted. Enable App Control in RoadMate Settings.',
      };
    }
    startListening();

    final tapped = await tapButtonByText(buttonText.trim());
    if (tapped) {
      final label = (appHint != null && appHint.isNotEmpty) ? ' in $appHint' : '';
      return {'ok': true, 'message': 'Tapped "$buttonText"$label'};
    }
    return {
      'ok': false,
      'error': 'Could not tap "$buttonText". Button may have disappeared or is not interactive.',
    };
  }

  // ── App launcher ───────────────────────────────────────────────────────────

  /// Common app name → Android package name mappings.
  static const _appPackages = {
    'google maps': 'com.google.android.apps.maps',
    'maps': 'com.google.android.apps.maps',
    'navigation': 'com.google.android.apps.maps',
    'waze': 'com.waze',
    'spotify': 'com.spotify.music',
    'facebook': 'com.facebook.katana',
    'fb': 'com.facebook.katana',
    'messenger': 'com.facebook.orca',
    'instagram': 'com.instagram.android',
    'whatsapp': 'com.whatsapp',
    'youtube': 'com.google.android.youtube',
    'gmail': 'com.google.android.gm',
    'chrome': 'com.android.chrome',
    'telegram': 'org.telegram.messenger',
    'twitter': 'com.twitter.android',
    'x': 'com.twitter.android',
    'tiktok': 'com.zhiliaoapp.musically',
    'uber': 'com.ubercab',
    'lyft': 'me.lyft.android',
    'netflix': 'com.netflix.mediaclient',
    'snapchat': 'com.snapchat.android',
    'phone': 'com.google.android.dialer',
    'dialer': 'com.google.android.dialer',
    'settings': 'com.android.settings',
    'camera': 'com.android.camera2',
    'photos': 'com.google.android.apps.photos',
    'google photos': 'com.google.android.apps.photos',
    'calendar': 'com.google.android.calendar',
    'messages': 'com.google.android.apps.messaging',
    'sms': 'com.google.android.apps.messaging',
    'play store': 'com.android.vending',
    'google play': 'com.android.vending',
    'maps me': 'com.mapswithme.maps.pro',
    'maps.me': 'com.mapswithme.maps.pro',
    'google': 'com.google.android.googlequicksearchbox',
    'amazon': 'com.amazon.mShop.android.shopping',
    'linkedin': 'com.linkedin.android',
    'discord': 'com.discord',
    'reddit': 'com.reddit.frontpage',
    'zoom': 'us.zoom.videomeetings',
    'slack': 'com.Slack',
    'teams': 'com.microsoft.teams',
    'microsoft teams': 'com.microsoft.teams',
    'outlook': 'com.microsoft.office.outlook',
    'signal': 'org.thoughtcrime.securesms',
  };

  Future<Map<String, dynamic>> toolLaunchApp(dynamic args) async {
    final String? appName = args['app_name'] as String?;
    if (appName == null || appName.trim().isEmpty) {
      return {'ok': false, 'error': 'app_name is required'};
    }
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'App launching is only supported on Android'};
    }

    final key = appName.trim().toLowerCase();
    final pkg = _appPackages[key];
    if (pkg == null) {
      return {
        'ok': false,
        'error': 'Unknown app "$appName". Try the exact app name (e.g. "Spotify", "Google Maps").',
      };
    }

    try {
      const channel = MethodChannel('app_launcher');
      final launched = await channel.invokeMethod<bool>('launchApp', {'package': pkg}) ?? false;
      if (launched) {
        debugPrint('[AppControl] Launched $appName ($pkg)');
        return {'ok': true, 'message': 'Opened $appName'};
      }
      return {'ok': false, 'error': '$appName does not appear to be installed'};
    } catch (e) {
      debugPrint('[AppControl] launch error: $e');
      return {'ok': false, 'error': 'Could not open $appName: $e'};
    }
  }

  // ── Type text ──────────────────────────────────────────────────────────────

  /// Find the first editable node in the tree, optionally near a label hint.
  AccessibilityEvent? _findEditableNode(AccessibilityEvent root, String? hint) {
    AccessibilityEvent? best;

    void walk(AccessibilityEvent node) {
      if (node.isEditable == true) {
        if (hint == null || hint.isEmpty) {
          best ??= node; // take first editable
        } else {
          // Prefer a node whose text or nodeId contains the hint
          final label = (_nodeLabel(node) ?? '').toLowerCase();
          final id = (node.nodeId ?? '').toLowerCase();
          if (label.contains(hint.toLowerCase()) || id.contains(hint.toLowerCase())) {
            best = node;
            return;
          }
          best ??= node; // fallback: first editable
        }
      }
      for (final child in node.subNodes ?? []) { walk(child); }
    }

    walk(root);
    return best;
  }

  Future<Map<String, dynamic>> toolTypeText(dynamic args) async {
    final String? text = args['text'] as String?;
    final String? fieldHint = args['field_hint'] as String?;

    if (text == null || text.isEmpty) {
      return {'ok': false, 'error': 'text is required'};
    }
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'App control is only supported on Android'};
    }
    final enabled = await isAccessibilityEnabled();
    if (!enabled) {
      return {
        'ok': false,
        'error': 'Accessibility permission not granted. Enable App Control in RoadMate Settings.',
      };
    }
    startListening();
    if (!await _ensureEvents()) {
      return {'ok': false, 'error': 'No screen content available'};
    }
    _evictStalePackages();

    AccessibilityEvent? editableNode;
    for (final event in _foregroundEvents.reversed) {
      editableNode = _findEditableNode(event, fieldHint);
      if (editableNode != null) break;
    }

    if (editableNode == null) {
      return {'ok': false, 'error': 'No editable text field found on screen'};
    }

    try {
      // Click first to focus the field
      await FlutterAccessibilityService.performAction(editableNode, NodeAction.actionClick);
      await Future.delayed(const Duration(milliseconds: 200));
      // Set text
      final ok = await FlutterAccessibilityService.performAction(
          editableNode, NodeAction.actionSetText, text);
      if (ok) {
        debugPrint('[AppControl] typed "$text" into ${editableNode.nodeId}');
        return {'ok': true, 'message': 'Typed "$text"'};
      }
      return {'ok': false, 'error': 'Could not type text — field may be read-only'};
    } catch (e) {
      debugPrint('[AppControl] typeText error: $e');
      return {'ok': false, 'error': 'Error typing text: $e'};
    }
  }

  Future<Map<String, dynamic>> toolGetForegroundApp(dynamic args) async {
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'App control is only supported on Android'};
    }
    final enabled = await isAccessibilityEnabled();
    if (!enabled) {
      return {'ok': false, 'error': 'Accessibility permission not granted.'};
    }
    startListening();
    await _ensureEvents();
    _evictStalePackages();

    final pkg = foregroundPackage;
    debugPrint('[AppControl] GET_FOREGROUND: pkg=$pkg '
        'focusTimes=${_lastFocusTime.map((k, v) => MapEntry(k, v.toIso8601String()))} '
        'activityTimes=${_lastActivityTime.map((k, v) => MapEntry(k, v.toIso8601String()))}');

    final content = _getScreenContent();
    debugPrint('[AppControl] GET_FOREGROUND: buttons=${content['buttons']} '
        'textCount=${content['text']?.length}');

    return {
      'ok': true,
      'package_name': pkg ?? 'unknown',
      'buttons': content['buttons'],
      'text': content['text'],
    };
  }
}
