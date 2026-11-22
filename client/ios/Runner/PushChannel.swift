import Flutter
import UIKit
import UserNotifications

/// `mixtape/push`: mix-ready pushes from APNs, with no Firebase (spec
/// 2026-11-21 durable mix turns → iOS client).
///
/// Dart asks for `status` ("notDetermined" | "authorized" | "denied"),
/// `requestAuthorization` (alert, sound, badge; the status it leaves),
/// `register` (the APNs device token as lowercase hex), `environment`
/// ("sandbox" | "production": the APNs that token belongs to), `appVersion`,
/// `setVisibleSession` ({sessionId} or null: the mix on screen) and
/// `initialTap` (the tap that launched the app, once). It is sent `onTap`
/// ({sessionId, turnId, kind}) for a tap while running, and answers true
/// once it holds it; anything else leaves the tap for `initialTap`.
///
/// ## The notification-center delegate is chained, never replaced
///
/// `UNUserNotificationCenter` has exactly one delegate, and whoever holds it
/// gets every tap and every foreground presentation, local and remote. The
/// app's local notifications (the Spotify request reminder, the quick fix's
/// "Your mix is ready") go through `flutter_local_notifications`, which
/// handles them from the FlutterAppDelegate's plugin fan-out: the app
/// delegate forwards both `UNUserNotificationCenterDelegate` callbacks to
/// every plugin registered as an application delegate.
///
/// So this object is a proxy. `install` captures whatever delegate is set
/// (or, with none, falls back to the app delegate, which is what the plugin
/// expects to be the delegate) and puts itself in front. It handles only our
/// own remote pushes: delivered by APNs (`UNPushNotificationTrigger`) and
/// carrying `sessionId` and `turnId`. A tap on anything else, and any
/// selector it does not implement (for example `openSettingsFor`), goes to
/// the previous delegate unchanged, so the reminder's and the quick fix's
/// taps keep working. Foreground presentation of anything else is the one
/// exception: it stays silent, as it was before this proxy (see
/// `willPresent`).
///
/// It is installed in `didFinishLaunching` (a cold-start tap goes to the
/// delegate that is set when launch finishes) and again after the plugins
/// register, so a plugin that set its own delegate meanwhile is chained
/// rather than overwritten.
///
/// Nothing here is logged: a mix id and a device token are the listener's.
final class PushChannel: NSObject, UNUserNotificationCenterDelegate {
  private var channel: FlutterMethodChannel?

  /// The delegate this one stands in front of. Weak, as the center's own
  /// reference is: its owner keeps it alive.
  private weak var previous: UNUserNotificationCenterDelegate?

  /// Without a previous delegate: the app delegate, whose plugin fan-out is
  /// where `flutter_local_notifications` hears its taps.
  private weak var fallback: UNUserNotificationCenterDelegate?

  /// The mix the listener is looking at: a push for it is not shown while
  /// the app is in the foreground (the transcript shows the turn land).
  private var visibleSessionId: String?

  /// A tap Dart has not taken yet: a cold start's, or one that came before
  /// Dart was listening.
  private var pendingTap: [String: Any]?

  /// Taps already handed on, by notification request id, so a launch tap
  /// that arrives both as a delegate callback and in the scene's connection
  /// options opens once.
  private var deliveredTaps: Set<String> = []

  /// `register` calls waiting for the token callback.
  private var pendingRegistrations: [FlutterResult] = []

  init(fallback: UNUserNotificationCenterDelegate) {
    self.fallback = fallback
    super.init()
  }

