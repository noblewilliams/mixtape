import AVFoundation
import Flutter
import MusicKit
import Speech
import UIKit

/// The on-device fallback transcriber, behind the `mixtape/speech` channel.
///
/// Dart records one clip and asks the server first; this runs only when the
/// server could not answer. Nothing here logs: the clip is a listener's voice
/// and the transcript is their words, and neither may reach a device log.
final class SpeechTranscriber: NSObject {
  private let channel: FlutterMethodChannel

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "mixtape/speech",
      binaryMessenger: binaryMessenger
    )
    super.init()
    bind()
  }

  private func bind() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "transcribeFile":
        guard let path = call.arguments as? String, !path.isEmpty else {
          result(FlutterError(code: "FILE_NOT_FOUND", message: "No clip path", details: nil))
          return
        }
        self.transcribe(path: path, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// en-US is what the DJ is asked in; a device set to another language gets
  /// its own recogniser rather than nothing at all.
  private func recognizer() -> SFSpeechRecognizer? {
    if let english = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), english.isAvailable {
      return english
    }
    if let local = SFSpeechRecognizer(locale: Locale.current), local.isAvailable {
      return local
    }
    return nil
  }

  private func transcribe(path: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "No clip at that path", details: nil))
      return
    }
    // Authorization first: a recogniser reports itself unavailable until the
    // listener has been asked, so checking availability before the prompt
    // would fail the very first use without ever showing it.
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        switch status {
        case .authorized:
          guard let recognizer = self.recognizer() else {
            result(FlutterError(
              code: "RECOGNIZER_UNAVAILABLE",
              message: "No speech recogniser is available",
              details: nil
            ))
            return
          }
          self.run(url: URL(fileURLWithPath: path), recognizer: recognizer, result: result)
        case .denied:
          result(FlutterError(code: "PERMISSION_DENIED", message: nil, details: nil))
        case .restricted:
          result(FlutterError(code: "PERMISSION_RESTRICTED", message: nil, details: nil))
        case .notDetermined:
          result(FlutterError(code: "PERMISSION_NOT_DETERMINED", message: nil, details: nil))
        @unknown default:
          result(FlutterError(code: "RECOGNITION_FAILED", message: nil, details: nil))
        }
      }
    }
  }

  /// A recognition task reports partial results, and can report an error after
  /// a final one; a `FlutterResult` may be called exactly once, so the first
  /// answer wins and the rest are dropped.
  private func run(
    url: URL,
    recognizer: SFSpeechRecognizer,
    result: @escaping FlutterResult
  ) {
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    // The clip never leaves the phone on this path — that is the whole point
    // of the fallback — when the device can do it.
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }

    var hasResolved = false
    let resolve: (Any?) -> Void = { answer in
      guard !hasResolved else { return }
      hasResolved = true
      DispatchQueue.main.async { result(answer) }
    }

    recognizer.recognitionTask(with: request) { transcription, error in
      if let transcription, transcription.isFinal {
        resolve(transcription.bestTranscription.formattedString)
        return
      }
      if error != nil {
        resolve(FlutterError(code: "RECOGNITION_FAILED", message: nil, details: nil))
      }
    }
  }
}

/// The audio session, behind `mixtape/audio_session`.
///
/// Recording needs `.playAndRecord`, which would tear down the category the
/// app's own MusicKit playback runs under. So a listener who is playing music
/// is asked to pause rather than having the music stopped for them.
enum AudioSessionBridge {
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "activate":
      activate(result: result)
    case "deactivate":
      deactivate(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func activate(result: @escaping FlutterResult) {
    if isPlaying {
      result(FlutterError(code: "PLAYBACK_ACTIVE", message: nil, details: nil))
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try session.setActive(true, options: [])
      result(true)
    } catch {
      result(FlutterError(code: "AUDIO_SESSION", message: nil, details: nil))
    }
  }

  private static func deactivate(result: @escaping FlutterResult) {
    // Handing the session back is best effort: a failure here only means
    // another app keeps ducking a moment longer.
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
    result(true)
  }

  /// Our own queue, the one `MusicKitBridge` plays through.
  private static var isPlaying: Bool {
    ApplicationMusicPlayer.shared.state.playbackStatus == .playing
  }
}
