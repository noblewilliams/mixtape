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
  /// Switching tabs is choosing among peers, so it plays the selection tick
  /// like every other toggler in the app (Dart's `HapticKind.select`).
  private let hapticGenerator = UISelectionFeedbackGenerator()

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

  /// iOS 27.1+: the window's root, whose own tab bar the system stands in
  /// the vertical bar (see `ShellTabController`). Nil below that.
  private var verticalHost: UIViewController?

  /// The tabs are in the vertical bar right now, so the bare dock stands
  /// down.
  private var isVertical: Bool {
    if #available(iOS 27.1, *), let host = verticalHost as? ShellTabController {
      return host.isVertical
    }
    return false
  }

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
    installVerticalHost()
    bindChannel()
    observeAccessibility()
  }

  /// Makes a `ShellTabController` the window's root, with Flutter inside it,
  /// so the system can carry the tabs in the vertical bar.
  private func installVerticalHost() {
    guard #available(iOS 27.1, *),
      let window = hostView as? UIWindow,
      let flutter = window.rootViewController as? FlutterViewController
    else { return }
    let host = ShellTabController(flutter: flutter, items: Self.makeItems())
    applyTint(to: host.tabBar)
    // The vertical bar takes its tint from the controller's view, not the
    // bar's own (it draws the system blue otherwise).
    host.view.tintColor = host.tabBar.tintColor
    host.onTabSelected = { [weak self] index in
      guard let self else { return }
      self.hapticGenerator.selectionChanged()
      self.hapticGenerator.prepare()
      self.tabBar.selectedItem = self.tabBar.items?[index]
      self.channel.invokeMethod("tabChanged", arguments: index)
    }
    host.onLayout = { [weak self] in self?.applyBarePlacement() }
    host.onPlacementChanged = { [weak self] vertical in
      guard let self else { return }
      self.applyBarePlacement()
      self.channel.invokeMethod("verticalBarChanged", arguments: vertical)
    }
    window.rootViewController = host
    verticalHost = host
    DispatchQueue.main.async { [weak self] in self?.bringToFront() }
  }

  /// In the vertical bar the bare dock's tab bar stands down; back at the
  /// bottom it returns if the route allows it.
  private func applyBarePlacement() {
    // The root's view is the window's lowest subview, but swapping roots and
    // rotating can put it back over the dock.
    bringToFront()
    guard !isRouteHidden else { return }
    let showBare = !isVertical
    // Idempotent: this runs on every layout pass, and must not cut short a
    // fade already heading the same way.
    guard tabBar.isHidden == showBare || (showBare && tabBar.alpha < 1) else { return }
    tabBar.layer.removeAllAnimations()
    tabBar.isHidden = !showBare
    tabBar.alpha = showBare ? 1 : 0
  }

  private func setVerticalTabsWanted(_ wanted: Bool) {
    if #available(iOS 27.1, *), let host = verticalHost as? ShellTabController {
      host.setTabsWanted(wanted)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Tab bar

  /// The four approved tabs, in shell order. Tags mirror the Dart tab indices
  /// so `didSelect(item.tag)` and `setTab(index)` stay consistent.
  private func configureTabBar() {
    tabBar.items = Self.makeItems()
    tabBar.selectedItem = tabBar.items?.first
    tabBar.delegate = self
    applyTint(to: tabBar)
    hapticGenerator.prepare()
  }

  /// The tabs' tint, shared by the bare dock and the vertical bar's tabs.
  private func applyTint(to bar: UITabBar) {
    // Default appearance, deliberately: iOS 26 dresses a UITabBar in its own
    // Liquid Glass only while the appearance is untouched.
    bar.tintColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.949, green: 0.933, blue: 0.945, alpha: 1)
        : UIColor(red: 0.110, green: 0.102, blue: 0.118, alpha: 1)
    }
    bar.unselectedItemTintColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.596, green: 0.573, blue: 0.604, alpha: 1)
        : UIColor(red: 0.522, green: 0.494, blue: 0.525, alpha: 1)
    }
  }

  /// A fresh set each call: a `UITabBarItem` belongs to one bar.
  static func makeItems() -> [UITabBarItem] {
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

    return [home, mixes, library, you]
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
      // Measured from the safe area's sides, not the window's: a system bar
      // can stand on one side edge for a whole pose (iPhone Duo), and the
      // dock then centres under the content beside it, as Flutter's pages do.
      tabBar.leadingAnchor.constraint(
        equalTo: hostView.safeAreaLayoutGuide.leadingAnchor, constant: 22),
      tabBar.trailingAnchor.constraint(
        equalTo: hostView.safeAreaLayoutGuide.trailingAnchor, constant: -22),
      tabBar.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

      // The board's floating pill: 22 pt side margins, 52 pt tall, 7 pt above
      // the bar. It stays put when the bar minimises.
      miniPlayer.leadingAnchor.constraint(
        equalTo: hostView.safeAreaLayoutGuide.leadingAnchor, constant: 22),
      miniPlayer.trailingAnchor.constraint(
        equalTo: hostView.safeAreaLayoutGuide.trailingAnchor, constant: -22),
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
    setVerticalTabsWanted(false)
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
    setVerticalTabsWanted(true)
    let showBare = !isVertical
    tabBar.isHidden = !showBare
    if isMiniWanted { miniPlayer.isHidden = false }
    animate {
      self.tabBar.alpha = showBare ? 1 : 0
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
    if #available(iOS 27.1, *), let host = verticalHost as? ShellTabController {
      host.tabBar.overrideUserInterfaceStyle = style
    }
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
        if #available(iOS 27.1, *), let host = self.verticalHost as? ShellTabController {
          host.select(index: index)
        }
        result(nil)

      case "isVerticalBar":
        result(self.isVertical)

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
      playing: args["playing"] as? Bool ?? false,
      unavailable: args["unavailable"] as? Bool ?? false
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
    hapticGenerator.selectionChanged()
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
  ///
  /// Only while the pill is on screen: UIKit's own hidden/alpha check lives
  /// in `super.hitTest`, so without this guard a hidden pill kept taking taps
  /// for its two buttons out of the Flutter content under it (2026-11-20,
  /// found when a toast's action at that spot did nothing).
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    for button in [nextButton, playPauseButton] {
      let target = button.convert(button.bounds, to: self)
        .insetBy(dx: -4, dy: -4)
      if target.contains(point) { return button }
    }
    return super.hitTest(point, with: event)
  }

  /// The line the pill says where the artist goes when Apple Music will not
  /// play the track here. `MiniPlayerState.unavailableLine` says the same.
  static let unavailableHint = "Not available in your region"

  func apply(
    title: String,
    artist: String,
    artworkUrl: String?,
    playing: Bool,
    unavailable: Bool
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

    // Apple Music refused this track: play/pause is dead and says why, while
    // Next — the way out — stays live (board → Dock; plan task 6.2).
    playPauseButton.isEnabled = !unavailable
    playPauseButton.alpha = unavailable ? 0.35 : 1
    playPauseButton.accessibilityHint = unavailable ? Self.unavailableHint : nil
    nextButton.isEnabled = true

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
    let params = args as? [String: Any]
    let isDark = params?["isDark"] as? Bool
    let cornerRadius = (params?["cornerRadius"] as? NSNumber)?.doubleValue ?? 0
    // The header buttons are true circles; the continuous curve would draw
    // them as squircles at half the side.
    let circle = params?["circle"] as? Bool ?? false
    return LiquidGlassPlatformView(
      frame: frame, isDark: isDark, cornerRadius: cornerRadius, circle: circle)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class LiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let effectView: UIVisualEffectView

  init(frame: CGRect, isDark: Bool?, cornerRadius: Double, circle: Bool = false) {
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
    // Flutter's clip does not reach a platform view, so the glass rounds
    // itself to the radius the widget was given (the Home panel's 32 pt).
    if cornerRadius > 0 {
      effectView.layer.cornerRadius = CGFloat(cornerRadius)
      effectView.layer.cornerCurve = circle ? .circular : .continuous
      effectView.clipsToBounds = true
    }
    super.init()
  }

  func view() -> UIView {
    return effectView
  }
}

