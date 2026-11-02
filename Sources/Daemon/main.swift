import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let dryRun = arguments.contains("--dry-run")

func usage() {
    print("""
    fence-daemon <command>

      run [--dry-run]   Start the daemon. Root is required. --dry-run skips pf, DNS flush and root check.
      status            Print the daemon state as JSON.
      manual-on         Set the manual block.
      manual-off        Clear the manual block.
      recheck           Check the country now.
      reload            Re-read config.json.
      service-on <id>   Enable a service from config.json.
      service-off <id>  Disable a service from config.json.
      services          List the services and their state.
      geo               Run one geo lookup and print the result. No daemon needed.
      cleanup           Remove the hosts block and the pf anchor. Root is required. Used by uninstall.sh.
    """)
}

switch command {
case "run":
    if !dryRun && getuid() != 0 {
        FileHandle.standardError.write(Data("run: root is required. Use --dry-run for a test without root.\n".utf8))
        exit(2)
    }
    Daemon(dryRun: dryRun).run()

case "status", "manual-on", "manual-off", "recheck", "reload", "service-on", "service-off", "services":
    let line = arguments.filter { !$0.hasPrefix("--") }.joined(separator: " ")
    guard let cmd = FenceCommand(line: command == "services" ? "status" : line) else {
        usage()
        exit(2)
    }
    do {
        let state = try SocketClient.send(cmd)
        if command == "services" {
            for service in state.services {
                print("\(service.enabled ? "[x]" : "[ ]") \(service.id)\t\(service.name)")
            }
        } else {
            let data = try JSONCoding.encoder.encode(state)
            print(String(decoding: data, as: UTF8.self))
        }
    } catch {
        FileHandle.standardError.write(Data("cannot reach the daemon: \(error)\n".utf8))
        exit(1)
    }

case "geo":
    switch GeoLookup.lookup() {
    case .success(let geo):
        print("\(geo.country) \(geo.ip) via \(geo.source)")
    case .failure(let error):
        print("lookup failed: \(error.message)")
        exit(1)
    }

case "cleanup":
    if !dryRun && getuid() != 0 {
        FileHandle.standardError.write(Data("cleanup: root is required.\n".utf8))
        exit(2)
    }
    let log = Logger(path: FencePaths.logFile)
    Blocker(log: log, dryRun: dryRun).remove(reason: "cleanup")
    log.flush()
    print("cleanup done")

case "help", "-h", "--help":
    usage()

default:
    usage()
    exit(2)
}