  /// Puts this proxy in front of the current delegate. Safe to call again.
  func install() {
    let center = UNUserNotificationCenter.current()
    if let current = center.delegate, current !== self {
      previous = current
    }
    center.delegate = self
  }

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/push", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      self.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      currentStatus { result($0) }
    case "requestAuthorization":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { [weak self] _, _ in
        // The answer, whatever it was, is read back as the status.
        guard let self else { return DispatchQueue.main.async { result("denied") } }
        self.currentStatus { result($0) }
      }
    case "register":
      pendingRegistrations.append(result)
      UIApplication.shared.registerForRemoteNotifications()
    case "environment":
      result(Self.apnsEnvironment)
    case "appVersion":
      let info = Bundle.main.infoDictionary
      let version = info?["CFBundleShortVersionString"] as? String ?? "?"
      let build = info?["CFBundleVersion"] as? String ?? "?"
      result("\(version) (\(build))")
    case "setVisibleSession":
      visibleSessionId = (call.arguments as? [String: Any])?["sessionId"] as? String
      result(nil)
    case "initialTap":
      // Handed over exactly once.
      let tap = pendingTap
      pendingTap = nil
      result(tap)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// On the main queue. Provisional and ephemeral count as authorized: the
  /// push is delivered (quietly, for provisional).
  private func currentStatus(_ answer: @escaping (String) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let name: String
      switch settings.authorizationStatus {
      case .notDetermined: name = "notDetermined"
      case .authorized, .provisional, .ephemeral: name = "authorized"
      case .denied: name = "denied"
      @unknown default: name = "denied"
      }
      DispatchQueue.main.async { answer(name) }
    }
  }

  /// Which APNs issued this build's token: "sandbox" or "production". The
  /// signing profile decides, not the build mode (`flutter run --release`
  /// is development-signed, and Xcode signs with the profile's value), so
  /// it is read from the embedded profile. App Store and TestFlight builds
  /// carry none: production. The simulator registers with the sandbox.
  private static let apnsEnvironment: String = {
    #if targetEnvironment(simulator)
      return "sandbox"
    #else
      guard
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
        let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .isoLatin1),
        let start = text.range(of: "<?xml"),
        let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
        let xml = text[start.lowerBound..<end.upperBound].data(using: .isoLatin1),
        let profile = try? PropertyListSerialization.propertyList(from: xml, format: nil)
          as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let aps = entitlements["aps-environment"] as? String
      else { return "production" }
      return aps == "development" ? "sandbox" : "production"
    #endif
  }()

  // MARK: Token callbacks, forwarded by AppDelegate

  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    answerRegistrations(hex)
  }

  func didFailToRegister(_ error: Error) {
    answerRegistrations(
      FlutterError(code: "register_failed", message: error.localizedDescription, details: nil)
    )
  }

  private func answerRegistrations(_ answer: Any) {
    let waiting = pendingRegistrations
    pendingRegistrations = []
    waiting.forEach { $0(answer) }
  }

  // MARK: Taps

  /// A cold start's tap, from the scene's connection options. The delegate
  /// usually hears it too; [deliveredTaps] keeps it to one.
  func receiveLaunch(_ response: UNNotificationResponse) {
    guard let tap = Self.tap(from: response.notification) else { return }
    receive(tap, id: response.notification.request.identifier)
  }

  private func receive(_ tap: [String: Any], id: String) {
    guard deliveredTaps.insert(id).inserted else { return }
    pendingTap = tap
    channel?.invokeMethod("onTap", arguments: tap) { [weak self] reply in
      // Dart answers true once it holds the tap. Anything else (no listener
      // yet on a cold start, an error) leaves it for `initialTap`.
      guard let self, (reply as? Bool) == true else { return }
      if (self.pendingTap?["turnId"] as? String) == (tap["turnId"] as? String),
        (self.pendingTap?["sessionId"] as? String) == (tap["sessionId"] as? String)
      {
        self.pendingTap = nil
      }
    }
  }

  /// Ours: delivered by APNs, and carrying the mix and the turn. A local
  /// notification never is, even with the same keys.
  private static func tap(from notification: UNNotification) -> [String: Any]? {
    guard notification.request.trigger is UNPushNotificationTrigger else { return nil }
    let info = notification.request.content.userInfo
    guard let sessionId = info["sessionId"] as? String, !sessionId.isEmpty,
      let turnId = info["turnId"] as? String
    else { return nil }
    return [
      "sessionId": sessionId,
      "turnId": turnId,
      "kind": info["kind"] as? String ?? "ready",
    ]
  }

  // MARK: UNUserNotificationCenterDelegate

  private var forwardTarget: UNUserNotificationCenterDelegate? { previous ?? fallback }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if let tap = Self.tap(from: notification) {
      // The mix on screen already shows its turn land.
      if let visible = visibleSessionId, visible == tap["sessionId"] as? String {
        completionHandler([])
      } else {
        completionHandler([.banner, .list, .sound])
      }
      return
    }
    // Anything else (the Spotify reminder, the quick fix's "Your mix is
    // ready", a remote push that is not ours) stays silent in the foreground,
    // exactly as before this proxy existed: with no delegate at all, iOS
    // presents nothing. It is deliberately not forwarded. The only one
    // downstream that answers is flutter_local_notifications, whose
    // `willPresent` has no side effect beyond choosing presentation options,
    // and it would choose a banner (its defaults present alert, banner, list
    // and sound), a visible change from today.
    completionHandler([])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let tap = Self.tap(from: response.notification) {
      // A tap on the notification, not a dismissal.
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
        receive(tap, id: response.notification.request.identifier)
      }
      completionHandler()
      return
    }
    let forwarded: Void? = forwardTarget?.userNotificationCenter?(
      center,
      didReceive: response,
      withCompletionHandler: completionHandler
    )
    if forwarded == nil { completionHandler() }
  }

  // Every other selector (`openSettingsFor`, and whatever a later iOS adds)
  // answers and goes exactly as it would without this proxy.

  override func responds(to aSelector: Selector!) -> Bool {
    if super.responds(to: aSelector) { return true }
    return forwardTarget?.responds(to: aSelector) ?? false
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let target = forwardTarget, target.responds(to: aSelector) { return target }
    return super.forwardingTarget(for: aSelector)
  }
}