// MARK: - Native switch platform view

/// A real `UISwitch` for Flutter (viewType `mixtape/native_switch`), so the
/// You tab's toggles get iOS 26's Liquid Glass thumb — the compact track and
/// the lens that swells under a finger — which no Flutter-drawn switch has.
///
/// Each view talks over its own channel, `mixtape/native_switch_<id>`:
/// Flutter sends `setValue` / `setEnabled`, the switch sends `valueChanged`.
/// The switch is centred in a view larger than itself, because the glass
/// thumb grows past the track while it is held.
final class NativeSwitchViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let params = args as? [String: Any]
    return NativeSwitchPlatformView(
      frame: frame,
      channel: FlutterMethodChannel(
        name: "mixtape/native_switch_\(viewId)",
        binaryMessenger: messenger
      ),
      value: params?["value"] as? Bool ?? false,
      enabled: params?["enabled"] as? Bool ?? true,
      isDark: params?["isDark"] as? Bool
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class NativeSwitchPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let toggle = UISwitch()
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    channel: FlutterMethodChannel,
    value: Bool,
    enabled: Bool,
    isDark: Bool?
  ) {
    container = UIView(frame: frame)
    self.channel = channel
    super.init()

    container.backgroundColor = .clear
    switch isDark {
    case .some(true): container.overrideUserInterfaceStyle = .dark
    case .some(false): container.overrideUserInterfaceStyle = .light
    case .none: container.overrideUserInterfaceStyle = .unspecified
    }

    toggle.isOn = value
    toggle.isEnabled = enabled
    toggle.translatesAutoresizingMaskIntoConstraints = false
    toggle.addTarget(self, action: #selector(changed), for: .valueChanged)
    container.addSubview(toggle)
    NSLayoutConstraint.activate([
      toggle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "setValue":
        self.toggle.setOn(
          args?["value"] as? Bool ?? self.toggle.isOn,
          animated: args?["animated"] as? Bool ?? true
        )
        result(nil)
      case "setEnabled":
        self.toggle.isEnabled = args?["enabled"] as? Bool ?? true
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return container
  }

  @objc private func changed() {
    channel.invokeMethod("valueChanged", arguments: ["value": toggle.isOn])
  }
}

// MARK: - Native segmented control platform view

/// A real `UISegmentedControl` for Flutter (viewType `mixtape/native_segmented`),
/// so the Mixes toggle gets iOS 26's Liquid Glass thumb — the lens that swells
/// and slides under a finger — which no Flutter-drawn toggle has.
///
/// Each view talks over its own channel, `mixtape/native_segmented_<id>`:
/// Flutter sends `setSelected`, the control sends `valueChanged`. The control
/// is inset inside its view, because the glass thumb grows past the track
/// while it is held and a platform view clips to its frame.
final class NativeSegmentedViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let params = args as? [String: Any]
    return NativeSegmentedPlatformView(
      frame: frame,
      channel: FlutterMethodChannel(
        name: "mixtape/native_segmented_\(viewId)",
        binaryMessenger: messenger
      ),
      labels: params?["labels"] as? [String] ?? [],
      selected: (params?["selected"] as? NSNumber)?.intValue ?? 0,
      isDark: params?["isDark"] as? Bool,
      fontSize: (params?["fontSize"] as? NSNumber)?.doubleValue ?? 13,
      insetX: (params?["insetX"] as? NSNumber)?.doubleValue ?? 0,
      insetY: (params?["insetY"] as? NSNumber)?.doubleValue ?? 0,
      glass: params?["glass"] as? Bool ?? false,
      cornerRadius: (params?["cornerRadius"] as? NSNumber)?.doubleValue ?? 0
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class NativeSegmentedPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let control: UISegmentedControl
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    channel: FlutterMethodChannel,
    labels: [String],
    selected: Int,
    isDark: Bool?,
    fontSize: Double,
    insetX: Double,
    insetY: Double,
    glass: Bool,
    cornerRadius: Double
  ) {
    container = UIView(frame: frame)
    control = UISegmentedControl(items: labels)
    self.channel = channel
    super.init()

    container.backgroundColor = .clear
    switch isDark {
    case .some(true): container.overrideUserInterfaceStyle = .dark
    case .some(false): container.overrideUserInterfaceStyle = .light
    case .none: container.overrideUserInterfaceStyle = .unspecified
    }

    control.selectedSegmentIndex = selected
    control.apportionsSegmentWidthsByContent = false
    let size = CGFloat(fontSize)
    control.setTitleTextAttributes(
      [.font: UIFont.systemFont(ofSize: size, weight: .medium)], for: .normal)
    control.setTitleTextAttributes(
      [.font: UIFont.systemFont(ofSize: size, weight: .semibold)], for: .selected)
    control.translatesAutoresizingMaskIntoConstraints = false
    control.addTarget(self, action: #selector(changed), for: .valueChanged)

    // On a glass capsule, as the dock is: the glass sits behind the control,
    // the same shape, so the control's translucent track reads as glass. The
    // control is a sibling, not inside the glass, so its thumb can still swell
    // past the capsule while it is held.
    let inset = (x: CGFloat(insetX), y: CGFloat(insetY))
    if glass, #available(iOS 26, *) {
      let glassView = UIVisualEffectView(effect: UIGlassEffect())
      glassView.translatesAutoresizingMaskIntoConstraints = false
      glassView.layer.cornerRadius = CGFloat(cornerRadius)
      glassView.layer.cornerCurve = .continuous
      glassView.clipsToBounds = true
      container.addSubview(glassView)
      NSLayoutConstraint.activate([
        glassView.leadingAnchor.constraint(
          equalTo: container.leadingAnchor, constant: inset.x),
        glassView.trailingAnchor.constraint(
          equalTo: container.trailingAnchor, constant: -inset.x),
        glassView.topAnchor.constraint(
          equalTo: container.topAnchor, constant: inset.y),
        glassView.bottomAnchor.constraint(
          equalTo: container.bottomAnchor, constant: -inset.y),
      ])
      control.backgroundColor = .clear
    }
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(
        equalTo: container.leadingAnchor, constant: inset.x),
      control.trailingAnchor.constraint(
        equalTo: container.trailingAnchor, constant: -inset.x),
      control.topAnchor.constraint(
        equalTo: container.topAnchor, constant: inset.y),
      control.bottomAnchor.constraint(
        equalTo: container.bottomAnchor, constant: -inset.y),
    ])

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "setSelected":
        let index = (args?["index"] as? NSNumber)?.intValue ?? 0
        if index >= 0 && index < self.control.numberOfSegments {
          self.control.selectedSegmentIndex = index
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return container
  }

  @objc private func changed() {
    channel.invokeMethod(
      "valueChanged", arguments: ["index": control.selectedSegmentIndex])
  }
}

