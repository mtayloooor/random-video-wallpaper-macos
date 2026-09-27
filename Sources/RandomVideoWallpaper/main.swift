import AppKit
import AVFoundation
import Darwin
import QuartzCore

private let supportedExtensions: Set<String> = ["m4v", "mov", "mp4", "webm"]

private struct Options {
    var inputs: [String] = []
    var workingDirectory = FileManager.default.currentDirectoryPath
    var checkOnly = false
    var lowPowerMode = false
    var recursive = true
    var muted = true
    var onlyMainScreen = false
    var disabledDisplays: Set<String> = []
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var fadeDuration: TimeInterval = 1.2
    var levelOffset = 0
}

private enum VideoWallpaperError: Error, CustomStringConvertible {
    case badOption(String)
    case missingValue(String)
    case noVideos([String])

    var description: String {
        switch self {
        case .badOption(let option):
            return "Unknown option: \(option)"
        case .missingValue(let option):
            return "Missing value after \(option)"
        case .noVideos(let inputs):
            if inputs.isEmpty {
                return "No video files found in the current directory."
            }

            return "No video files found for: \(inputs.joined(separator: ", "))"
        }
    }
}

private enum DefaultsKeys {
    static let lastInputs = "lastInputs"
    static let disabledDisplays = "disabledDisplays"
}

private final class Playlist {
    let urls: [URL]
    private var lastURL: URL?

    init(urls: [URL]) {
        self.urls = urls
    }

    func nextURL() -> URL {
        guard urls.count > 1 else {
            lastURL = urls[0]
            return urls[0]
        }

        var candidate = urls.randomElement()!
        for _ in 0..<8 where candidate == lastURL {
            candidate = urls.randomElement()!
        }

        lastURL = candidate
        return candidate
    }
}

private extension NSScreen {
    /// Stable identifier that survives reconnects and restarts, unlike the display ID.
    var displayUUID: String? {
        guard let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class VideoSurface: NSView {
    private let playerLayers: [AVPlayerLayer]

    init(playerLayers: [AVPlayerLayer]) {
        self.playerLayers = playerLayers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayers.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}

private final class PlayerSlot {
    let player = AVPlayer()
    let playerLayer: AVPlayerLayer
    private var endObserver: NSObjectProtocol?

    init(gravity: AVLayerVideoGravity, muted: Bool) {
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        player.volume = muted ? 0 : 1

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = gravity
        playerLayer.opacity = 0
    }

    deinit {
        stopObserving()
    }

    func prepare(url: URL, onEnd: @escaping (PlayerSlot) -> Void) {
        stopObserving()
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            onEnd(self)
        }
        player.replaceCurrentItem(with: item)
        player.seek(to: .zero)
    }

    func stopObserving() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

private final class WallpaperPlayer {
    private let playlist: Playlist
    private let fadeDuration: TimeInterval
    private let slots: [PlayerSlot]
    private var activeIndex = 0
    private var isTransitioning = false

    var playerLayers: [AVPlayerLayer] {
        slots.map(\.playerLayer)
    }

    init(
        playlist: Playlist,
        muted: Bool,
        gravity: AVLayerVideoGravity,
        fadeDuration: TimeInterval
    ) {
        self.playlist = playlist
        self.fadeDuration = fadeDuration
        slots = [
            PlayerSlot(gravity: gravity, muted: muted),
            PlayerSlot(gravity: gravity, muted: muted)
        ]
    }

    func start() {
        let activeSlot = slots[activeIndex]
        prepare(slot: activeSlot, url: playlist.nextURL())
        setOpacity(activeSlot, 1)
        activeSlot.player.play()
        prepareInactiveSlot()
    }

    private func didFinish(slot: PlayerSlot) {
        guard slot === slots[activeIndex], !isTransitioning else {
            return
        }

        crossfadeToPreparedSlot()
    }

    private func prepareInactiveSlot() {
        let inactiveSlot = slots[1 - activeIndex]
        prepare(slot: inactiveSlot, url: playlist.nextURL())
        inactiveSlot.player.pause()
        setOpacity(inactiveSlot, 0)
    }

    private func prepare(slot: PlayerSlot, url: URL) {
        slot.prepare(url: url) { [weak self] finishedSlot in
            self?.didFinish(slot: finishedSlot)
        }
    }

    private func crossfadeToPreparedSlot() {
        let previousIndex = activeIndex
        let nextIndex = 1 - activeIndex
        let previousSlot = slots[previousIndex]
        let nextSlot = slots[nextIndex]

        isTransitioning = true
        activeIndex = nextIndex

        setOpacity(nextSlot, 0)
        nextSlot.player.seek(to: .zero)
        nextSlot.player.play()

        let duration = max(0.01, fadeDuration)
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak previousSlot] in
            guard let self, let previousSlot else {
                return
            }

            previousSlot.player.pause()
            previousSlot.stopObserving()
            previousSlot.player.replaceCurrentItem(with: nil)
            setOpacity(previousSlot, 0)
            isTransitioning = false
            prepareInactiveSlot()
        }
        previousSlot.playerLayer.opacity = 0
        nextSlot.playerLayer.opacity = 1
        CATransaction.commit()
    }

    private func setOpacity(_ slot: PlayerSlot, _ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.playerLayer.opacity = opacity
        CATransaction.commit()
    }
}

private final class WallpaperScene {
    private let window: WallpaperWindow
    private let wallpaperPlayer: WallpaperPlayer

