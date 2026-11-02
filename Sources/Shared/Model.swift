import Foundation

/// Protection status that the daemon reports to the GUI.
enum ProtectionStatus: String, Codable {
    /// The public IP is outside the blocked countries. Access to Anthropic is open.
    case open
    /// The network changed. The daemon holds the block until it confirms the country.
    case checking
    /// The public IP is in a blocked country. The block is active.
    case blocked
    /// The user set a manual block. The block is active.
    case manual
}

/// State that the daemon publishes over the socket and in the state file.
struct DaemonState: Codable {
    var status: ProtectionStatus = .checking
    var country: String?
    var ip: String?
    var geoSource: String?
    var lastCheck: Date?
    var lastError: String?
    var manualBlock: Bool = false
    /// Set when the hosts file could not be written. The block is then weaker than the status says.
    var blockError: String?
    var services: [ServiceState] = []
    var networkSignature: String = ""
    var daemonVersion: String = FenceConfig.version
    var updatedAt: Date = Date()

    var isBlocked: Bool { status != .open }
}

/// One service as the daemon reports it to the GUI.
struct ServiceState: Codable {
    var id: String
    var name: String
    var enabled: Bool
}

/// Commands that the GUI or the CLI sends to the daemon. Wire format: one line of text.
enum FenceCommand: Equatable {
    case status
    case manualOn
    case manualOff
    case recheck
    case reload
    case serviceOn(String)
    case serviceOff(String)

    var line: String {
        switch self {
        case .status: return "status"
        case .manualOn: return "manual-on"
        case .manualOff: return "manual-off"
        case .recheck: return "recheck"
        case .reload: return "reload"
        case .serviceOn(let id): return "service-on \(id)"
        case .serviceOff(let id): return "service-off \(id)"
        }
    }

    init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return nil }
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch head {
        case "status": self = .status
        case "manual-on": self = .manualOn
        case "manual-off": self = .manualOff
        case "recheck": self = .recheck
        case "reload": self = .reload
        case "service-on" where Self.isValidID(arg): self = .serviceOn(arg)
        case "service-off" where Self.isValidID(arg): self = .serviceOff(arg)
        default: return nil
        }
    }

    /// A service id: letters, digits, dash, underscore. Nothing else reaches the log or the config.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

enum Hostname {
    /// RFC 1123 host name: labels of letters, digits and dashes, joined by dots, 253 chars at most.
    static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, host.allSatisfy({ $0.isASCII }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

/// One blocked service in config.json.
struct ServiceConfig: Codable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var hosts: [String]
    /// Also drop packets to the resolved addresses with pf. Keep this off for hosts behind a
    /// shared CDN such as Cloudflare or Google front ends. Those addresses serve other sites too.
    var pf: Bool

    init(id: String, name: String, enabled: Bool, hosts: [String], pf: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.hosts = hosts
        self.pf = pf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        pf = try c.decodeIfPresent(Bool.self, forKey: .pf) ?? false
    }
}

/// Contents of config.json. The daemon writes the defaults when the file is missing.
struct FenceConfigFile: Codable, Equatable {
    var blockedCountries: [String]
    var services: [ServiceConfig]

    var enabledHosts: [String] {
        services.filter { $0.enabled }.flatMap { $0.hosts }
    }

    /// Hosts of enabled services that also get the pf layer.
    var enabledPFHosts: [String] {
        services.filter { $0.enabled && $0.pf }.flatMap { $0.hosts }
    }

    var allHosts: [String] {
        services.flatMap { $0.hosts }
    }

    static let defaults = FenceConfigFile(
        blockedCountries: FenceConfig.blockedCountries.sorted(),
        services: FenceConfig.defaultServices
    )

    /// Add services that a newer build introduced. Keep the user's choices for the rest.
    mutating func mergeMissingDefaults() {
        for service in FenceConfig.defaultServices where !services.contains(where: { $0.id == service.id }) {
            services.append(service)
        }
    }
}

enum ConfigStore {
    /// Read config.json. Create it with the defaults when it is missing or unreadable.
    static func load() -> FenceConfigFile {
        if let data = FileManager.default.contents(atPath: FencePaths.configFile),
           var config = try? JSONCoding.decoder.decode(FenceConfigFile.self, from: data) {
            let before = config
            config.mergeMissingDefaults()
            if config != before { save(config) }
            return config
        }
        let config = FenceConfigFile.defaults
        save(config)
        return config
    }

    static func save(_ config: FenceConfigFile) {
        guard let data = try? JSONCoding.encoder.encode(config) else { return }
        let dir = (FencePaths.configFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: FencePaths.configFile), options: .atomic)
        chmod(FencePaths.configFile, 0o644)
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: FencePaths.configFile))?[.modificationDate] as? Date
    }
}

enum FenceConfig {
    static let version = "1.0.0"
    static let daemonLabel = "com.dm.fence.daemon"
    static let appLabel = "com.dm.fence.app"