// MARK: - Vertical bar host (iOS 27.1+)

/// The window's root on iOS 27.1 and later, so the system can stand the tabs
/// in the vertical bar: the column the iPhone Duo keeps its status items in
/// whenever one of its side edges holds them (closed, or open in landscape).
/// Only a `UITabBarController`'s own tab bar is placed there, and only in
/// the system's Liquid Glass; a bare `UITabBar` never is.
///
/// Flutter is ONE view controller, so the four tabs share it: each tab's
/// view controller is an empty slot, and the Flutter controller moves into
/// whichever slot is selected. Slots forward no appearance calls, so a move
/// never tells Flutter it disappeared (which would pause the app's
/// lifecycle); the one real appearance is forwarded by hand when Flutter is
/// first embedded.
///
/// Wherever iOS uses no vertical bar (every pose of every other iPhone, the
/// Duo open in portrait) this controller's tab bar stays hidden and
/// `ShellDock`'s bottom dock carries on exactly as before.
@available(iOS 27.1, *)
final class ShellTabController: UITabBarController, UITabBarControllerDelegate {
  private let flutter: UIViewController
  private var slots: [FlutterSlot] = []

  /// A tab chosen in the vertical bar, by its index.
  var onTabSelected: ((Int) -> Void)?

  /// The tabs moved into or out of the vertical bar.
  var onPlacementChanged: ((Bool) -> Void)?

