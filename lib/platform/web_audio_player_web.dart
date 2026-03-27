import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:dart_webrtc/src/media_stream_impl.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;

web.HTMLAudioElement? _audioEl;

/// Attaches a remote WebRTC audio stream to a hidden <audio> element so the
/// browser plays it back. Must be called from a user-gesture context (it is —
/// the user already pressed the mic button).
void attachRemoteAudio(MediaStream? stream) {
  detachRemoteAudio();
  if (stream == null || stream is! MediaStreamWeb) return;

  final audio = web.document.createElement('audio') as web.HTMLAudioElement;
  audio.autoplay = true;

  // Set srcObject via generic property access to avoid package:web type issues.
  (audio as JSObject).setProperty('srcObject'.toJS, stream.jsStream);

  // Append to body so the element is active; play() is implicit via autoplay.
  web.document.body?.append(audio);
  audio.play().toDart.ignore();

  _audioEl = audio;
}

void detachRemoteAudio() {
  _audioEl?.pause();
  ((_audioEl) as JSObject?)?.setProperty('srcObject'.toJS, null);
  _audioEl?.remove();
  _audioEl = null;
}