    /// Default ISO 3166-1 alpha-2 codes for config.json. The daemon blocks when the public IP is in one of them.
    /// The set is every country that is absent from https://www.anthropic.com/supported-countries.
    /// Checked on 2026-10-28.
    static let blockedCountries: Set<String> = [
        "RU", // Russia
        "BY", // Belarus
        "CN", // China
        "HK", // Hong Kong
        "MO", // Macau
        "IR", // Iran
        "KP", // North Korea
        "SY", // Syria
        "CU", // Cuba
        "VE", // Venezuela
        "AF", // Afghanistan
        "MM", // Myanmar
        "YE", // Yemen
    ]

    /// Services that config.json starts with. The user can edit the file or use the menu.
    static let defaultServices: [ServiceConfig] = [
        ServiceConfig(id: "anthropic", name: "Anthropic / Claude", enabled: true, hosts: [
            "api.anthropic.com",
            "api-staging.anthropic.com",
            "console.anthropic.com",
            "statsig.anthropic.com",
            "claude.ai",
            "www.claude.ai",
            "claude.com",
            "www.claude.com",
            "platform.claude.com",
        ], pf: true),
        ServiceConfig(id: "openai", name: "OpenAI / ChatGPT", enabled: true, hosts: [
            "api.openai.com",
            "chatgpt.com",
            "www.chatgpt.com",
            "chat.openai.com",
            "auth.openai.com",
            "platform.openai.com",
        ]),
        ServiceConfig(id: "cursor", name: "Cursor", enabled: true, hosts: [
            "api2.cursor.sh",
            "api3.cursor.sh",
            "api4.cursor.sh",
            "authenticator.cursor.sh",
            "cursor.sh",
            "cursor.com",
            "www.cursor.com",
        ]),
        ServiceConfig(id: "gemini", name: "Google Gemini API / AI Studio", enabled: true, hosts: [
            "generativelanguage.googleapis.com",
            "aistudio.google.com",
            "gemini.google.com",
        ]),
        ServiceConfig(id: "copilot", name: "GitHub Copilot", enabled: false, hosts: [
            "api.githubcopilot.com",
            "api.individual.githubcopilot.com",
            "api.business.githubcopilot.com",
            "copilot-proxy.githubusercontent.com",
        ]),
        ServiceConfig(id: "notion", name: "Notion", enabled: false, hosts: [
            "notion.so",
            "www.notion.so",
            "notion.com",
            "www.notion.com",
            "api.notion.com",
        ]),
        ServiceConfig(id: "xai", name: "xAI / Grok", enabled: false, hosts: [
            "api.x.ai",
            "accounts.x.ai",
            "grok.com",
            "www.grok.com",
        ]),
        ServiceConfig(id: "perplexity", name: "Perplexity", enabled: false, hosts: [
            "perplexity.ai",
            "www.perplexity.ai",
            "api.perplexity.ai",
        ]),
        ServiceConfig(id: "mistral", name: "Mistral", enabled: false, hosts: [
            "mistral.ai",
            "api.mistral.ai",
            "chat.mistral.ai",
            "console.mistral.ai",
        ]),
    ]

    /// The daemon checks the country on this interval when nothing changes.
    static let periodicCheckInterval: TimeInterval = 60
    /// The daemon checks the country on this interval while the block is active.
    static let blockedRecheckInterval: TimeInterval = 15
    /// Delay between a network change and the first country check. The VPN needs time to settle.
    static let settleDelay: TimeInterval = 1.5
    /// Delay before a retry when the geo lookup fails.
    static let retryDelay: TimeInterval = 4
    /// The watchdog pings the main queue on this interval.
    static let watchdogInterval: TimeInterval = 15
    /// The daemon exits after this many missed pings. launchd then restarts it.
    static let watchdogMissedPings = 6
    /// A socket command waits this long for the main queue. Then the reply carries the last state.
    static let commandWait: TimeInterval = 3
}

enum FencePaths {
    /// Test prefix. Set FENCE_PREFIX to run the daemon without root in dry-run mode.
    static let prefix = ProcessInfo.processInfo.environment["FENCE_PREFIX"] ?? ""
    static let supportDir = prefix + "/Library/Application Support/Fence"
    static let stateFile = supportDir + "/state.json"
    static let configFile = supportDir + "/config.json"
    static let knownIPsFile = supportDir + "/known_ips.json"
    static let pfRulesFile = supportDir + "/pf.rules"
    static let logDir = prefix + "/Library/Logs/Fence"
    static let logFile = logDir + "/daemon.log"
    /// FENCE_SOCKET overrides the socket path. A unix socket path must stay under 104 bytes.
    static let socketPath = ProcessInfo.processInfo.environment["FENCE_SOCKET"] ?? (prefix + "/var/run/fence.sock")
    static let hostsFile = prefix + "/etc/hosts"
    static let daemonBinary = "/usr/local/libexec/fence-daemon"
    /// Sub-anchor of "com.apple/*". The default /etc/pf.conf evaluates it.
    static let pfAnchor = "com.apple/fence"
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
