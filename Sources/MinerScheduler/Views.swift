import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: ViewModel
    @State var tab = "dash"
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("⛏️ Miner Scheduler").font(.headline)
                Spacer()
                if vm.protoLoggedIn {
                    Label("Proto", systemImage: "lock.open.fill").foregroundColor(.green).font(.caption)
                }
                Button(action: { vm.checkAllStatuses() }) {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).help("Refresh")
            }.padding()
            
            if !vm.protoLoggedIn {
                LoginBar(label: "Proto", password: $vm.protoPassword, error: $vm.protoLoginError) { vm.loginProto() }
            }
            
            Picker("", selection: $tab) {
                Text("Dashboard").tag("dash")
                Text("Settings").tag("set")
            }.pickerStyle(.segmented).padding(.horizontal)
            
            if tab == "dash" { DashboardView() } else { SettingsView() }
        }
        .frame(minWidth: 500, minHeight: 620)
    }
}

struct LoginBar: View {
    let label: String
    @Binding var password: String
    @Binding var error: String
    let onLogin: () -> Void
    @State private var pw = ""
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundColor(.orange).font(.caption)
            Text("\(label):").font(.caption).foregroundColor(.secondary)
            SecureField("Password", text: $pw)
                .textFieldStyle(.roundedBorder).frame(width: 140).onSubmit { submit() }
            Button("Login") { submit() }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(pw.isEmpty)
            if !error.isEmpty { Text(error).font(.caption).foregroundColor(.red) }
        }
        .padding(.horizontal).padding(.vertical, 5).background(Color(.controlBackgroundColor))
    }
    private func submit() { guard !pw.isEmpty else { return }; password = pw; onLogin() }
}

// MARK: - Dashboard
struct DashboardView: View {
    @EnvironmentObject var vm: ViewModel
    @State private var powerText = ""
    
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Next action
                HStack {
                    VStack(alignment: .leading) {
                        Text("Next Action").font(.caption).foregroundColor(.gray)
                        Text(vm.nextAction).font(.headline)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(vm.scheduleEnabled ? .green : .gray).frame(width: 6, height: 6)
                        Text(vm.scheduleEnabled ? "Auto" : "Off").font(.caption).foregroundColor(.secondary)
                    }
                }.padding(12).background(Color(.controlBackgroundColor)).cornerRadius(8)
                
                // PROTO
                MinerCardView(name: "Proto", status: vm.protoStatus, stats: protoStats) {
                    AnyView(HStack(spacing: 8) {
                        Button("ON") { vm.controlProto("on") }.buttonStyle(.bordered).tint(.green).controlSize(.small)
                        Button("OFF") { vm.controlProto("off") }.buttonStyle(.bordered).tint(.red).controlSize(.small)
                        Button("Reboot") { vm.rebootProto() }.buttonStyle(.bordered).tint(.orange).controlSize(.small)
                        Spacer()
                        TextField("W", text: $powerText)
                            .textFieldStyle(.roundedBorder).frame(width: 65)
                            .font(.system(.caption, design: .monospaced))
                            .onAppear { if powerText.isEmpty { powerText = "\(vm.protoPowerTarget)" } }
                            .onSubmit { applyPower() }
                        Button("Set") { applyPower() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(Int(powerText) == nil || Int(powerText) == vm.protoPowerTarget)
                        Text("max \(vm.protoPowerMax)").font(.caption2).foregroundColor(.gray)
                    })
                }
                
                // AVALON
                MinerCardView(name: "Avalon", status: vm.avalonStatus, stats: avalonStats) {
                    AnyView(VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("ON") { vm.controlAvalon("on") }.buttonStyle(.bordered).tint(.green).controlSize(.small)
                            Button("OFF") { vm.controlAvalon("off") }.buttonStyle(.bordered).tint(.red).controlSize(.small)
                            Spacer()
                            Text("Mode:").font(.caption).foregroundColor(.gray)
                            ForEach(["0", "1", "2"], id: \.self) { m in
                                let name = m == "0" ? "Eco" : m == "1" ? "Std" : "Super"
                                let active = vm.avalonMode == (m == "0" ? "Eco" : m == "1" ? "Standard" : "Super")
                                Button(name) { vm.setAvalonMode(m) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .tint(active ? .blue : .gray)
                            }
                        }
                    })
                }
                
