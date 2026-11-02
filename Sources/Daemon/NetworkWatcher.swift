import Foundation
import Network
import SystemConfiguration

/// Report network changes. Two sources: NWPathMonitor and the SystemConfiguration dynamic store.
/// The callback runs on `queue` and gets a signature string. The caller compares signatures.
final class NetworkWatcher {
    private let queue: DispatchQueue
    private let monitor = NWPathMonitor()
    private var store: SCDynamicStore?
    private var currentPath: NWPath?

    var onChange: ((String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        if let store = SCDynamicStoreCreate(nil, "fence" as CFString, callback, &context) {
            self.store = store
            let keys = [
                "State:/Network/Global/IPv4",
                "State:/Network/Global/IPv6",
                "State:/Network/Global/DNS",
            ] as CFArray
            let patterns = [
                "State:/Network/Interface/.*/IPv4",
                "State:/Network/Service/.*/IPv4",
            ] as CFArray
            SCDynamicStoreSetNotificationKeys(store, keys, patterns)
            SCDynamicStoreSetDispatchQueue(store, queue)
        }

        // Start the path monitor last. Its first callback then sees the dynamic store.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.currentPath = path
            self.fire()
        }
        monitor.start(queue: queue)
    }

    /// Describe the current network. Any change in this string means the route may have changed.
    func signature() -> String {
        var parts: [String] = []
        if let path = currentPath {
            parts.append("status=\(path.status)")
            let names = path.availableInterfaces.map { "\($0.name)/\($0.type)" }.sorted()
            parts.append("if=" + names.joined(separator: ","))
            if #available(macOS 11.0, *) {
                let gateways = path.gateways.map { "\($0)" }.sorted()
                parts.append("gw=" + gateways.joined(separator: ","))
            }
        }
        if let store = store,
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            let primary = global["PrimaryInterface"] as? String ?? "-"
            let router = global["Router"] as? String ?? "-"
            parts.append("primary=\(primary) router=\(router)")
        } else {
            parts.append("primary=none")
        }
        return parts.joined(separator: " ")
    }

    private func fire() {
        onChange?(signature())
    }
}
