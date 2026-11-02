import Foundation
import SystemConfiguration

/// Core logic. Fail closed: the block is active until a geo lookup confirms a safe country.
final class Daemon {
    private let queue = DispatchQueue(label: "fence.daemon")
    private let log: Logger
    private let blocker: Blocker
    private let watcher: NetworkWatcher
    private var server: SocketServer?
    private var periodic: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []

    private var state = DaemonState()
    /// Copy of `state` for the socket. The socket reads it without the main queue.
    private let snapshotLock = NSLock()
    private var snapshot = DaemonState()
    private let watchdogQueue = DispatchQueue(label: "fence.watchdog")
    private var watchdogTimer: DispatchSourceTimer?
    /// Pings without an answer. Only the watchdog queue touches it.
    private var missedPings = 0
    private var config = FenceConfigFile.defaults
    private var configDate: Date?
    private var configTimer: DispatchSourceTimer?
    private var lastSignature = ""
    /// Each scheduled check gets a token. A newer token cancels older checks and their results.
    private var checkToken = 0
    private let dryRun: Bool

    init(dryRun: Bool) {
        self.dryRun = dryRun
        log = Logger(path: FencePaths.logFile)
        blocker = Blocker(log: log, dryRun: dryRun)
        watcher = NetworkWatcher(queue: queue)
    }

    func run() -> Never {
        log.info("Fence daemon \(FenceConfig.version) start\(dryRun ? " (dry run)" : "")")
        try? FileManager.default.createDirectory(atPath: FencePaths.supportDir, withIntermediateDirectories: true)
        restoreManualFlag()

        queue.sync {
            loadConfig(reason: "startup")
            state.status = state.manualBlock ? .manual : .checking
            applyBlock(reason: "startup")
            publish()
        }
        startConfigWatcher()
        startWatchdog()

        watcher.onChange = { [weak self] signature in self?.handleNetwork(signature) }
        watcher.start()
        startPeriodicTimer()

        let server = SocketServer(path: FencePaths.socketPath, log: log,
                                  authorize: { uid in Daemon.authorize(uid: uid) }) { [weak self] command in
            self?.handleCommand(command) ?? DaemonState()
        }
        do {
            try server.start()
        } catch {
            log.error("socket: \(error)")
        }
        self.server = server

        installSignalHandlers()
        dispatchMain()
    }

    // MARK: Network

    private func handleNetwork(_ signature: String) {
        guard signature != lastSignature else { return }
        let first = lastSignature.isEmpty
        lastSignature = signature
        state.networkSignature = signature
        log.info("network \(first ? "initial" : "changed"): \(signature)")
        if !first {
            applyBlock(reason: "network changed")
        }
        state.status = state.manualBlock ? .manual : .checking
        publish()
        scheduleCheck(after: FenceConfig.settleDelay, reason: first ? "startup" : "network changed")
    }

    // MARK: Block

    /// Set the block and record a hosts file failure in the state.
    private func applyBlock(reason: String) {
        state.blockError = blocker.apply(hosts: config.enabledHosts, pfHosts: config.enabledPFHosts, reason: reason)
    }

    private func removeBlock(reason: String) {
        state.blockError = blocker.remove(reason: reason)
    }

    // MARK: Access

    /// Root, the daemon's own user and the user at the console may talk to the daemon.
    static func authorize(uid: uid_t) -> Bool {
        if uid == 0 || uid == getuid() { return true }
        var consoleUID = uid_t.max
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil else { return false }
        return consoleUID == uid
    }

    // MARK: Geo check