                // Logs
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Logs").font(.headline); Spacer()
                        if !vm.logs.isEmpty { Button("Clear") { vm.logs.removeAll() }.buttonStyle(.borderless).font(.caption) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if vm.logs.isEmpty {
                            Text("No activity yet").font(.caption).foregroundColor(.gray)
                        } else {
                            ForEach(Array(vm.logs.prefix(15).enumerated()), id: \.offset) { _, log in
                                Text(log).font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
                            }
                        }
                    }.padding(8).background(Color(.controlBackgroundColor)).cornerRadius(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }.padding(16)
        }
    }
    
    private func applyPower() {
        guard let w = Int(powerText), w >= vm.protoPowerMin, w <= vm.protoPowerMax else { return }
        vm.setProtoPowerTarget(w)
    }
    
    private var protoStats: [(String, String)] {
        guard vm.protoHashrate > 0 else { return [] }
        return [
            ("Hashrate", String(format: "%.1f TH/s", vm.protoHashrate / 1000)),
            ("Power", String(format: "%.0f W", vm.protoPower)),
            ("J/TH", String(format: "%.2f", vm.protoEfficiency)),
            ("Boards", "\(vm.protoBoards)/\(vm.protoTotalBoards)"),
        ]
    }
    
    private var avalonStats: [(String, String)] {
        guard vm.avalonHashrate > 0 else { return [] }
        var s: [(String, String)] = [
            ("Hashrate", String(format: "%.1f TH/s", vm.avalonHashrate)),
        ]
        if vm.avalonPower > 0 {
            s.append(("Power", String(format: "%.0f W", vm.avalonPower)))
        }
        if vm.avalonEfficiency > 0 {
            s.append(("J/TH", String(format: "%.1f", vm.avalonEfficiency)))
        }
        if vm.avalonMode != "—" {
            s.append(("Mode", vm.avalonMode))
        }
        if !vm.avalonTemp.isEmpty {
            s.append(("Temp", "\(vm.avalonTemp)°C"))
        }
        if !vm.avalonFanPct.isEmpty {
            s.append(("Fan", "\(vm.avalonFanPct)"))
        }
        return s
    }
}

// MARK: - Miner Card
struct MinerCardView<Controls: View>: View {
    let name: String; let status: String; let stats: [(String, String)]
    @ViewBuilder let controls: () -> Controls
    
    private var statusColor: Color {
        switch status {
        case "Mining": return .green
        case "Offline": return .red
        case "Idle", "Stopped": return .gray
        default: return .orange
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(name).font(.headline); Spacer()
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(status).font(.subheadline).foregroundColor(.secondary)
                }
            }
            if !stats.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        VStack(spacing: 2) {
                            Text(stat.0).font(.caption2).foregroundColor(.gray)
                            Text(stat.1).font(.system(.caption, design: .monospaced)).bold()
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            controls()
        }.padding(12).background(Color(.controlBackgroundColor)).cornerRadius(8)
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var vm: ViewModel
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Network").font(.headline)
                    IPRow(label: "Proto", ip: $vm.protoIP, port: $vm.protoPort)
                    IPRow(label: "Avalon", ip: $vm.avalonIP, port: $vm.avalonAPIPort)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Schedule").font(.headline)
                        Spacer()
                        Toggle("Enabled", isOn: $vm.scheduleEnabled).toggleStyle(.switch).labelsHidden()
                        Text(vm.scheduleEnabled ? "On" : "Off").font(.caption).foregroundColor(vm.scheduleEnabled ? .green : .gray)
                    }
                    TimeRow(label: "Proto ON", time: $vm.protoOnTime)
                    TimeRow(label: "Proto OFF", time: $vm.protoOffTime)
                    TimeRow(label: "Avalon ON", time: $vm.avalonOnTime)
                    TimeRow(label: "Avalon OFF", time: $vm.avalonOffTime)
                }
                Spacer()
            }.padding(16)
        }
    }
}

struct IPRow: View {
    let label: String; @Binding var ip: String; @Binding var port: String
    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading); Spacer()
            TextField("IP", text: $ip).textFieldStyle(.roundedBorder).frame(width: 140)
            Text(":").foregroundColor(.gray)
            TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 60)
        }.padding(8).background(Color(.controlBackgroundColor)).cornerRadius(6)
    }
}

struct TimeRow: View {
    let label: String; @Binding var time: String
    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading); Spacer()
            TextField("HH:MM", text: $time).textFieldStyle(.roundedBorder).frame(width: 80)
        }.padding(8).background(Color(.controlBackgroundColor)).cornerRadius(6)
    }
}
