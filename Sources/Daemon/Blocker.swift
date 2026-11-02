import Foundation

/// Apply and remove the block.
///
/// Two layers:
/// 1. /etc/hosts points the blocked hosts to 127.0.0.1 and ::1. New connections fail at once.
/// 2. A pf anchor drops packets to the known IPs of those hosts. Open keep-alive connections die.
final class Blocker {
    private let log: Logger
    private let dryRun: Bool
    private let work = DispatchQueue(label: "fence.blocker")
    private let resolveQueue = DispatchQueue(label: "fence.resolve")
    private var resolving = false
    /// Known addresses per host. The pf table is the union over the hosts of the current block.
    private var knownIPs: [String: Set<String>] = [:]
    /// Hosts of the current block. Set by apply().
    private var currentHosts: [String] = []
    /// Subset of currentHosts that gets the pf layer.
    private var currentPFHosts: [String] = []
    /// True between apply() and remove(). A late resolve result reloads pf only while this is true.
    private var wantBlocked = false
    /// Hosts from the config that failed validation. Each one is logged once.
    private var reportedBadHosts: Set<String> = []

    private let beginMarker = "# >>> Fence managed block. Do not edit. >>>"
    private let endMarker = "# <<< Fence managed block <<<"

    init(log: Logger, dryRun: Bool) {
        self.log = log
        self.dryRun = dryRun
        loadKnownIPs()
    }

    // MARK: Public

    /// Apply the block for `hosts` now. `pfHosts` is the subset that also gets the pf layer.
    /// Return nil on success, or the error text when the hosts file was not written.
    @discardableResult
    func apply(hosts: [String], pfHosts: [String], reason: String) -> String? {
        work.sync {
            wantBlocked = true
            currentHosts = validated(hosts)
            currentPFHosts = validated(pfHosts)
            let error = updateHosts(blocked: true, reason: reason)
            pfApply()
            pfKillStates()
            return error
        }
    }

    /// Remove the block now. Return nil on success, or the error text.
    @discardableResult
    func remove(reason: String) -> String? {
        work.sync {
            wantBlocked = false
            let error = updateHosts(blocked: false, reason: reason)
            pfClear()
            return error
        }
    }

    /// True when /etc/hosts contains the managed block.
    func hostsBlockPresent() -> Bool {
        work.sync {
            guard let text = try? String(contentsOfFile: FencePaths.hostsFile, encoding: .utf8) else { return false }
            return text.contains(beginMarker)
        }
    }

    /// Resolve `hosts` with the system resolver and merge the result into the known IP map.
    /// Call it only while the block is off: with the block on, the resolver returns loopback.
    /// Loopback and private addresses never enter the map.
    func refreshIPs(hosts: [String]) {
        let shouldRun: Bool = work.sync {
            if resolving { return false }
            resolving = true
            return true
        }
        guard shouldRun else { return }
        let valid = validated(hosts)
        resolveQueue.async {
            var found: [String: Set<String>] = [:]
            for host in valid {
                found[host] = Self.systemResolve(host).filter(Self.isPublicAddress)
            }
            let added: Bool = self.work.sync {
                self.resolving = false
                var changed = false
                var relevant = false
                for (host, ips) in found where !ips.isEmpty {
                    let merged = (self.knownIPs[host] ?? []).union(ips)
                    if merged != self.knownIPs[host] {
                        self.knownIPs[host] = merged
                        changed = true
                        if self.currentPFHosts.contains(host) { relevant = true }
                    }
                }
                if changed {
                    self.saveKnownIPs()
                    self.log.info("resolved \(valid.count) hosts, known addresses: \(self.activeIPs().count) active, \(self.knownIPs.count) hosts total")
                }
                return relevant
            }
            guard added else { return }
            self.work.sync {
                guard self.wantBlocked else { return }
                self.pfApply()
                self.pfKillStates()
            }
        }
    }

    // MARK: Validation

    /// Keep only well formed host names. A bad name could break the hosts file or pass as a dig option.
    private func validated(_ hosts: [String]) -> [String] {
        hosts.filter { host in
            if Hostname.isValid(host) { return true }
            if !reportedBadHosts.contains(host) {
                reportedBadHosts.insert(host)
                log.warn("config: host '\(host.prefix(80))' is not a valid host name, skipped")
            }
            return false
        }
    }

    /// Addresses of the pf hosts in the current block.
    private func activeIPs() -> Set<String> {
        var out: Set<String> = []
        for host in currentPFHosts {
            out.formUnion(knownIPs[host] ?? [])
        }
        return out
    }

    // MARK: Hosts

    /// Return nil on success, or the error text.
    private func updateHosts(blocked: Bool, reason: String) -> String? {
        do {
            if try writeHosts(blocked: blocked) {
                log.info("hosts: block \(blocked ? "written" : "removed") (\(reason))")
                flushDNS()
            }
            return nil
        } catch {
            let text = "hosts file \(blocked ? "block" : "unblock") failed: \(error.localizedDescription)"
            log.error(text)
            return text
        }
    }

