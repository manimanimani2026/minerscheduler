import SwiftUI
import Foundation

@main
struct MinerSchedulerApp: App {
    @StateObject var vm = ViewModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(vm) }
    }
}

@MainActor
class ViewModel: ObservableObject {
    // Proto state
    @Published var protoStatus = "Checking…"
    @Published var protoHashrate: Double = 0
    @Published var protoPower: Double = 0
    @Published var protoEfficiency: Double = 0
    @Published var protoBoards: Int = 0
    @Published var protoTotalBoards: Int = 5
    @Published var protoPowerTarget: Int = 6900
    @Published var protoPowerMin: Int = 1500
    @Published var protoPowerMax: Int = 6900
    
    // Avalon state (all from litestats — no auth needed)
    @Published var avalonStatus = "Checking…"
    @Published var avalonHashrate: Double = 0    // TH/s
    @Published var avalonPower: Double = 0       // Watts (MPO from litestats)
    @Published var avalonEfficiency: Double = 0  // J/TH
    @Published var avalonAccepted: Int = 0
    @Published var avalonMode = "—"              // Eco/Standard/Super
    @Published var avalonFanPct = ""
    @Published var avalonTemp = ""
    
    // Network config
    @Published var protoIP = "192.168.86.51"
    @Published var protoPort = "80"
    @Published var avalonIP = "192.168.86.26"
    @Published var avalonAPIPort = "4028"
    
    // Schedule
    @Published var nextAction = ""
    @Published var logs: [String] = []
    @Published var protoOnTime = "23:01"
    @Published var protoOffTime = "06:59"
    @Published var avalonOnTime = "21:01"
    @Published var avalonOffTime = "15:59"
    
    // Proto auth
    @Published var protoPassword = ""
    @Published var protoLoggedIn = false
    @Published var protoLoginError = ""
    private var protoAuthToken: String?
    
    // Proto watchdog
    private var protoDegradedSince: Date?
    
