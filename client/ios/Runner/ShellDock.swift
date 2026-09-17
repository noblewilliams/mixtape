import Flutter
import UIKit

/// The approved native dock: a real `UITabBar` with the four Mixtape tabs and,
/// above it, a mini-player in genuine Liquid Glass
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock, Platform
/// differences).
///
/// iOS 26 only — `AppDelegate` never instantiates this below that, and Flutter
/// draws `FrostedDock` instead. Everything iOS-26-specific is still guarded,
/// because the deployment target is 16.0 and this file has to compile for it.
///
/// Both views are installed in the WINDOW, not in the FlutterViewController's
/// view: that view *is* the FlutterView, and Flutter's iOS compositor
/// re-stacks the platform views it owns inside it on every composited frame.
/// A sibling parked in there gets pushed under them and swallows the taps
/// meant for it; re-fronting cannot win that race. One level up is out of the
/// compositor's reach for good (the lesson goalympics learned the hard way).
class ShellDock: NSObject {

  private let tabBar = UITabBar()
  private let miniPlayer: MiniPlayerView
  private let channel: FlutterMethodChannel
  private weak var hostView: UIView?
  private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

  /// Independent of `hide()`/`show()`, which are route-level visibility.
  private var isMinimized = false

  /// A route inside a mix has hidden the dock. `setMiniPlayer` then records
  /// what is playing without putting the pill back on screen; `show()`
  /// applies whatever arrived while the dock was away.
  /// Starts hidden: nothing is shown until the Flutter shell mounts and
  /// calls `show()`, so sign-in and onboarding never see the dock.
  private var isRouteHidden = true

  /// What Flutter last asked the mini-player to be, regardless of whether the
  /// route currently allows it on screen.
  private var isMiniWanted = false

