import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// C5: a Spotify export ZIP the listener handed us from Files or Mail,
  /// already copied into our own temporary directory. Buffered here because
  /// a cold start opens the file before Dart's handler is registered; Dart
  /// drains it with `getPendingArchive`, and a push that Dart acknowledges
  /// clears it, so the same file is never delivered twice.
  private var pendingArchive: [String: Any]?
  private var openArchiveChannel: FlutterMethodChannel?

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
    if let controller = window?.rootViewController as? FlutterViewController {
      MusicKitBridge.register(with: controller.binaryMessenger)
      registerOpenArchiveChannel(with: controller.binaryMessenger)
    }
    GeneratedPluginRegistrant.register(with: self)
    // A launch that exists only to open a file delivers it through the open
    // hook below, which runs straight after this returns. Copying the launch
    // URL here as well would leave a second copy of the export behind.
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

  private func receive(_ url: URL) {
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