  /// Flutter's own wish for the tabs (`show`/`hide` on `mixtape/shell`).
  private var tabsWanted = false

  init(flutter: UIViewController, items: [UITabBarItem]) {
    self.flutter = flutter
    super.init(nibName: nil, bundle: nil)
    slots = items.map { item in
      let slot = FlutterSlot()
      slot.tabBarItem = item
      return slot
    }
    setViewControllers(slots, animated: false)
    delegate = self
    tabBarMinimizeBehavior = .never
    registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
      (self: Self, _: UITraitCollection) in
      self.placementDidChange()
    }
    // UITabBarController loads its view inside `super.init`, before the slots
    // exist, so Flutter is embedded here rather than in `viewDidLoad`.
    embedFlutter(in: slots[0], firstTime: true)
    applyTabBarVisibility(animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Whether the system currently stands the tabs in the vertical bar.
  var isVertical: Bool { traitCollection.verticalBarEdge != .unspecified }

  /// Flutter asked for the tabs (`show`) or for none (`hide`).
  func setTabsWanted(_ wanted: Bool) {
    tabsWanted = wanted
    applyTabBarVisibility(animated: true)
  }

  /// Flutter switched tabs itself.
  func select(index: Int) {
    guard index >= 0, index < slots.count, index != selectedIndex else { return }
    selectedIndex = index
    embedFlutter(in: slots[index], firstTime: false)
  }

  private var lastVertical: Bool?

  /// Every layout pass, after the placement is re-read.
  var onLayout: (() -> Void)?

  // A belt to the trait registration's braces: a fold or a rotation always
  // lays the controller out again, so the placement is re-read here too, and
  // the bare dock re-derives its visibility. A `show()` from Flutter that
  // lands mid-unfold reads the old placement; this pass corrects it.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    placementDidChange()
    onLayout?()
  }