    private func scheduleCheck(after delay: TimeInterval, reason: String) {
        checkToken += 1
        let token = checkToken
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, token == self.checkToken else { return }
            self.runCheck(token: token, reason: reason)
        }
    }

    private func runCheck(token: Int, reason: String) {
        log.info("geo check: \(reason)")
        // A change from blocked to open needs two providers that agree. Staying open needs one.
        let confirmOpen = state.status != .open
        let blocked = Set(config.blockedCountries)
        DispatchQueue.global().async { [weak self] in
            let verdict = GeoLookup.check(blockedCountries: blocked, confirmOpen: confirmOpen)
            self?.queue.async {
                guard let self = self else { return }
                guard token == self.checkToken else {
                    self.log.info("geo check: result discarded, a newer check is pending")
                    return
                }
                self.applyGeo(verdict)
            }
        }
    }

    private func applyGeo(_ verdict: GeoVerdict) {
        state.lastCheck = Date()
        switch verdict {
        case .failed(let message):
            state.lastError = message
            log.warn("geo check failed, block stays: \(message)")
            applyBlock(reason: "geo check failed")
            state.status = state.manualBlock ? .manual : .checking
            publish()
            scheduleCheck(after: FenceConfig.retryDelay, reason: "retry")

        case .unconfirmed(let geo, let message):
            record(geo)
            state.lastError = "open needs a second provider: \(message)"
            log.warn("\(summary(geo)): open, but no second provider confirmed it, block stays: \(message)")
            applyBlock(reason: "unconfirmed")
            state.status = state.manualBlock ? .manual : .checking
            publish()
            scheduleCheck(after: FenceConfig.blockedRecheckInterval, reason: "confirmation retry")

        case .blocked(let geo):
            record(geo)
            state.lastError = nil
            if state.status != .blocked { log.info("\(summary(geo)): BLOCKED") }
            applyBlock(reason: "country \(geo.country)")
            state.status = .blocked
            publish()
            scheduleCheck(after: FenceConfig.blockedRecheckInterval, reason: "blocked recheck")

        case .open(let geo, let confirmedBy):
            record(geo)
            state.lastError = nil
            if state.manualBlock {
                if state.status != .manual { log.info("\(summary(geo)): manual block active") }
                applyBlock(reason: "manual block")
                state.status = .manual
            } else {
                if state.status != .open {
                    let by = confirmedBy.map { ", \($0.country) via \($0.source) agrees" } ?? ""
                    log.info("\(summary(geo))\(by): OPEN")
                }
                removeBlock(reason: "country \(geo.country)")
                state.status = .open
                // Keep the pf address list fresh for the next block. Only the pf hosts need it.
                blocker.refreshIPs(hosts: config.enabledPFHosts)
            }
            publish()
        }
    }

    private func record(_ geo: GeoResult) {
        state.country = geo.country
        state.ip = geo.ip
        state.geoSource = geo.source
    }

    private func summary(_ geo: GeoResult) -> String {
        "\(geo.country) \(geo.ip) via \(geo.source)"
    }

    private func startPeriodicTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + FenceConfig.periodicCheckInterval, repeating: FenceConfig.periodicCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.scheduleCheck(after: 0, reason: "periodic")
        }
        timer.resume()
        periodic = timer
    }

    // MARK: Watchdog

    /// Ping the main queue. When the queue does not answer for a long time, exit.
    /// The block stays in place and launchd starts a fresh daemon.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + FenceConfig.watchdogInterval, repeating: FenceConfig.watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.missedPings += 1
            if self.missedPings >= FenceConfig.watchdogMissedPings {
                let seconds = Int(FenceConfig.watchdogInterval) * FenceConfig.watchdogMissedPings
                self.log.error("watchdog: the main queue did not answer for \(seconds) s. Exit, launchd restarts the daemon.")
                self.log.flush()
                exit(3)
            }
            self.queue.async {
                self.watchdogQueue.async { self.missedPings = 0 }
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: Config

    private func loadConfig(reason: String) {
        let loaded = ConfigStore.load()
        configDate = ConfigStore.modificationDate()
        guard loaded != config || reason == "startup" else { return }
        config = loaded
        state.services = config.services.map { ServiceState(id: $0.id, name: $0.name, enabled: $0.enabled) }
        let enabled = config.services.filter { $0.enabled }.map { $0.id }.joined(separator: ", ")
        log.info("config loaded (\(reason)): countries \(config.blockedCountries.joined(separator: ",")), services \(enabled)")
    }

    /// Re-apply the current block with the current host list. Used after a config change.
    private func reapplyIfBlocked(reason: String) {
        if state.isBlocked {
            applyBlock(reason: reason)
        } else {
            blocker.refreshIPs(hosts: config.enabledPFHosts)
        }
    }

    /// Poll the config file date every 5 seconds. A hand edit then takes effect without a restart.
    private func startConfigWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let date = ConfigStore.modificationDate()
            guard date != self.configDate else { return }
            let before = self.config
            self.loadConfig(reason: "file changed")
            if self.config != before {
                self.reapplyIfBlocked(reason: "config file changed")
                self.publish()
            }
        }
        timer.resume()
        configTimer = timer
    }

    private func setService(_ id: String, enabled: Bool) {
        guard let index = config.services.firstIndex(where: { $0.id == id }) else {
            log.warn("service '\(id)' is not in the config")
            return
        }
        guard config.services[index].enabled != enabled else { return }
        config.services[index].enabled = enabled
        ConfigStore.save(config)
        configDate = ConfigStore.modificationDate()
        state.services = config.services.map { ServiceState(id: $0.id, name: $0.name, enabled: $0.enabled) }
        log.info("service \(id) \(enabled ? "ON" : "OFF")")
        reapplyIfBlocked(reason: "service \(id) \(enabled ? "on" : "off")")
        publish()
    }

    // MARK: Commands

    /// Runs on the socket thread. `status` reads the snapshot and never waits for the main queue.
    /// Other commands wait for the main queue for a short time. Then the reply carries the last state.
    private func handleCommand(_ command: FenceCommand) -> DaemonState {
        if case .status = command { return currentSnapshot() }
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.execute(command)
            done.signal()
        }
        if done.wait(timeout: .now() + FenceConfig.commandWait) == .timedOut {
            log.warn("socket: command '\(command.line)' waits, the main queue is busy")
            var reply = currentSnapshot()
            reply.lastError = "the daemon is busy, the command waits"
            return reply
        }
        return currentSnapshot()
    }

    private func currentSnapshot() -> DaemonState {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    /// Runs on the main queue.
    private func execute(_ command: FenceCommand) {
        switch command {
        case .status:
            break
        case .reload:
            let before = config
            loadConfig(reason: "reload command")
            if config != before {
                reapplyIfBlocked(reason: "config reloaded")
                publish()
            }
        case .serviceOn(let id):
            setService(id, enabled: true)
        case .serviceOff(let id):
            setService(id, enabled: false)
        case .manualOn:
            state.manualBlock = true
            applyBlock(reason: "manual block on")
            if state.status != .blocked { state.status = .manual }
            log.info("manual block ON")
            publish()
        case .manualOff:
            state.manualBlock = false
            log.info("manual block OFF")
            if state.status == .manual {
                state.status = .checking
                scheduleCheck(after: 0, reason: "manual block off")
            }
            publish()
        case .recheck:
            scheduleCheck(after: 0, reason: "manual recheck")
        }
    }

    // MARK: State file

    private func publish() {
        state.updatedAt = Date()
        snapshotLock.lock()
        snapshot = state
        snapshotLock.unlock()
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: FencePaths.stateFile), options: .atomic)
        // The file holds the public IP. The app gets the state over the socket, not from here.
        chmod(FencePaths.stateFile, 0o600)
    }

    private func restoreManualFlag() {
        guard let data = FileManager.default.contents(atPath: FencePaths.stateFile),
              let saved = try? JSONCoding.decoder.decode(DaemonState.self, from: data) else { return }
        state.manualBlock = saved.manualBlock
        if saved.manualBlock { log.info("manual block restored from the state file") }
    }

    // MARK: Signals

    private func installSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                self?.log.info("signal \(sig): exit. The block stays as it is (fail closed).")
                self?.log.flush()
                exit(0)
            }
            source.resume()
            signals.append(source)
        }
    }
}
