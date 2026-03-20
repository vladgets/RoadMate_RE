import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var buttonEventSink: FlutterEventSink?
  private var pendingButtonEvent: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register the voice-trigger EventChannel so iOS can forward Flic button
    // single-press events (via roadmate:// URL scheme) to Flutter.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterEventChannel(
        name: "roadmate/accessibility_button",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setStreamHandler(self)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Called when the Flic app opens roadmate://voice
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "roadmate" && url.host == "voice" {
      let event = "flic_tap"
      if let sink = buttonEventSink {
        sink(event)
      } else {
        pendingButtonEvent = event
      }
      return true
    }
    return super.application(app, open: url, options: options)
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    buttonEventSink = events
    if let pending = pendingButtonEvent {
      events(pending)
      pendingButtonEvent = nil
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    buttonEventSink = nil
    return nil
  }
}
