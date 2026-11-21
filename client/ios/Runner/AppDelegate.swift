import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// C5: a Spotify export ZIP the listener handed us from Files or Mail,
  /// already copied into our own temporary directory. Buffered here because
  /// a cold start opens the file before Dart's handler is registered; Dart
  /// drains it with `getPendingArchive`, and a push that Dart acknowledges
  /// clears it, so the same file is never delivered twice.
  private var pendingArchive: [String: Any]?
  private var openArchiveChannel: FlutterMethodChannel?

  /// Retained so the native dock and its `mixtape/shell` channel stay alive.
  /// Only ever built on iOS 26 — below that Flutter draws `FrostedDock`.
  private var shellDock: ShellDock?

  /// Retained for the life of the app: the scene's half of launch, the dock
  /// and handed-over ZIPs (see `SceneHooks`).
  private var sceneHooks: SceneHooks?

  /// Retained so the `mixtape/speech` channel — the on-device transcriber
  /// Dart falls back to — stays alive for the life of the app.
  private var speechTranscriber: SpeechTranscriber?

  /// Retained the same way: `mixtape/dictation`, the live recogniser that
  /// writes the listener's words into the composer as they speak.
  private var liveDictation: LiveDictation?

  /// Retained for the same reason: `mixtape/audio_session`, which Dart calls
  /// before recording so the session is ours, or so recording is refused
  /// while our own MusicKit queue is playing.
  private var audioSessionChannel: FlutterMethodChannel?
  private var deviceChannel: FlutterMethodChannel?

  /// Retained so `mixtape/haptics` — the full haptic palette Dart's
  /// `Haptics` plays on every touch — stays alive for the life of the app.
  private var hapticsBridge: HapticsBridge?

  /// The scene's window, once it connects: where the idiom is read from, so
  /// the answer describes the scene the app renders in, not the hardware.
  fileprivate weak var sceneWindow: UIWindow? {
    didSet { answerPendingIdiomQueries() }
  }

  /// `isPad` asked before the scene connected: answered once it has.
  private var pendingIdiomQueries: [FlutterResult] = []

  /// Where those copies live. Everything under it is a listener's whole
  /// export — the identity and payment files the parser refuses to read
  /// included — so it is emptied at launch, and each copy again as soon as
  /// the import that reads it is over.
  private var openedArchivesDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("opened-archives", isDirectory: true)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Anything left from a previous launch is dead: the import that would
    // have read it went with the process.
    purgeOpenedArchives()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Everything the app registers with Flutter. Under the UIScene lifecycle
  /// (required from the iOS 27 SDK, or iOS traps at launch) there is no
  /// window or root view controller at didFinishLaunching: the storyboard's
  /// FlutterViewController builds its engine when the scene connects, and
  /// hands it here first.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let messenger = engineBridge.applicationRegistrar.messenger()
    let registry = engineBridge.pluginRegistry
    MusicKitBridge.register(with: messenger)
    registerOpenArchiveChannel(with: messenger)
    registerVoiceChannels(with: messenger)
    registerDeviceChannel(with: messenger)
    hapticsBridge = HapticsBridge(binaryMessenger: messenger)
    // Liquid Glass for surfaces that live inside Flutter (the collapsing
    // title bar, the Home panel). Flutter only inserts it when the dock is
    // available, and falls back to `FrostedSurface` otherwise.
    if let glassRegistrar = registry.registrar(forPlugin: "mixtape.liquid_glass") {
      glassRegistrar.register(
        LiquidGlassViewFactory(),
        withId: "mixtape/liquid_glass"
      )
    }
    // Native switches, for the Liquid Glass thumb only UIKit draws.
    if let switchRegistrar = registry.registrar(forPlugin: "mixtape.native_switch") {
      switchRegistrar.register(
        NativeSwitchViewFactory(messenger: switchRegistrar.messenger()),
        withId: "mixtape/native_switch"
      )
    }
    // Native segmented controls, for the Liquid Glass thumb only UIKit draws.
    if let segmentedRegistrar = registry.registrar(forPlugin: "mixtape.native_segmented") {
      segmentedRegistrar.register(
        NativeSegmentedViewFactory(messenger: segmentedRegistrar.messenger()),
        withId: "mixtape/native_segmented"
      )
    }
    // Ahead of the plugins, so a handed-over ZIP is taken here before
    // app_links ever sees its file URL.
    if let sceneRegistrar = registry.registrar(forPlugin: "mixtape.scene") {
      let hooks = SceneHooks(app: self, messenger: messenger)
      sceneRegistrar.addSceneDelegate(hooks)
      sceneHooks = hooks
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  /// The approved dock, in genuine Liquid Glass, on iOS 26 only.
  ///
  /// Hosted on the WINDOW, not on the FlutterViewController's view: that
  /// view is the FlutterView, and Flutter re-stacks the platform views it
  /// owns inside it on every composited frame — which would bury the dock
  /// under any platform view that scrolled into its band.
  ///
  /// There is no second-best host: the FlutterView is exactly the view the
  /// compositor owns, so a dock parked there would be buried and eat taps.
  /// Without a window the dock is simply not installed, and Flutter falls
  /// back to `FrostedDock` because `isAvailable` never answers. Nothing is
  /// logged either way: this file must stay free of logging (see the export
  /// privacy contract).
  fileprivate func installDock(in window: UIWindow, messenger: FlutterBinaryMessenger) {
    guard shellDock == nil else { return }
    if #available(iOS 26, *) {
      shellDock = ShellDock(hostView: window, binaryMessenger: messenger)
    }
  }

  /// "Open in Mixtape" / "Copy to Mixtape" on a `public.zip-archive`
  /// (declared in Info.plist's CFBundleDocumentTypes), from the scene: its
  /// connection options on a cold start, its open-URL hook while running.
  /// Only file URLs are ours; anything else stays with the plugins.
  fileprivate func receiveFiles(_ contexts: Set<UIOpenURLContext>) -> Bool {
    let files = contexts.map(\.url).filter(\.isFileURL)
    files.forEach(receive)
    return !files.isEmpty
  }

  /// Voice input: the on-device transcriber and the audio session it and the
  /// recorder both need. Neither logs anything — a clip and a transcript are
  /// the listener's own words, like an export's file name above.
  private func registerVoiceChannels(with messenger: FlutterBinaryMessenger) {
    speechTranscriber = SpeechTranscriber(binaryMessenger: messenger)
    liveDictation = LiveDictation(binaryMessenger: messenger)
    let channel = FlutterMethodChannel(
      name: "mixtape/audio_session",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      AudioSessionBridge.handle(call, result: result)
    }
    audioSessionChannel = channel
  }

  /// Whether this is an iPad. The shell keeps the standard layout there and
  /// docks to the side only on a wide iPhone (unfolded, or in landscape).
  private func registerDeviceChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/device", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "isPad":
        guard let self else { return result(false) }
        self.pendingIdiomQueries.append(result)
        self.answerPendingIdiomQueries()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    deviceChannel = channel
  }

  private func answerPendingIdiomQueries() {
    guard let window = sceneWindow else { return }
    let isPad = window.traitCollection.userInterfaceIdiom == .pad
    let queries = pendingIdiomQueries
    pendingIdiomQueries = []
    queries.forEach { $0(isPad) }
  }

  private func registerOpenArchiveChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/open-archive", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getPendingArchive":
        // Handed over exactly once: a second ask (a later sign-in, a
        // rebuilt provider) gets nothing.
        let pending = self?.pendingArchive
        self?.pendingArchive = nil
        result(pending)
      case "deleteOpenedArchive":
        // The import is over, so our copy of the export goes.
        let path = (call.arguments as? [String: Any])?["path"] as? String
        result(self?.deleteOpenedArchive(at: path) ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    openArchiveChannel = channel
  }

  fileprivate func receive(_ url: URL) {
    guard let archive = copyIntoTemporaryDirectory(url) else {
      // The listener chose a file we could not even copy. Saying so by name
      // is the whole of what we know about it.
      deliver(["error": "unreadable", "name": fileName(of: url)])
      return
    }
    deliver(archive)
  }

  private func deliver(_ payload: [String: Any]) {
    pendingArchive = payload
    openArchiveChannel?.invokeMethod("onOpenedArchive", arguments: payload) { [weak self] reply in
      // Dart answers true once it holds the file. Anything else (no handler
      // yet on a cold start, an error, a newer file already buffered) leaves
      // it for `getPendingArchive`.
      guard let self, (reply as? Bool) == true else { return }
      if self.key(of: self.pendingArchive) == self.key(of: payload) {
        self.pendingArchive = nil
      }
    }
  }

  /// The copy's own directory, and only ever one of ours: a path outside
  /// `tmp/opened-archives` (or the root itself) is refused, not deleted.
  private func deleteOpenedArchive(at path: String?) -> Bool {
    guard let path, !path.isEmpty else { return false }
    let root = openedArchivesDirectory.standardizedFileURL
    let directory = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
    guard directory.path.hasPrefix(root.path + "/") else { return false }
    try? FileManager.default.removeItem(at: directory)
    return true
  }

  private func purgeOpenedArchives() {
    try? FileManager.default.removeItem(at: openedArchivesDirectory)
  }

  /// A document opened in place lives outside our container and is only
  /// readable inside its security scope, which ends as soon as this returns.
  /// Copying it into our own temporary directory under a fresh name lets the
  /// import read it afterwards, and keeps two files of the same name apart.
  ///
  /// Never logs the path or the file name: an export's name is the
  /// listener's, like everything else inside the archive.
  private func copyIntoTemporaryDirectory(_ url: URL) -> [String: Any]? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }

    let name = fileName(of: url)
    let directory = openedArchivesDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: destination)
      let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      // Mail and "Copy to Mixtape" hand the file over by leaving a copy in
      // our own Documents/Inbox. That copy is ours, and keeping it would
      // mean a second, permanent copy of the export.
      if isInsideInbox(url) { try? FileManager.default.removeItem(at: url) }
      return ["path": destination.path, "name": name, "size": size]
    } catch {
      return nil
    }
  }

  private func isInsideInbox(_ url: URL) -> Bool {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    guard let documents else { return false }
    let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
    return url.standardizedFileURL.path.hasPrefix(inbox.path + "/")
  }

  private func fileName(of url: URL) -> String {
    url.lastPathComponent.isEmpty ? "export.zip" : url.lastPathComponent
  }

  /// What tells two hand-overs apart: the copy's path, or the name when
  /// there is no copy.
  private func key(of payload: [String: Any]?) -> String? {
    (payload?["path"] as? String) ?? (payload?["name"] as? String)
  }
}