  private func placementDidChange() {
    let vertical = isVertical
    applyTabBarVisibility(animated: false)
    guard vertical != lastVertical else { return }
    lastVertical = vertical
    onPlacementChanged?(vertical)
  }

  /// Shown only in the vertical bar, and only while Flutter wants the tabs;
  /// at the bottom the bare dock does the job.
  private func applyTabBarVisibility(animated: Bool) {
    let hidden = !(tabsWanted && isVertical)
    guard isTabBarHidden != hidden else { return }
    setTabBarHidden(hidden, animated: animated && !UIAccessibility.isReduceMotionEnabled)
  }

  private func embedFlutter(in slot: FlutterSlot, firstTime: Bool) {
    guard flutter.parent !== slot else { return }
    if flutter.parent != nil {
      flutter.willMove(toParent: nil)
      flutter.view.removeFromSuperview()
      flutter.removeFromParent()
    }
    slot.addChild(flutter)
    flutter.view.frame = slot.view.bounds
    flutter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if firstTime { flutter.beginAppearanceTransition(true, animated: false) }
    slot.view.addSubview(flutter.view)
    if firstTime { flutter.endAppearanceTransition() }
    flutter.didMove(toParent: slot)
  }

  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelect viewController: UIViewController
  ) {
    guard let slot = viewController as? FlutterSlot,
      let index = slots.firstIndex(of: slot)
    else { return }
    embedFlutter(in: slot, firstTime: false)
    onTabSelected?(index)
  }

  // The status bar follows Flutter, wherever it sits.
  override var childForStatusBarStyle: UIViewController? { flutter }
  override var childForStatusBarHidden: UIViewController? { flutter }
}

/// One tab's view controller: an empty stage the shared Flutter controller
/// stands on while this tab is selected. It forwards no appearance calls (see
/// `ShellTabController`).
@available(iOS 27.1, *)
final class FlutterSlot: UIViewController {
  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
}