  init(hostView: UIView, binaryMessenger: FlutterBinaryMessenger) {
    self.hostView = hostView
    self.channel = FlutterMethodChannel(
      name: "mixtape/shell",
      binaryMessenger: binaryMessenger
    )
    self.miniPlayer = MiniPlayerView()
    super.init()

    configureTabBar()
    installInHostView()
    bindChannel()
    observeAccessibility()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Tab bar

  /// The four approved tabs, in shell order. Tags mirror the Dart tab indices
  /// so `didSelect(item.tag)` and `setTab(index)` stay consistent.
  private func configureTabBar() {
    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)

    let home = UITabBarItem(
      title: "Home",
      image: UIImage(systemName: "house", withConfiguration: config),
      selectedImage: UIImage(systemName: "house.fill", withConfiguration: config)
    )
    home.tag = 0

    // The cassette is the motif; a symbol set without it falls back to a list.
    let tape = UIImage(systemName: "recordingtape", withConfiguration: config)
      ?? UIImage(systemName: "music.note.list", withConfiguration: config)
    let mixes = UITabBarItem(title: "Mixes", image: tape, selectedImage: tape)
    mixes.tag = 1

    let library = UITabBarItem(
      title: "Library",
      image: UIImage(systemName: "books.vertical", withConfiguration: config),
      selectedImage: UIImage(systemName: "books.vertical.fill", withConfiguration: config)
    )
    library.tag = 2

    let you = UITabBarItem(
      title: "You",
      image: UIImage(systemName: "person", withConfiguration: config),
      selectedImage: UIImage(systemName: "person.fill", withConfiguration: config)
    )
    you.tag = 3

    tabBar.items = [home, mixes, library, you]
    tabBar.selectedItem = home
    tabBar.delegate = self

    // Default appearance, deliberately: iOS 26 dresses a UITabBar in its own
    // Liquid Glass only while the appearance is untouched.
    tabBar.tintColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.949, green: 0.933, blue: 0.945, alpha: 1)
        : UIColor(red: 0.110, green: 0.102, blue: 0.118, alpha: 1)
    }
    tabBar.unselectedItemTintColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.596, green: 0.573, blue: 0.604, alpha: 1)
        : UIColor(red: 0.522, green: 0.494, blue: 0.525, alpha: 1)
    }

    hapticGenerator.prepare()
  }

  // MARK: - Layout

  private func installInHostView() {
    guard let hostView = hostView else { return }

    tabBar.translatesAutoresizingMaskIntoConstraints = false
    miniPlayer.translatesAutoresizingMaskIntoConstraints = false
    hostView.addSubview(tabBar)
    hostView.addSubview(miniPlayer)

    NSLayoutConstraint.activate([
      // A bare UITabBar in a window is edge-to-edge, so the 22 pt margins are
      // pinned by hand to match the mini-player and the Flutter FrostedDock
      // pill. If iOS 26 turns out to inset the floating bar itself, the extra
      // inset will show at the device gate — drop these two constraints then.
      tabBar.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: 22),
      tabBar.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -22),
      tabBar.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

      // The board's floating pill: 22 pt side margins, 52 pt tall, 7 pt above
      // the bar. It stays put when the bar minimises.
      miniPlayer.leadingAnchor.constraint(
        equalTo: hostView.leadingAnchor, constant: 22),
      miniPlayer.trailingAnchor.constraint(
        equalTo: hostView.trailingAnchor, constant: -22),
      miniPlayer.bottomAnchor.constraint(
        equalTo: tabBar.topAnchor, constant: -7),
      miniPlayer.heightAnchor.constraint(equalToConstant: 52),
    ])

    miniPlayer.isHidden = true
    miniPlayer.alpha = 0
    tabBar.isHidden = true
    tabBar.alpha = 0
    miniPlayer.onTapped = { [weak self] in
      self?.channel.invokeMethod("miniPlayerTapped", arguments: nil)
    }
    miniPlayer.onPlayPause = { [weak self] in
      self?.channel.invokeMethod("miniPlayerPlayPause", arguments: nil)
    }
    miniPlayer.onNext = { [weak self] in
      self?.channel.invokeMethod("miniPlayerNext", arguments: nil)
    }

    // We install during didFinishLaunching, before the root controller's view
    // is attached — so on some launches THAT lands on top and hides the dock
    // entirely. Re-front once the hierarchy has settled.
    DispatchQueue.main.async { [weak self] in self?.bringToFront() }
  }

  /// Re-raises the dock after UIKit attaches the root controller's view.
  /// Needed once, at launch: the dock otherwise lives outside Flutter's
  /// platform-view hierarchy.
  func bringToFront() {
    tabBar.superview?.bringSubviewToFront(tabBar)
    miniPlayer.superview?.bringSubviewToFront(miniPlayer)
  }

  // MARK: - Visibility

  /// Fades both pieces away — a pushed route inside a mix owns the screen.
  func hide() {
    isRouteHidden = true
    animate {
      self.tabBar.alpha = 0
      self.miniPlayer.alpha = 0
    } completion: { finished in
      // A fast hide → show cancels this fade. Hiding the views on a cancelled
      // completion would leave the dock invisible at alpha 1.
      guard finished else { return }
      self.tabBar.isHidden = true
      self.miniPlayer.isHidden = true
    }
  }

  /// Fades both back, always at full size, with whatever the mini-player was
  /// told to show while the dock was hidden.
  func show() {
    isRouteHidden = false
    isMinimized = false
    tabBar.isHidden = false
    if isMiniWanted { miniPlayer.isHidden = false }
    animate {
      self.tabBar.alpha = 1
      self.tabBar.transform = .identity
      self.miniPlayer.alpha = self.isMiniWanted ? 1 : 0
    } completion: { finished in
      guard finished else { return }
      self.miniPlayer.isHidden = !self.isMiniWanted
    }
  }

  /// Scroll shrinks the tab bar to 70%, anchored to the bottom edge so it
  /// stays grounded and centred. The mini-player stays where it is.
  func setMinimized(_ minimized: Bool) {
    guard isMinimized != minimized else { return }
    isMinimized = minimized
    tabBar.layer.removeAllAnimations()
    let transform = minimizedTransform
    guard !UIAccessibility.isReduceMotionEnabled else {
      tabBar.transform = transform
      return
    }
    UIView.animate(
      withDuration: 0.3,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState],
      animations: { self.tabBar.transform = transform }
    )
  }

  private var minimizedTransform: CGAffineTransform {
    guard isMinimized else { return .identity }
    let scale: CGFloat = 0.7
    let dy = tabBar.frame.height * (1 - scale) / 2
    return CGAffineTransform(translationX: 0, y: dy).scaledBy(x: scale, y: scale)
  }

  /// The glass resolves against the iOS system appearance, so Flutter pushes
  /// its own resolved brightness down whenever the app theme changes.
  func setAppearance(isDark: Bool) {
    let style: UIUserInterfaceStyle = isDark ? .dark : .light
    tabBar.overrideUserInterfaceStyle = style
    miniPlayer.overrideUserInterfaceStyle = style
  }

  /// 200 ms, or instantly under Reduce Motion.
  private func animate(
    _ changes: @escaping () -> Void,
    completion: ((Bool) -> Void)? = nil
  ) {
    tabBar.layer.removeAllAnimations()
    miniPlayer.layer.removeAllAnimations()
    guard !UIAccessibility.isReduceMotionEnabled else {
      changes()
      completion?(true)
      return
    }
    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState],
      animations: changes,
      completion: { finished in completion?(finished) }
    )
  }

  // MARK: - Accessibility

  private func observeAccessibility() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceTransparencyChanged),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil
    )
  }

  @objc private func reduceTransparencyChanged() {
    let reduced = UIAccessibility.isReduceTransparencyEnabled
    channel.invokeMethod("reduceTransparencyChanged", arguments: reduced)
  }

  // MARK: - Method channel

  private func bindChannel() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }

      switch call.method {
      case "isAvailable":
        // The dock only exists on iOS 26; reaching this handler at all means
        // it was installed.
        if #available(iOS 26, *) {
          result(true)
        } else {
          result(false)
        }

      case "setTab":
        guard let index = call.arguments as? Int,
          let items = self.tabBar.items,
          index >= 0, index < items.count
        else {
          result(
            FlutterError(
              code: "INVALID_INDEX", message: "Tab index out of range",
              details: nil))
          return
        }
        self.tabBar.selectedItem = items[index]
        result(nil)

      case "show":
        self.show()
        result(nil)

      case "hide":
        self.hide()
        result(nil)

      case "setMinimized":
        guard let minimized = call.arguments as? Bool else {
          result(
            FlutterError(
              code: "INVALID_ARG", message: "setMinimized expects a Bool",
              details: nil))
          return
        }
        self.setMinimized(minimized)
        result(nil)

      case "setMiniPlayer":
        guard let args = call.arguments as? [String: Any] else {
          result(
            FlutterError(
              code: "INVALID_ARG", message: "setMiniPlayer expects a map",
              details: nil))
          return
        }
        self.applyMiniPlayer(args)
        result(nil)

      case "setAppearance":
        guard let isDark = call.arguments as? Bool else {
          result(
            FlutterError(
              code: "INVALID_ARG", message: "setAppearance expects a Bool",
              details: nil))
          return
        }
        self.setAppearance(isDark: isDark)
        result(nil)

      case "getReduceTransparency":
        result(UIAccessibility.isReduceTransparencyEnabled)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func applyMiniPlayer(_ args: [String: Any]) {
    let visible = args["visible"] as? Bool ?? false
    isMiniWanted = visible
    miniPlayer.apply(
      title: args["title"] as? String ?? "",
      artist: args["artist"] as? String ?? "",
      artworkUrl: args["artworkUrl"] as? String,
      playing: args["playing"] as? Bool ?? false
    )

    // Inside a mix the dock is gone: keep the state, reveal nothing. `show()`
    // puts the pill back when the route returns.
    guard !isRouteHidden else { return }
    // Already in the asked-for state: only the labels changed.
    guard miniPlayer.isHidden == visible else { return }
    if visible { miniPlayer.isHidden = false }
    animate {
      self.miniPlayer.alpha = visible ? 1 : 0
    } completion: { finished in
      guard finished else { return }
      self.miniPlayer.isHidden = !visible
    }
  }
}