    init(screen: NSScreen, playlist: Playlist, options: Options) {
        wallpaperPlayer = WallpaperPlayer(
            playlist: playlist,
            muted: options.muted,
            gravity: options.videoGravity,
            fadeDuration: options.fadeDuration
        )
        window = WallpaperWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + options.levelOffset
        )
        window.contentView = VideoSurface(playerLayers: wallpaperPlayer.playerLayers)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        wallpaperPlayer.start()
    }

    func orderFront() {
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }
}

private final class AppController: NSObject, NSApplicationDelegate {
    private var playlist: Playlist?
    private var options: Options
    private var scenes: [WallpaperScene] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    init(playlist: Playlist?, options: Options) {
        self.playlist = playlist
        self.options = options
        self.options.disabledDisplays = Set(
            UserDefaults.standard.stringArray(forKey: DefaultsKeys.disabledDisplays) ?? []
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        if playlist != nil {
            rebuildScenes()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.chooseMedia()
            }
        }

        observers.append(
            (
                NotificationCenter.default,
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.rebuildScenes()
                }
            )
        )

        observers.append(
            (
                NSWorkspace.shared.notificationCenter,
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.orderScenes()
                }
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers.forEach { center, observer in
            center.removeObserver(observer)
        }
        stopWallpaper()
    }

    private func rebuildScenes() {
        guard let playlist else {
            rebuildMenu()
            return
        }

        scenes.forEach { $0.close() }
        let screens = options.onlyMainScreen
            ? NSScreen.main.map { [$0] } ?? NSScreen.screens
            : enabledScreens()

        scenes = screens.map {
            WallpaperScene(screen: $0, playlist: playlist, options: options)
        }
        rebuildMenu()
    }

    /// Connected screens the user hasn't turned off, falling back to all screens so something always plays.
    private func enabledScreens() -> [NSScreen] {
        let enabled = NSScreen.screens.filter { screen in
            screen.displayUUID.map { !options.disabledDisplays.contains($0) } ?? true
        }
        return enabled.isEmpty ? NSScreen.screens : enabled
    }

    private func orderScenes() {
        scenes.forEach { $0.orderFront() }
    }

    private func stopWallpaper() {
        scenes.forEach { $0.close() }
        scenes.removeAll()
        playlist = nil
        rebuildMenu()
    }