/// The scene's half of launch, which the app delegate no longer sees under
/// the UIScene lifecycle: installing the dock once the scene has its window,
/// and taking a handed-over ZIP. Flutter's scene delegate forwards both here.
/// Selectors are spelled out because every method is optional: a Swift name
/// that drifted from the Objective-C one would compile and never be called.
private final class SceneHooks: NSObject, FlutterSceneLifeCycleDelegate {
  private weak var app: AppDelegate?
  private let messenger: FlutterBinaryMessenger

  init(app: AppDelegate, messenger: FlutterBinaryMessenger) {
    self.app = app
    self.messenger = messenger
    super.init()
  }

  /// A launch that exists only to open a file carries it here. Answering
  /// YES only when a ZIP was taken keeps a cold-start link with app_links.
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    installDock(on: scene)
    guard let contexts = connectionOptions?.urlContexts else { return false }
    return app?.receiveFiles(contexts) ?? false
  }

  /// A second chance at the dock, should the window arrive after connecting.
  @objc(sceneWillEnterForeground:)
  func sceneWillEnterForeground(_ scene: UIScene) {
    installDock(on: scene)
  }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    app?.receiveFiles(URLContexts) ?? false
  }

  private func installDock(on scene: UIScene) {
    guard let window = (scene.delegate as? FlutterSceneDelegate)?.window else { return }
    app?.sceneWindow = window
    app?.installDock(in: window, messenger: messenger)
  }
}