// MARK: - UITabBarDelegate

extension ShellDock: UITabBarDelegate {
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    hapticGenerator.impactOccurred()
    // The generator goes idle after firing; prime it for the next tap.
    hapticGenerator.prepare()
    channel.invokeMethod("tabChanged", arguments: item.tag)
  }
}

// MARK: - Mini-player

/// The board's floating mini-player: 38 pt artwork, two lines of text, a
/// play/pause and a next button, on real Liquid Glass. A tap anywhere else
/// opens the mix.
final class MiniPlayerView: UIView {

  private let glass: UIVisualEffectView
  private let artwork = UIImageView()
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let playPauseButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)

  /// The latest artwork URL, so a slow download that lost its race is dropped.
  private var artworkUrl: String?
  private var artworkTask: URLSessionDataTask?

  var onTapped: (() -> Void)?
  var onPlayPause: (() -> Void)?
  var onNext: (() -> Void)?

  init() {
    if #available(iOS 26, *) {
      glass = UIVisualEffectView(effect: UIGlassEffect())
    } else {
      glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    super.init(frame: .zero)
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  private func build() {
    layer.cornerRadius = 26  // Fully rounded at 52 pt tall.
    layer.cornerCurve = .continuous
    clipsToBounds = true

    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)

    artwork.translatesAutoresizingMaskIntoConstraints = false
    artwork.contentMode = .scaleAspectFill
    artwork.clipsToBounds = true
    artwork.layer.cornerRadius = 4
    artwork.layer.cornerCurve = .continuous
    // The placeholder is flat tape fill, never an empty hole.
    artwork.backgroundColor = UIColor(
      red: 0.302, green: 0.251, blue: 0.294, alpha: 1)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.lineBreakMode = .byTruncatingTail

    artistLabel.translatesAutoresizingMaskIntoConstraints = false
    artistLabel.font = .systemFont(ofSize: 12)
    artistLabel.textColor = .secondaryLabel
    artistLabel.lineBreakMode = .byTruncatingTail

    let text = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
    text.translatesAutoresizingMaskIntoConstraints = false
    text.axis = .vertical
    text.alignment = .leading
    text.spacing = 1

    configure(playPauseButton, symbol: "pause.fill", action: #selector(playPauseTapped))
    configure(nextButton, symbol: "forward.fill", action: #selector(nextTapped))

    glass.contentView.addSubview(artwork)
    glass.contentView.addSubview(text)
    glass.contentView.addSubview(playPauseButton)
    glass.contentView.addSubview(nextButton)

    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),

      artwork.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 7),
      artwork.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
      artwork.widthAnchor.constraint(equalToConstant: 38),
      artwork.heightAnchor.constraint(equalToConstant: 38),

      text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
      text.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
      text.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -6),

      playPauseButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
      playPauseButton.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
      playPauseButton.widthAnchor.constraint(equalToConstant: 36),
      playPauseButton.heightAnchor.constraint(equalToConstant: 36),

      nextButton.trailingAnchor.constraint(
        equalTo: glass.contentView.trailingAnchor, constant: -6),
      nextButton.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
      nextButton.widthAnchor.constraint(equalToConstant: 36),
      nextButton.heightAnchor.constraint(equalToConstant: 36),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(surfaceTapped))
    addGestureRecognizer(tap)
  }

  private func configure(_ button: UIButton, symbol: String, action: Selector) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
      for: .normal)
    button.tintColor = .label
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  /// A 36 pt glyph still has to answer a 44 pt touch, so the pill widens the
  /// two buttons' hit areas rather than their frames.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    for button in [nextButton, playPauseButton] {
      let target = button.convert(button.bounds, to: self)
        .insetBy(dx: -4, dy: -4)
      if target.contains(point) { return button }
    }
    return super.hitTest(point, with: event)
  }

  func apply(
    title: String,
    artist: String,
    artworkUrl: String?,
    playing: Bool
  ) {
    titleLabel.text = title
    artistLabel.text = artist
    playPauseButton.setImage(
      UIImage(
        systemName: playing ? "pause.fill" : "play.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
      for: .normal)
    playPauseButton.accessibilityLabel = playing ? "Pause" : "Play"
    nextButton.accessibilityLabel = "Next"
    loadArtwork(artworkUrl)
  }

  private func loadArtwork(_ url: String?) {
    guard artworkUrl != url else { return }
    artworkUrl = url
    artworkTask?.cancel()
    artwork.image = nil

    guard let url, let parsed = URL(string: url), parsed.scheme == "https" else {
      return
    }
    let task = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        // A later track may have won while this was in flight.
        guard self.artworkUrl == url else { return }
        self.artwork.image = image
      }
    }
    artworkTask = task
    task.resume()
  }

  @objc private func surfaceTapped() { onTapped?() }
  @objc private func playPauseTapped() { onPlayPause?() }
  @objc private func nextTapped() { onNext?() }
}

