import AppKit
import Foundation

// Anonymous usage telemetry. Events are appended to an on-disk spool
// (so nothing is lost offline) and batch-posted to Supabase with an
// insert-only key. Strictly anonymous: a random device UUID plus event
// names and coarse metadata — never message content, prompts, file
// paths, or raw provider output. Every entry point hops onto a private
// serial queue and swallows all failures; telemetry must never crash,
// block, or slow the app.
enum Telemetry {
    private enum Config {
        static let url = "https://ogiqgovvlrlypsjvtitq.supabase.co"
        static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9naXFnb3Z2bHJseXBzanZ0aXRxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ2MDMyMjgsImV4cCI6MjEwMDE3OTIyOH0.EIIcpZHKInzWXb_oNDODIULww7POhUJ3Ovu6xAhbYrE"
        static let flushBatchSize = 100
        static let flushThreshold = 20
        static let spoolByteCap = 512 * 1024
        static let spoolLineCap = 200
        static let maxBackoff: TimeInterval = 3600
    }

    private static let queue = DispatchQueue(label: "eave.telemetry", qos: .utility)
    private static let disabled = ProcessInfo.processInfo.environment["EAVE_TELEMETRY_DISABLED"] != nil
    private static var settingsSnapshot: (() -> [String: String])?
    private static var timer: DispatchSourceTimer?
    private static var pendingSinceFlush = 0
    private static var nextFlushAllowedAt = Date.distantPast
    private static var backoff: TimeInterval = 30
    private static var flushInFlight = false

    private static let spoolURL: URL = {
        let dir = AppPaths.supportDirectory.appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spool.ndjson")
    }()

    private static let appVersion: String = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }()

    private static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public API

    static func start(settingsSnapshot: @escaping () -> [String: String]) {
        guard !disabled else { return }
        queue.async {
            self.settingsSnapshot = settingsSnapshot
            if UserDefaults.standard.string(forKey: "telemetryDeviceID") == nil {
                UserDefaults.standard.set(UUID().uuidString, forKey: "telemetryDeviceID")
                append(event: "install", props: [:])
            }
            append(event: "launch", props: [:])
            heartbeatCheckLocked()
            startTimerLocked()
            queue.asyncAfter(deadline: .now() + 5) { flushLocked() }
        }
        // Timers are suspended while the Mac sleeps; the wake notification is
        // what lets a machine that slept past midnight emit its daily heartbeat.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            queue.async {
                heartbeatCheckLocked()
                flushLocked()
            }
        }
    }

    static func record(_ event: String, _ props: [String: String] = [:]) {
        guard !disabled else { return }
        queue.async {
            append(event: event, props: props)
            pendingSinceFlush += 1
            if pendingSinceFlush >= Config.flushThreshold { flushLocked() }
        }
    }

    // Best-effort synchronous flush at quit, hard-capped so termination is
    // never held up. Anything unsent stays in the spool for next launch.
    static func flushBeforeQuit() {
        guard !disabled else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            flushLocked(ignoreBackoff: true) { done.signal() }
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    // MARK: - Spool (queue-only)

    private static func append(event: String, props: [String: String]) {
        let line: [String: Any] = [
            "event": event,
            "props": props,
            "client_ts": isoFormatter.string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        if let handle = try? FileHandle(forWritingTo: spoolURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: spoolURL)
        }
        capSpoolIfNeeded()
    }

    private static func readSpoolLines() -> [String] {
        guard let raw = try? String(contentsOf: spoolURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func writeSpoolLines(_ lines: [String]) {
        if lines.isEmpty {
            try? FileManager.default.removeItem(at: spoolURL)
        } else {
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: spoolURL)
        }
    }

    // Weeks offline shouldn't grow the spool unboundedly; keep the newest events.
    private static func capSpoolIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: spoolURL.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > Config.spoolByteCap else { return }
        writeSpoolLines(Array(readSpoolLines().suffix(Config.spoolLineCap)))
    }

    // MARK: - Heartbeat (queue-only)

    private static func heartbeatCheckLocked() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let today = formatter.string(from: Date())
        guard UserDefaults.standard.string(forKey: "telemetryLastHeartbeatDay") != today else { return }
        UserDefaults.standard.set(today, forKey: "telemetryLastHeartbeatDay")
        // Settings live on the main actor; snapshot there, then re-enter record().
        let snapshot = settingsSnapshot
        DispatchQueue.main.async {
            record("heartbeat", snapshot?() ?? [:])
        }
    }

    private static func startTimerLocked() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 900, repeating: 900, leeway: .seconds(60))
        t.setEventHandler {
            heartbeatCheckLocked()
            flushLocked()
        }
        t.resume()
        timer = t
    }

    // MARK: - Flush (queue-only)

    private static func flushLocked(ignoreBackoff: Bool = false, completion: (() -> Void)? = nil) {
        guard !flushInFlight else { completion?(); return }
        guard ignoreBackoff || Date() >= nextFlushAllowedAt else { completion?(); return }
        let lines = readSpoolLines()
        guard !lines.isEmpty else {
            pendingSinceFlush = 0
            completion?()
            return
        }
        let batch = Array(lines.prefix(Config.flushBatchSize))
        guard let deviceID = UserDefaults.standard.string(forKey: "telemetryDeviceID") else {
            completion?()
            return
        }

        var rows: [[String: Any]] = []
        for line in batch {
            guard let data = line.data(using: .utf8),
                  var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row["event"] is String else { continue }
            row["device_id"] = deviceID
            row["app_version"] = appVersion
            row["os_version"] = osVersion
            rows.append(row)
        }
        // Malformed lines are dropped with their batch either way.
        guard !rows.isEmpty, let body = try? JSONSerialization.data(withJSONObject: rows) else {
            writeSpoolLines(Array(lines.dropFirst(batch.count)))
            completion?()
            return
        }

        guard let url = URL(string: "\(Config.url)/rest/v1/events") else {
            completion?()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(Config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        flushInFlight = true
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { _, response, _ in
            session.finishTasksAndInvalidate()
            queue.async {
                flushInFlight = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    pendingSinceFlush = 0
                    backoff = 30
                    nextFlushAllowedAt = .distantPast
                    let remaining = Array(readSpoolLines().dropFirst(batch.count))
                    writeSpoolLines(remaining)
                    if remaining.isEmpty {
                        completion?()
                    } else {
                        flushLocked(ignoreBackoff: ignoreBackoff, completion: completion)
                    }
                } else {
                    nextFlushAllowedAt = Date().addingTimeInterval(backoff)
                    backoff = min(backoff * 2, Config.maxBackoff)
                    completion?()
                }
            }
        }.resume()
    }
}
