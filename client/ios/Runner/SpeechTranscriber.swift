import AVFoundation
import Flutter
import MusicKit
import Speech
import QuartzCore
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

/// Live dictation, behind `mixtape/dictation` (start, stop, cancel) and
/// `mixtape/dictation/events` (`{type: partial, text}`, `{type: level,
/// value}`): the listener's words appear in the composer as they speak.
///
/// One input tap feeds two things at once: Apple's recogniser, for the words
/// shown live, and a clip on disk, which Dart sends to the server for a
/// better pass when the listener stops. Dart activates the audio session
/// first (`mixtape/audio_session`), so music playing is refused there.
///
/// Nothing here logs: the words and the clip are the listener's own.
final class LiveDictation: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?

  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var writer: ClipWriter?
  private var clipURL: URL?
  private var latest = ""
  private var finished: (() -> Void)?

  /// Bumped whenever a dictation ends, so a late callback from the last one
  /// writes nothing into the next.
  private var generation = 0

  /// How long `stop` waits for the recogniser's final words after the audio
  /// ends, before answering with the last partial ones.
  private static let finalWait: TimeInterval = 1.5

  init(binaryMessenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "mixtape/dictation", binaryMessenger: binaryMessenger)
    events = FlutterEventChannel(name: "mixtape/dictation/events", binaryMessenger: binaryMessenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "start":
        let arguments = call.arguments as? [String: Any]
        guard let path = arguments?["path"] as? String, !path.isEmpty else {
          result(FlutterError(code: "FAILED", message: nil, details: nil))
          return
        }
        let vocabulary = arguments?["contextualStrings"] as? [String] ?? []
        self.start(path: path, vocabulary: vocabulary, result: result)
      case "stop":
        self.stop(result: result)
      case "cancel":
        self.teardown(deleteClip: true)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func start(path: String, vocabulary: [String], result: @escaping FlutterResult) {
    teardown(deleteClip: true)
    // Speech first: without it Dart records the old way, with no live words.
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(FlutterError(code: "SPEECH_DENIED", message: nil, details: nil))
          return
        }
        self.requestMicrophone { granted in
          guard granted else {
            result(FlutterError(code: "MIC_DENIED", message: nil, details: nil))
            return
          }
          guard let recognizer = Self.recognizer() else {
            result(FlutterError(code: "UNAVAILABLE", message: nil, details: nil))
            return
          }
          do {
            try self.begin(
              url: URL(fileURLWithPath: path),
              recognizer: recognizer,
              vocabulary: vocabulary
            )
            result(nil)
          } catch {
            self.teardown(deleteClip: true)
            result(FlutterError(code: "UNAVAILABLE", message: nil, details: nil))
          }
        }
      }
    }
  }

  private func requestMicrophone(_ done: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async { done(granted) }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async { done(granted) }
      }
    }
  }

  /// en-US is what the DJ is asked in; a device set to another language gets
  /// its own recogniser rather than nothing at all.
  private static func recognizer() -> SFSpeechRecognizer? {
    if let english = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), english.isAvailable {
      return english
    }
    if let local = SFSpeechRecognizer(locale: Locale.current), local.isAvailable {
      return local
    }
    return nil
  }

  private func begin(url: URL, recognizer: SFSpeechRecognizer, vocabulary: [String]) throws {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.addsPunctuation = true
    request.contextualStrings = Array(vocabulary.prefix(100))
    // The live words never leave the phone: a device that cannot recognise
    // on its own records the old way instead, rather than streaming the
    // listener's voice to a server the AI consent does not name. The clip
    // goes to our server only once the listener stops, as it always has.
    guard recognizer.supportsOnDeviceRecognition else {
      throw NSError(domain: "LiveDictation", code: 2)
    }
    request.requiresOnDeviceRecognition = true

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "LiveDictation", code: 1)
    }
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
      ],
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    let writer = ClipWriter(file: file)
    let meter = LevelMeter()
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      writer.write(buffer)
      if let level = meter.level(of: buffer) {
        DispatchQueue.main.async { self?.sink?(["type": "level", "value": level]) }
      }
    }
    engine.prepare()
    try engine.start()

    generation += 1
    let current = generation
    self.engine = engine
    self.request = request
    self.writer = writer
    self.clipURL = url
    self.latest = ""
    task = recognizer.recognitionTask(with: request) { [weak self] transcription, error in
      DispatchQueue.main.async {
        guard let self, self.generation == current else { return }
        if let transcription {
          self.latest = transcription.bestTranscription.formattedString
          self.sink?(["type": "partial", "text": self.latest])
          if transcription.isFinal { self.finish() }
        } else if error != nil {
          self.finish()
        }
      }
    }
  }

  /// The audio ends, the clip is closed, and the answer waits for the
  /// recogniser's final words — or [finalWait], whichever comes first.
  private func stop(result: @escaping FlutterResult) {
    guard let engine, let request else {
      result(FlutterError(code: "FAILED", message: nil, details: nil))
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    request.endAudio()
    writer?.close()

    var answered = false
    let answer: () -> Void = { [weak self] in
      guard let self, !answered else { return }
      answered = true
      let path: Any = self.clipURL?.path ?? NSNull()
      let text = self.latest
      self.teardown(deleteClip: false)
      result(["path": path, "text": text])
    }
    finished = answer
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalWait) { answer() }
  }

  private func finish() {
    let done = finished
    finished = nil
    done?()
  }

  private func teardown(deleteClip: Bool) {
    generation += 1
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    task?.cancel()
    task = nil
    request = nil
    writer?.close()
    writer = nil
    finished = nil
    if deleteClip, let clipURL {
      try? FileManager.default.removeItem(at: clipURL)
    }
    clipURL = nil
    latest = ""
  }
}

/// The clip the tap writes to, closed from the main thread while the audio
/// thread may still be writing: dropping the last reference to the file is
/// what finishes it, so both sides go through one lock.
private final class ClipWriter {
  private var file: AVAudioFile?
  private let lock = NSLock()

  init(file: AVAudioFile) {
    self.file = file
  }

  func write(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    try? file?.write(from: buffer)
  }

  func close() {
    lock.lock()
    file = nil
    lock.unlock()
  }
}

/// The input level, 0–1 over the same −50 dBFS floor Dart's meter uses,
/// at most every 120 ms. Lives on the audio thread.
private final class LevelMeter {
  private var last: CFTimeInterval = 0
  private static let interval: CFTimeInterval = 0.12
  private static let floorDb: Float = -50

  func level(of buffer: AVAudioPCMBuffer) -> Double? {
    let now = CACurrentMediaTime()
    guard now - last >= Self.interval,
          let channel = buffer.floatChannelData?[0],
          buffer.frameLength > 0 else { return nil }
    last = now
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) {
      let sample = channel[index]
      sum += sample * sample
    }
    let rms = (sum / Float(buffer.frameLength)).squareRoot()
    let decibels = 20 * log10(max(rms, 0.000_001))
    let level = (decibels - Self.floorDb) / -Self.floorDb
    return Double(min(max(level, 0), 1))
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