    init() {
        updateNextAction()
        startMonitoring()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.checkAllStatuses()
        }
    }
    
    // MARK: - Shell helpers
    
    nonisolated private func curlProto(_ method: String, _ path: String, ip: String, port: String, token: String? = nil, body: String? = nil) -> (Int, String) {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = ["-s", "-w", "\n%{http_code}", "--connect-timeout", "5", "-X", method]
        if let t = token { args += ["-H", "Authorization: Bearer \(t)"] }
        if let b = body { args += ["-H", "Content-Type: application/json", "-d", b] }
        args.append("http://\(ip):\(port)/api/v1/\(path)")
        p.arguments = args; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return (0, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        let o = String(data: d, encoding: .utf8) ?? ""
        let lines = o.components(separatedBy: "\n")
        return (Int(lines.last ?? "") ?? 0, lines.dropLast().joined(separator: "\n"))
    }
    
    nonisolated private func ncAvalon(_ cmd: String, ip: String, port: String) -> String {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '\(cmd)' | nc -w 3 \(ip) \(port)"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(bytes: d.map { $0 == 0 ? UInt8(0x20) : $0 }, encoding: .utf8) ?? ""
    }
    
    nonisolated private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    
    // MARK: - Scheduling
    
    @Published var scheduleEnabled = true
    private var firedActions: Set<String> = []  // tracks "HH:mm-action" fired this minute
    
    func updateNextAction() {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let now = fmt.string(from: Date())
        let events = [
            (time: protoOnTime, label: "Proto ON"), (time: protoOffTime, label: "Proto OFF"),
            (time: avalonOnTime, label: "Avalon ON"), (time: avalonOffTime, label: "Avalon OFF"),
        ].sorted { $0.time < $1.time }
        if let next = events.first(where: { $0.time > now }) {
            nextAction = "Next: \(next.time) - \(next.label)"
        } else if let first = events.first {
            nextAction = "Next: \(first.time) - \(first.label) (tomorrow)"
        } else { nextAction = "No scheduled actions" }
    }
    
    func checkSchedule() {
        guard scheduleEnabled else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let now = fmt.string(from: Date())
        
        let actions: [(time: String, key: String, action: () -> Void)] = [
            (protoOnTime,  "proto-on",  { [weak self] in self?.controlProto("on") }),
            (protoOffTime, "proto-off", { [weak self] in self?.controlProto("off") }),
            (avalonOnTime, "avalon-on", { [weak self] in self?.controlAvalon("on") }),
            (avalonOffTime,"avalon-off",{ [weak self] in self?.controlAvalon("off") }),
        ]
        
        for a in actions {
            let fireKey = "\(a.time)-\(a.key)"
            if a.time == now && !firedActions.contains(fireKey) {
                firedActions.insert(fireKey)
                logs.insert("⏰ Schedule: \(a.key) triggered at \(now)", at: 0)
                a.action()
            }
        }
        
        // Clear fired actions from previous minutes
        firedActions = firedActions.filter { $0.hasPrefix(now) }
    }
    
    func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                self.updateNextAction()
                self.checkSchedule()
                self.checkAllStatuses()
            }
        }
    }
    
    func checkAllStatuses() { checkProtoStatus(); checkAvalonStatus() }
    
    // MARK: - Proto
    
    func checkProtoStatus() {
        let token = protoAuthToken; let ip = protoIP; let port = protoPort
        Task.detached {
            let (code, body) = self.curlProto("GET", "mining", ip: ip, port: port, token: token)
            await MainActor.run {
                guard code == 200, let json = self.parseJSON(body),
                      let ms = json["mining-status"] as? [String: Any] else {
                    self.protoStatus = code == 0 ? "Offline" : "HTTP \(code)"; return
                }
                let status = ms["status"] as? String ?? "Unknown"
                self.protoStatus = status
                self.protoHashrate = ms["average_hashrate_ghs"] as? Double ?? 0
                self.protoPower = ms["power_usage_watts"] as? Double ?? 0
                self.protoEfficiency = ms["power_efficiency_jth"] as? Double ?? 0
                self.protoBoards = ms["hashboards_mining"] as? Int ?? 0
                self.protoTotalBoards = ms["hashboards_installed"] as? Int ?? 5
                if let pt = ms["power_target_watts"] as? Int { self.protoPowerTarget = pt }
                else if let pt = ms["power_target_watts"] as? Double { self.protoPowerTarget = Int(pt) }
                
                // Watchdog: auto-reboot if degraded for 2+ minutes
                if status.lowercased().contains("degraded") {
                    if let since = self.protoDegradedSince {
                        let elapsed = Date().timeIntervalSince(since)
                        if elapsed >= 120 {
                            self.logs.insert("⚠️ Proto degraded for \(Int(elapsed))s — auto-rebooting", at: 0)
                            self.protoDegradedSince = nil
                            self.rebootProto()
                        } else {
                            self.logs.insert("⚠️ Proto degraded for \(Int(elapsed))s — waiting 2min before reboot", at: 0)
                        }
                    } else {
                        self.protoDegradedSince = Date()
                        self.logs.insert("⚠️ Proto entered degraded state — monitoring", at: 0)
                    }
                } else {
                    if self.protoDegradedSince != nil {
                        self.logs.insert("✅ Proto recovered from degraded state", at: 0)
                    }
                    self.protoDegradedSince = nil
                }
            }
        }
    }
    
    func setProtoPowerTarget(_ watts: Int) {
        let token = protoAuthToken; let ip = protoIP; let port = protoPort
        Task.detached {
            let (code, body) = self.curlProto("PUT", "mining/target", ip: ip, port: port, token: token,
                                               body: "{\"power_target_watts\":\(watts),\"performance_mode\":\"MaximumHashrate\"}")
            await MainActor.run {
                if (200...299).contains(code) { self.protoPowerTarget = watts; self.logs.insert("Proto: Power → \(watts)W ✓", at: 0) }
                else if code == 401 { self.logs.insert("Proto: Auth required — log in first", at: 0) }
                else { self.logs.insert("Proto: Set power failed (HTTP \(code)) \(body.prefix(80))", at: 0) }
            }
        }
    }
    
    func loginProto() {
        guard !protoPassword.isEmpty else { return }
        protoLoginError = ""; let pw = protoPassword; let ip = protoIP; let port = protoPort
        logs.insert("Proto: Logging in…", at: 0)
        Task.detached {
            let proc = Process(); let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = ["-s", "-w", "\n%{http_code}", "--connect-timeout", "5", "-X", "POST",
                              "-H", "Content-Type: application/json",
                              "-d", "{\"username\":\"admin\",\"password\":\"\(pw)\"}",
                              "http://\(ip):\(port)/api/v1/auth/login"]
            proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            do { try proc.run(); proc.waitUntilExit() } catch {
                await MainActor.run { self.protoLoginError = "Failed to connect" }; return
            }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            let o = String(data: d, encoding: .utf8) ?? ""
            let lines = o.components(separatedBy: "\n")
            let code = Int(lines.last ?? "") ?? 0
            let body = lines.dropLast().joined(separator: "\n")
            guard (200...299).contains(code) else {
                let msg: String
                if let j = self.parseJSON(body), let m = j["message"] as? String { msg = m } else { msg = "HTTP \(code)" }
                await MainActor.run { self.protoLoginError = msg; self.protoPassword = "" }; return
            }
            let token: String?
            if let j = self.parseJSON(body) { token = j["access_token"] as? String ?? j["token"] as? String } else { token = nil }
            await MainActor.run {
                self.protoAuthToken = token; self.protoLoggedIn = true
                self.logs.insert("Proto: Logged in ✓", at: 0); self.checkAllStatuses()
            }
        }
    }
    
    func controlProto(_ action: String) {
        let endpoint = action == "on" ? "mining/start" : "mining/stop"
        let token = protoAuthToken; let ip = protoIP; let port = protoPort
        Task.detached {
            let (code, _) = self.curlProto("POST", endpoint, ip: ip, port: port, token: token)
            await MainActor.run {
                self.logs.insert("Proto: \(action.uppercased()) \((200...299).contains(code) ? "✓" : "✗ HTTP \(code)")", at: 0)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.checkProtoStatus() }
        }
    }
    
    func rebootProto() {
        let token = protoAuthToken; let ip = protoIP; let port = protoPort
        Task.detached {
            let (code, _) = self.curlProto("POST", "system/reboot", ip: ip, port: port, token: token)
            await MainActor.run {
                self.logs.insert("Proto: Reboot \((200...299).contains(code) ? "✓" : "✗ HTTP \(code)")", at: 0)
                if (200...299).contains(code) { self.protoStatus = "Rebooting…" }
            }
        }
    }
    
    // MARK: - Avalon (all via CGMiner port 4028, no auth)
    
    func checkAvalonStatus() {
        let ip = avalonIP; let port = avalonAPIPort
        Task.detached {
            // Use litestats for rich data
            let lite = self.ncAvalon("litestats", ip: ip, port: port)
            
            // Also get summary for accepted shares
            let summ = self.ncAvalon("summary", ip: ip, port: port)
            
            if lite.isEmpty && summ.isEmpty {
                await MainActor.run { self.avalonStatus = "Offline" }; return
            }
            
            // Parse litestats
            var realtimeGHS: Double = 0
            var power: Double = 0
            var workmode = "—"
            var fanPct = ""
            var temp = ""
            var systemStatus = ""
            
            // Extract key=value pairs from litestats (format: KEY[VALUE])
            let bracketPattern = lite
            func extract(_ key: String) -> String? {
                guard let r = bracketPattern.range(of: "\(key)[") else { return nil }
                let start = r.upperBound
                guard let end = bracketPattern[start...].range(of: "]") else { return nil }
                return String(bracketPattern[start..<end.lowerBound])
            }
            
            if let gh = extract("GHSspd") { realtimeGHS = Double(gh) ?? 0 }
            if let ss = extract("SYSTEMSTATU") { systemStatus = ss }
            if let mpo = extract("MPO") { power = Double(mpo) ?? 0 }
            if let wm = extract("WORKMODE") {
                switch wm {
                case "0": workmode = "Eco"
                case "1": workmode = "Standard"
                case "2": workmode = "Super"
                default: workmode = "Mode \(wm)"
                }
            }
            if let fr = extract("FanR") { fanPct = fr }
            if let t = extract("TAvg") { temp = t }
            
            let hashrateTH = realtimeGHS / 1000
            let eff = (power > 0 && hashrateTH > 0) ? power / hashrateTH : 0
            
            // Parse summary for accepted
            var accepted = 0
            for field in summ.replacingOccurrences(of: "|", with: ",").components(separatedBy: ",") {
                let parts = field.components(separatedBy: "=")
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "Accepted" { accepted = Int(val) ?? 0 }
            }
            
            // Determine status from SYSTEMSTATU and real-time hashrate
            let status: String
            if systemStatus.contains("In Work") && realtimeGHS > 0 {
                status = "Mining"
            } else if systemStatus.contains("In Init") || systemStatus.contains("Calibrat") {
                status = "Starting"
            } else if systemStatus.contains("In Idle") || realtimeGHS == 0 {
                status = "Idle"
            } else {
                status = "Online"
            }
            
            await MainActor.run {
                self.avalonHashrate = hashrateTH
                self.avalonPower = power
                self.avalonEfficiency = eff
                self.avalonAccepted = accepted
                self.avalonMode = workmode
                self.avalonFanPct = fanPct
                self.avalonTemp = temp
                self.avalonStatus = status
            }
        }
    }
    
    func setAvalonMode(_ modeNum: String) {
        let ip = avalonIP; let port = avalonAPIPort
        let modeName: String
        switch modeNum {
        case "0": modeName = "Eco"
        case "1": modeName = "Standard"
        case "2": modeName = "Super"
        default: modeName = modeNum
        }
        Task.detached {
            let output = self.ncAvalon("ascset|0,workmode,set,\(modeNum)", ip: ip, port: port)
            await MainActor.run {
                if output.contains("STATUS=S") {
                    self.avalonMode = modeName
                    self.logs.insert("Avalon: Mode → \(modeName) ✓", at: 0)
                } else if output.contains("caling") {
                    self.logs.insert("Avalon: Calibrating — try again shortly", at: 0)
                } else {
                    let msg = output.contains("Msg=") ?
                        String(output[output.range(of: "Msg=")!.upperBound...].prefix(80)) : String(output.prefix(80))
                    self.logs.insert("Avalon: Mode ✗ \(msg)", at: 0)
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.checkAvalonStatus() }
        }
    }
    
    func controlAvalon(_ action: String) {
        let cmd = action == "on" ? "softon" : "softoff"
        let ip = avalonIP; let port = avalonAPIPort
        let ts = Int(Date().timeIntervalSince1970)
        Task.detached {
            let output = self.ncAvalon("ascset|0,\(cmd),1:\(ts)", ip: ip, port: port)
            await MainActor.run {
                if output.contains("success") {
                    self.logs.insert("Avalon: \(action.uppercased()) ✓", at: 0)
                } else {
                    self.logs.insert("Avalon: \(action.uppercased()) ✗ \(output.prefix(80))", at: 0)
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.checkAvalonStatus() }
        }
    }
}