// MARK: - Liquid Glass platform view

/// Exposes a native Liquid Glass surface to Flutter as a platform view
/// (viewType `mixtape/liquid_glass`) for the collapsing title bar and the Home
/// panel. iOS 26 gets the real `UIGlassEffect`; anything older a system blur,
/// though Flutter only inserts this when the dock is available.
///
/// Lives in this file so it inherits its Xcode target membership — a new
/// .swift file silently compiles to nothing until it is added to the target.
final class LiquidGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    // Flutter passes its resolved brightness so the glass follows the in-app
    // theme rather than the iOS system appearance.
    let isDark = (args as? [String: Any])?["isDark"] as? Bool
    return LiquidGlassPlatformView(frame: frame, isDark: isDark)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class LiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let effectView: UIVisualEffectView

  init(frame: CGRect, isDark: Bool?) {
    if #available(iOS 26, *) {
      effectView = UIVisualEffectView(effect: UIGlassEffect())
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    switch isDark {
    case .some(true): effectView.overrideUserInterfaceStyle = .dark
    case .some(false): effectView.overrideUserInterfaceStyle = .light
    case .none: effectView.overrideUserInterfaceStyle = .unspecified
    }
    effectView.frame = frame
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    super.init()
  }

  func view() -> UIView {
    return effectView
  }
}
