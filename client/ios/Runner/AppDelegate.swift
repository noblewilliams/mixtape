import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// C5: a Spotify export ZIP the listener handed us from Files or Mail,
  /// already copied into our own temporary directory. Buffered here because
  /// a cold start opens the file before Dart is up; Dart drains it with
  /// `getPendingArchive`, and a push that Dart acknowledges clears it, so
  /// the same file is never delivered twice.
  private var pendingArchive: [String: Any]?
  private var openArchiveChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      MusicKitBridge.register(with: controller.binaryMessenger)
      registerOpenArchiveChannel(with: controller.binaryMessenger)
    }
    GeneratedPluginRegistrant.register(with: self)
    // A launch that exists only to open a file: the URL arrives here, and
    // the open hook below may or may not follow with the same one (either
    // way the archive is buffered once, the newer copy winning).
    if let url = launchOptions?[.url] as? URL, url.isFileURL {
      receive(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// "Open in Mixtape" / "Copy to Mixtape" on a `public.zip-archive`
  /// (declared in Info.plist's CFBundleDocumentTypes). Only file URLs are
  /// ours; anything else stays with the plugins.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.isFileURL else {
      return super.application(app, open: url, options: options)
    }
    receive(url)
    return true
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    openArchiveChannel = channel
  }

  private func receive(_ url: URL) {
    guard let archive = copyIntoTemporaryDirectory(url),
          let path = archive["path"] as? String
    else { return }
    pendingArchive = archive
    openArchiveChannel?.invokeMethod("onOpenedArchive", arguments: archive) { [weak self] reply in
      // Dart answers true once it holds the archive. Anything else (no
      // handler yet on a cold start, an error, a newer file already
      // buffered) leaves it for `getPendingArchive`.
      guard let self, (reply as? Bool) == true else { return }
      if (self.pendingArchive?["path"] as? String) == path {
        self.pendingArchive = nil
      }
    }
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

    let name = url.lastPathComponent.isEmpty ? "export.zip" : url.lastPathComponent
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("opened-archives", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: destination)
      let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      return ["path": destination.path, "name": name, "size": size]
    } catch {
      return nil
    }
  }
}