    private func installStatusItem() {
        statusMenu.autoenablesItems = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "play.rectangle.on.rectangle",
                accessibilityDescription: "Random Video Wallpaper"
            )
            button.title = button.image == nil ? "RVW" : ""
        }
        statusItem?.menu = statusMenu
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let statusTitle: String
        if let playlist {
            statusTitle = "Playing \(playlist.urls.count) video\(playlist.urls.count == 1 ? "" : "s")"
        } else {
            statusTitle = "Stopped"
        }

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenu.addItem(status)
        statusMenu.addItem(.separator())

        statusMenu.addItem(menuItem("Choose Videos or Folder...", #selector(chooseMedia), "o"))

        let startLast = menuItem("Start Last Selection", #selector(startLastSelection), "")
        startLast.isEnabled = UserDefaults.standard.stringArray(forKey: DefaultsKeys.lastInputs)?.isEmpty == false
        statusMenu.addItem(startLast)

        let stop = menuItem("Stop Wallpaper", #selector(stopWallpaperFromMenu), "")
        stop.isEnabled = playlist != nil
        statusMenu.addItem(stop)
        statusMenu.addItem(.separator())

        let lowPower = menuItem("Low Power Mode", #selector(toggleLowPowerMode), "")
        lowPower.state = options.lowPowerMode ? .on : .off
        statusMenu.addItem(lowPower)

        let onlyMain = menuItem("Main Display Only", #selector(toggleOnlyMainScreen), "")
        onlyMain.state = options.onlyMainScreen ? .on : .off
        statusMenu.addItem(onlyMain)

        if !options.onlyMainScreen {
            let displays = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
            displays.submenu = displaysMenu()
            statusMenu.addItem(displays)
        }

        let fit = menuItem("Fit Instead of Fill", #selector(toggleFitMode), "")
        fit.state = options.videoGravity == .resizeAspect ? .on : .off
        statusMenu.addItem(fit)

        let sound = menuItem("Sound", #selector(toggleSound), "")
        sound.state = options.muted ? .off : .on
        statusMenu.addItem(sound)
        statusMenu.addItem(.separator())

        statusMenu.addItem(menuItem("Quit", #selector(quit), "q"))
    }

    private func displaysMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let enabled = enabledScreens()
        let enabledCount = enabled.count

        for screen in NSScreen.screens {
            guard let displayUUID = screen.displayUUID else {
                continue
            }

            let item = menuItem(screen.localizedName, #selector(toggleDisplay(_:)), "")
            item.representedObject = displayUUID
            let isEnabled = enabled.contains(screen)
            item.state = isEnabled ? .on : .off
            // Keep at least one display playing.
            item.isEnabled = !(isEnabled && enabledCount <= 1)
            menu.addItem(item)
        }

        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, _ keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func start(inputs: [String]) {
        var nextOptions = options
        nextOptions.inputs = inputs
        nextOptions = applyLowPowerDefaults(to: nextOptions)

        do {
            let nextPlaylist = try resolvePlaylist(options: nextOptions)
            UserDefaults.standard.set(inputs, forKey: DefaultsKeys.lastInputs)
            options = nextOptions
            playlist = nextPlaylist
            rebuildScenes()
        } catch {
            showError(error)
        }
    }

    @objc private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = "Choose videos or a folder"
        panel.message = "Choose one or more videos or folders to use as the wallpaper playlist."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else {
            rebuildMenu()
            return
        }

        start(inputs: panel.urls.map(\.path))
    }

    @objc private func startLastSelection() {
        guard let inputs = UserDefaults.standard.stringArray(forKey: DefaultsKeys.lastInputs),
              !inputs.isEmpty else {
            chooseMedia()
            return
        }

        start(inputs: inputs)
    }

    @objc private func stopWallpaperFromMenu() {
        stopWallpaper()
    }

    @objc private func toggleLowPowerMode() {
        options.lowPowerMode.toggle()
        options = applyLowPowerDefaults(to: options)
        rebuildScenes()
        rebuildMenu()
    }

    @objc private func toggleOnlyMainScreen() {
        options.onlyMainScreen.toggle()
        rebuildScenes()
        rebuildMenu()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let displayUUID = sender.representedObject as? String else {
            return
        }

        if sender.state == .on {
            // Displays shown as on must not stay in the disabled set (e.g. after the fallback kicks in).
            options.disabledDisplays.subtract(enabledScreens().compactMap(\.displayUUID))
            options.disabledDisplays.insert(displayUUID)
        } else {
            options.disabledDisplays.remove(displayUUID)
        }
        UserDefaults.standard.set(Array(options.disabledDisplays).sorted(), forKey: DefaultsKeys.disabledDisplays)
        rebuildScenes()
        rebuildMenu()
    }

    @objc private func toggleFitMode() {
        options.videoGravity = options.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
        rebuildScenes()
        rebuildMenu()
    }

    @objc private func toggleSound() {
        options.muted.toggle()
        rebuildScenes()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not start wallpaper"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        rebuildMenu()
    }
}

private func printUsage() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print(
        """
        Usage:
          \(executable) [options] <video-or-folder> [more videos/folders...]

        Examples:
          \(executable) ~/Movies/wallpapers
          \(executable) ~/Movies/wallpapers/vending-stigmata-loop-*.mp4

        Options:
          --fit             Letterbox instead of cropping to fill the screen.
          --fill            Crop to fill the screen. This is the default.
          --fade SECONDS    Crossfade duration. Default is 1.2.
          --low-power       Prefer one display and shorter fades.
          --no-recursive    Do not scan subfolders.
          --only-main       Use only the main display.
          --sound           Keep video audio on. Default is muted.
          --level-offset N  Raise/lower the desktop window level if needed.
          --check           Check inputs and exit without starting the wallpaper.
          --help            Show this help.
        """
    )
}

private func parseOptions(arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let arg = arguments[index]

        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--fit":
            options.videoGravity = .resizeAspect
        case "--fill":
            options.videoGravity = .resizeAspectFill
        case "--fade":
            index += 1
            guard index < arguments.count else {
                throw VideoWallpaperError.missingValue(arg)
            }
            guard let value = Double(arguments[index]), value >= 0 else {
                throw VideoWallpaperError.badOption("--fade \(arguments[index])")
            }
            options.fadeDuration = value
        case "--low-power":
            options.lowPowerMode = true
        case "--no-recursive":
            options.recursive = false
        case "--only-main":
            options.onlyMainScreen = true
        case "--sound":
            options.muted = false
        case "--check":
            options.checkOnly = true
        case "--cwd":
            index += 1
            guard index < arguments.count else {
                throw VideoWallpaperError.missingValue(arg)
            }
            options.workingDirectory = arguments[index]
        case "--level-offset":
            index += 1
            guard index < arguments.count else {
                throw VideoWallpaperError.missingValue(arg)
            }
            guard let value = Int(arguments[index]) else {
                throw VideoWallpaperError.badOption("--level-offset \(arguments[index])")
            }
            options.levelOffset = value
        case "--":
            options.inputs.append(contentsOf: arguments[(index + 1)...])
            return options
        default:
            if arg.hasPrefix("-") {
                throw VideoWallpaperError.badOption(arg)
            }
            options.inputs.append(arg)
        }

        index += 1
    }

    return options
}

private func applyLowPowerDefaults(to options: Options) -> Options {
    var adjusted = options
    if adjusted.lowPowerMode {
        adjusted.onlyMainScreen = true
        adjusted.fadeDuration = min(adjusted.fadeDuration, 0.5)
    }
    return adjusted
}

private func normalizedInput(_ input: String) -> String {
    input
        .replacingOccurrences(of: "＊", with: "*")
        .replacingOccurrences(of: "〜", with: "~")
}

private func containsGlobCharacters(_ value: String) -> Bool {
    value.contains("*") || value.contains("?") || value.contains("[")
}

private func globMatches(for pattern: String) -> [String] {
    var result = glob_t()
    defer { globfree(&result) }

    let rc = glob(pattern, GLOB_TILDE, nil, &result)
    guard rc == 0, let pathv = result.gl_pathv else {
        return []
    }

    return (0..<Int(result.gl_matchc)).compactMap { index in
        pathv[index].map { String(cString: $0) }
    }
}

private func resolvedPath(for input: String, workingDirectory: String) -> String {
    let normalized = normalizedInput(input)
    let expanded = (normalized as NSString).expandingTildeInPath

    if expanded.hasPrefix("/") || expanded.hasPrefix("~") {
        return expanded
    }

    return URL(fileURLWithPath: workingDirectory)
        .appendingPathComponent(expanded)
        .standardizedFileURL
        .path
}

private func isSupportedVideo(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
}

private func addVideoURL(_ url: URL, to output: inout Set<URL>) {
    if isSupportedVideo(url) {
        output.insert(url.standardizedFileURL)
    }
}

private func collectVideos(from input: String, recursive: Bool, workingDirectory: String, output: inout Set<URL>) {
    let expanded = resolvedPath(for: input, workingDirectory: workingDirectory)
    let paths = containsGlobCharacters(expanded) ? globMatches(for: expanded) : [expanded]
    let fileManager = FileManager.default

    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            continue
        }

        if isDirectory.boolValue {
            if recursive {
                let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }

                for case let childURL as URL in enumerator {
                    addVideoURL(childURL, to: &output)
                }
            } else {
                let children = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                children.forEach { addVideoURL($0, to: &output) }
            }
        } else {
            addVideoURL(url, to: &output)
        }
    }
}

private func resolvePlaylist(options: Options) throws -> Playlist {
    let inputs = options.inputs.isEmpty ? [options.workingDirectory] : options.inputs
    var urls = Set<URL>()

    for input in inputs {
        collectVideos(
            from: input,
            recursive: options.recursive,
            workingDirectory: options.workingDirectory,
            output: &urls
        )
    }

    let sorted = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    guard !sorted.isEmpty else {
        throw VideoWallpaperError.noVideos(options.inputs)
    }

    return Playlist(urls: sorted)
}

private var retainedController: AppController?

do {
    let options = applyLowPowerDefaults(
        to: try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    )
    let shouldResolvePlaylist = options.checkOnly || !options.inputs.isEmpty
    let playlist = try shouldResolvePlaylist ? resolvePlaylist(options: options) : nil
    if options.checkOnly {
        print("RandomVideoWallpaper: found \(playlist?.urls.count ?? 0) video(s).")
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    retainedController = AppController(playlist: playlist, options: options)
    app.delegate = retainedController

    if let playlist {
        print("RandomVideoWallpaper: playing \(playlist.urls.count) video(s).")
        print("RandomVideoWallpaper: press Ctrl-C or run scripts/stop-video-wallpaper to stop.")
    } else {
        print("RandomVideoWallpaper: menu bar app started.")
    }
    app.run()
} catch {
    fputs("random-video-wallpaper: \(error)\n", stderr)
    fputs("Run with --help for usage.\n", stderr)
    exit(1)
}