    /// Rewrite the hosts file. Return true when the file changed.
    private func writeHosts(blocked: Bool) throws -> Bool {
        let path = FencePaths.hostsFile
        let original = try String(contentsOfFile: path, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")

        if let start = lines.firstIndex(of: beginMarker) {
            let stop = lines[start...].firstIndex(of: endMarker) ?? (lines.count - 1)
            lines.removeSubrange(start...stop)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        if blocked {
            lines.append("")
            lines.append(beginMarker)
            for host in currentHosts {
                lines.append("127.0.0.1\t\(host)")
                lines.append("::1\t\(host)")
            }
            lines.append(endMarker)
        }

        let updated = lines.joined(separator: "\n") + "\n"
        if updated == original { return false }

        let tmp = path + ".fence.tmp"
        try updated.write(toFile: tmp, atomically: false, encoding: .utf8)
        chmod(tmp, 0o644)
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "rename: \(UnixSocket.errnoText())"])
        }
        return true
    }

    private func flushDNS() {
        if dryRun {
            log.info("dry run: skip DNS flush")
            return
        }
        Shell.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 10)
        Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 10)
    }

    // MARK: pf

    private func pfApply() {
        let ips = activeIPs()
        guard !ips.isEmpty else {
            if !currentPFHosts.isEmpty { log.warn("pf: no known addresses yet, hosts layer only") }
            pfClear()
            return
        }
        let list = ips.sorted().joined(separator: ", ")
        let rules = """
        table <fence_block> persist { \(list) }
        block drop out quick proto tcp from any to <fence_block>
        block drop out quick proto udp from any to <fence_block>

        """
        do {
            try rules.write(toFile: FencePaths.pfRulesFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("pf: cannot write rules: \(error.localizedDescription)")
            return
        }
        if dryRun {
            log.info("dry run: skip pf load (\(ips.count) addresses)")
            return
        }
        let load = Shell.run("/sbin/pfctl", ["-q", "-a", FencePaths.pfAnchor, "-f", FencePaths.pfRulesFile])
        if !load.ok {
            log.warn("pf: load failed: \(load.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // -E takes a reference on pf. Other tools keep their own references.
        Shell.run("/sbin/pfctl", ["-q", "-E"])
    }

    private func pfKillStates() {
        if dryRun { return }
        for ip in activeIPs() {
            let any = ip.contains(":") ? "::/0" : "0.0.0.0/0"
            Shell.run("/sbin/pfctl", ["-q", "-k", any, "-k", ip], timeout: 5)
        }
    }

    private func pfClear() {
        if dryRun {
            log.info("dry run: skip pf clear")
            return
        }
        let r = Shell.run("/sbin/pfctl", ["-q", "-a", FencePaths.pfAnchor, "-F", "all"])
        if !r.ok {
            log.warn("pf: clear failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Resolve

    private static func systemResolve(_ host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: Set<String> = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                out.insert(text.split(separator: "%").first.map(String.init) ?? text)
            }
            node = info.pointee.ai_next
        }
        return out
    }

    /// True for a global unicast address. Loopback, private, link local and multicast ranges
    /// must never land in the pf table: a poisoned DNS answer could then cut local traffic.
    static func isPublicAddress(_ s: String) -> Bool {
        if isIPv4(s) {
            let p = s.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            if p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224 { return false }
            if p[0] == 169 && p[1] == 254 { return false }
            if p[0] == 172 && (16...31).contains(p[1]) { return false }
            if p[0] == 192 && p[1] == 168 { return false }
            if p[0] == 100 && (64...127).contains(p[1]) { return false }
            return true
        }
        if isIPv6(s) {
            let lower = s.lowercased()
            if lower == "::" || lower == "::1" { return false }
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return false }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("ff") { return false }
            if lower.hasPrefix("::ffff:") { return false }
            return true
        }
        return false
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let n = Int(part), (0...255).contains(n) else { return false }
            return true
        }
    }

    static func isIPv6(_ s: String) -> Bool {
        guard s.contains(":"), s.count <= 45 else { return false }
        let allowed = Set("0123456789abcdefABCDEF:")
        return s.allSatisfy { allowed.contains($0) }
    }

    // MARK: Known IP store

    /// Load the map. Every entry passes the same checks as a fresh resolver answer.
    private func loadKnownIPs() {
        guard let data = FileManager.default.contents(atPath: FencePaths.knownIPsFile),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        for (host, ips) in map where Hostname.isValid(host) {
            let clean = Set(ips.filter(Self.isPublicAddress))
            if !clean.isEmpty { knownIPs[host] = clean }
        }
    }

    private func saveKnownIPs() {
        let map = knownIPs.mapValues { $0.sorted() }
        guard let data = try? JSONCoding.encoder.encode(map) else { return }
        try? data.write(to: URL(fileURLWithPath: FencePaths.knownIPsFile), options: .atomic)
    }
}