/// `mixtape/haptics`: plays one pattern from Dart's haptic vocabulary
/// (`lib/presentation/widgets/foundation/haptics.dart`). Dart owns the table
/// of what each touch feels like; this only knows how to play a style at an
/// intensity, so retuning the feel never needs a new binary.
final class HapticsBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
  private let selection = UISelectionFeedbackGenerator()
  private let notification = UINotificationFeedbackGenerator()

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "mixtape/haptics", binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "play" else { return result(FlutterMethodNotImplemented) }
      let args = call.arguments as? [String: Any]
      let style = args?["style"] as? String ?? "light"
      let intensity = CGFloat((args?["intensity"] as? NSNumber)?.doubleValue ?? 1)
      self?.play(style: style, intensity: intensity)
      result(nil)
    }
  }

  private func play(style: String, intensity: CGFloat) {
    switch style {
    case "selection":
      selection.selectionChanged()
      selection.prepare()
    case "success":
      notification.notificationOccurred(.success)
      notification.prepare()
    case "warning":
      notification.notificationOccurred(.warning)
      notification.prepare()
    case "error":
      notification.notificationOccurred(.error)
      notification.prepare()
    default:
      let generator = impact(for: style)
      generator.impactOccurred(intensity: min(max(intensity, 0), 1))
      // The generator goes idle after firing; prime it for the next touch.
      generator.prepare()
    }
  }

  private func impact(for style: String) -> UIImpactFeedbackGenerator {
    let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
    switch style {
    case "soft": feedbackStyle = .soft
    case "rigid": feedbackStyle = .rigid
    case "medium": feedbackStyle = .medium
    case "heavy": feedbackStyle = .heavy
    default: feedbackStyle = .light
    }
    if let existing = impacts[feedbackStyle] { return existing }
    let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
    impacts[feedbackStyle] = generator
    return generator
  }
}
