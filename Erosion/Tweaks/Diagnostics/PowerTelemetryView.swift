//
//  PowerTelemetryView.swift
//  Erosion
//
//  [Experimental / 测试特性] Read-only hardware battery health (raw mAh, cycle count,
//  voltage/amperage/wattage, cell temperature) & SoC thermal throttling telemetry
//  via APFS clonefile() snapshot of systemgroup.com.apple.powerlog.
//

import SwiftUI
import SQLite3

struct BatteryTelemetrySample: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let levelPercent: Double?
    let rawMaxCapacitymAh: Int?
    let nominalCapacitymAh: Int?
    let designCapacitymAh: Int?
    let cycleCount: Int?
    let voltagemV: Int?
    let amperagemA: Int?
    let temperatureCelsius: Double?
    let isCharging: Bool?

    var computedPowerWatts: Double? {
        guard let v = voltagemV, let a = amperagemA else { return nil }
        return (Double(v) * Double(a)) / 1_000_000.0
    }

    var trueHealthPercent: Double? {
        guard let raw = rawMaxCapacitymAh, let design = designCapacitymAh, design > 0 else { return nil }
        return (Double(raw) / Double(design)) * 100.0
    }
}

struct ThermalTelemetryEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let levelCode: Int
    let summary: String
}

struct PowerTelemetryView: View {
    @State private var isLoading = false
    @State private var statusBanner: String = L("点击右上角刷新按钮读取底层 Powerlog 快照遥测")
    @State private var powerlogAccessible = false
    @State private var latestBattery: BatteryTelemetrySample?
    @State private var recentBatterySamples: [BatteryTelemetrySample] = []
    @State private var thermalEvents: [ThermalTelemetryEvent] = []
    @State private var liveThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private static let powerlogDir = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.powerlog/Library/BatteryLife"
    private static let powerlogDBPath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"
    private static let telemetryQueue = DispatchQueue(label: "com.erosion.telemetry.powerlog", qos: .userInitiated)

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "flask.fill")
                        .foregroundStyle(Color.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("测试特性 · 纯只读硬件遥测快照")
                            .font(.subheadline.weight(.semibold))
                        Text("通过 APFS clonefile() 写时复制将 CurrentPowerlog.PLSQL 瞬时克隆至本应用临时目录后只读解析，零物理写入、绝不阻塞系统 powerlogHelperd 守护进程（注：部分 iOS 26 固件限制了系统级 Powerlog 沙盒令牌下发，iOS 27 真机支持完整读取）。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                HStack {
                    Text("当前芯片实时热状态 (ThermalState)")
                    Spacer()
                    Text(thermalStateLabel(liveThermalState))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(thermalStateColor(liveThermalState))
                }
                HStack {
                    Text("Powerlog 数据库快照状态")
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(powerlogAccessible ? L("✅ 已挂载只读快照") : L("未挂载 / 受限"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(powerlogAccessible ? Color.green : Color.secondary)
                    }
                }
                Text(statusBanner)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                HeaderLabel(L("实时芯片温控与数据源状态"), symbol: "thermometer.medium")
            }

            if let latest = latestBattery {
                Section {
                    if let health = latest.trueHealthPercent {
                        metricRow(
                            title: L("物理真实电池健康度"),
                            value: String(format: "%.2f%%", health),
                            accent: health >= 85 ? .green : (health >= 78 ? .orange : .red)
                        )
                    }
                    if let raw = latest.rawMaxCapacitymAh {
                        metricRow(title: L("真实物理最大容量 (RawMaxCapacity)"), value: "\(raw) mAh")
                    }
                    if let nom = latest.nominalCapacitymAh {
                        metricRow(title: L("系统标称满充容量 (NominalCapacity)"), value: "\(nom) mAh")
                    }
                    if let des = latest.designCapacitymAh {
                        metricRow(title: L("原厂设计容量 (DesignCapacity)"), value: "\(des) mAh")
                    }
                    if let cyc = latest.cycleCount {
                        metricRow(title: L("精确完整循环次数 (CycleCount)"), value: L("\(cyc) 次"))
                    }
                    if let temp = latest.temperatureCelsius {
                        metricRow(
                            title: L("电芯物理传感器温度"),
                            value: String(format: "%.1f °C", temp),
                            accent: temp >= 40 ? .red : (temp >= 36 ? .orange : .primary)
                        )
                    }
                    if let v = latest.voltagemV {
                        metricRow(title: L("电芯实时电压 (Voltage)"), value: "\(v) mV (\(String(format: "%.2f V", Double(v) / 1000.0)))")
                    }
                    if let a = latest.amperagemA {
                        let signHint = a >= 0 ? L("充电输入") : L("放电消耗")
                        metricRow(title: L("瞬时充放电电流 (\(signHint))"), value: "\(a) mA")
                    }
                    if let watts = latest.computedPowerWatts {
                        metricRow(
                            title: L("整机实时充放电功率"),
                            value: String(format: "%.2f W", abs(watts)),
                            accent: watts >= 0 ? .green : .blue
                        )
                    }
                    metricRow(title: L("最近快照采样时间"), value: formatDate(latest.timestamp))
                } header: {
                    HeaderLabel(L("物理电芯全维度指标 [测试]"), symbol: "battery.100percent.bolt")
                } footer: {
                    Text("提示：系统“设置 -> 电池健康”显示的百分比经过平滑校准算法修饰，而 AppleRawMaxCapacity 反映 PMU 电量计芯片测得的真实物理满电容量。")
                }
            }

            if !thermalEvents.isEmpty {
                Section {
                    ForEach(thermalEvents.prefix(12)) { ev in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.summary)
                                    .font(.subheadline.weight(.medium))
                                Text(formatDate(ev.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("等级 \(ev.levelCode)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(ev.levelCode >= 20 ? Color.orange : Color.secondary)
                        }
                    }
                } header: {
                    HeaderLabel(L("近期芯片温控与降频记录 [测试]"), symbol: "flame")
                }
            }

            if !recentBatterySamples.isEmpty {
                Section {
                    ForEach(recentBatterySamples.prefix(15)) { sample in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                let lvlText = sample.levelPercent.map { String(format: "%.0f%%", $0) } ?? "--%"
                                let tempText = sample.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "--°C"
                                Text("电量 \(lvlText) · 温度 \(tempText)")
                                    .font(.subheadline)
                                Text(formatDate(sample.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let watts = sample.computedPowerWatts {
                                Text(String(format: "%@%.2f W", watts >= 0 ? "+" : "-", abs(watts)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(watts >= 0 ? Color.green : Color.secondary)
                            }
                        }
                    }
                } header: {
                    HeaderLabel(L("近期电池采样流水（最近 15 条）"), symbol: "chart.xyaxis.line")
                }
            }
        }
        .navigationTitle("电池与温控遥测 [测试]")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if latestBattery != nil {
                    Button {
                        exportJSONReport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshTelemetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            liveThermalState = ProcessInfo.processInfo.thermalState
            if latestBattery == nil && !isLoading {
                refreshTelemetry()
            }
        }
    }

    @ViewBuilder
    private func metricRow(title: String, value: String, accent: Color = .primary) -> some View {
        HStack {
            Text(title.loc)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(accent)
        }
    }

    private func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return L("正常 (Nominal · 无降频)")
        case .fair: return L("温热 (Fair · 轻度温控)")
        case .serious: return L("发热降频 (Serious · 已锁帧/降频)")
        case .critical: return L("严重过热 (Critical · 强制限频降亮度)")
        @unknown default: return L("未知状态")
        }
    }

    private func thermalStateColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    private func refreshTelemetry() {
        isLoading = true
        statusBanner = L("正在挂载 CurrentPowerlog.PLSQL 只读快照...")
        liveThermalState = ProcessInfo.processInfo.thermalState
        Self.telemetryQueue.async {
            let wasActive = wq.hasActiveAccess(path: Self.powerlogDir)
            let grant = wq.grantAccess(path: Self.powerlogDir, requireWrite: false)
            defer {
                if !wasActive {
                    wq.releaseAccess(path: Self.powerlogDir)
                }
            }

            guard grant.0 && fm.isReadableFile(atPath: Self.powerlogDBPath) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.powerlogAccessible = false
                    self.statusBanner = L("当前固件未放行 systemgroup.com.apple.powerlog 只读扩展令牌（\(grant.2)）。上方芯片实时热状态仍可正常监测。")
                }
                return
            }

            do {
                let parsed = try SQLiteSnapshotHelper.withClonedDatabase(at: Self.powerlogDBPath) { db in
                    let batSamples = Self.queryBatterySamples(db: db)
                    let thermals = Self.queryThermalEvents(db: db)
                    return (batSamples, thermals)
                }
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.powerlogAccessible = true
                    self.recentBatterySamples = parsed.0
                    self.latestBattery = parsed.0.first
                    self.thermalEvents = parsed.1
                    if parsed.0.isEmpty {
                        self.statusBanner = L("已成功打开 Powerlog 快照，但未查询到近期电池采样表记录。")
                    } else {
                        self.statusBanner = L("已通过 APFS clonefile 无锁快照解析 \(parsed.0.count) 条近期电池记录与 \(parsed.1.count) 条温控记录。")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.powerlogAccessible = false
                    self.statusBanner = L("解析 Powerlog 快照异常：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func queryBatterySamples(db: OpaquePointer) -> [BatteryTelemetrySample] {
        let tables = SQLiteSnapshotHelper.allTables(in: db)
        let candidates = [
            "PLBatteryAgent_EventBackward_Battery",
            "PLBatteryAgent_EventForward_Battery",
            "PLBatteryAgent_EventBackward_BatteryUI"
        ]
        guard let tableName = candidates.first(where: { tables.contains($0) }) ?? tables.first(where: { $0.contains("PLBatteryAgent") && $0.hasSuffix("_Battery") }) else {
            return []
        }

        let cols = SQLiteSnapshotHelper.columnNames(in: tableName, db: db)
        guard cols.contains("timestamp") else { return [] }

        func pick(_ names: [String]) -> String {
            for n in names where cols.contains(n) {
                return "\"\(n)\""
            }
            return "NULL"
        }

        let sql = """
        SELECT timestamp,
               \(pick(["Level", "CurrentCapacity"])),
               \(pick(["AppleRawMaxCapacity", "RawMaxCapacity", "MaxCapacity"])),
               \(pick(["NominalChargeCapacity", "MaxCapacity"])),
               \(pick(["DesignCapacity"])),
               \(pick(["CycleCount"])),
               \(pick(["Voltage"])),
               \(pick(["InstantAmperage", "Amperage"])),
               \(pick(["Temperature"])),
               \(pick(["IsCharging"]))
        FROM "\(tableName)"
        ORDER BY timestamp DESC
        LIMIT 25;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let validStmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(validStmt) }

        var samples: [BatteryTelemetrySample] = []
        while sqlite3_step(validStmt) == SQLITE_ROW {
            guard let ts = SQLiteSnapshotHelper.doubleCol(validStmt, 0) else { continue }
            let rawTemp = SQLiteSnapshotHelper.doubleCol(validStmt, 8)
            let normalizedTemp: Double? = rawTemp.map { abs($0) > 120.0 ? ($0 / 100.0) : $0 }
            let chargingInt = SQLiteSnapshotHelper.intCol(validStmt, 9)

            samples.append(
                BatteryTelemetrySample(
                    id: UUID(),
                    timestamp: Date(timeIntervalSince1970: ts),
                    levelPercent: SQLiteSnapshotHelper.doubleCol(validStmt, 1),
                    rawMaxCapacitymAh: SQLiteSnapshotHelper.intCol(validStmt, 2),
                    nominalCapacitymAh: SQLiteSnapshotHelper.intCol(validStmt, 3),
                    designCapacitymAh: SQLiteSnapshotHelper.intCol(validStmt, 4),
                    cycleCount: SQLiteSnapshotHelper.intCol(validStmt, 5),
                    voltagemV: SQLiteSnapshotHelper.intCol(validStmt, 6),
                    amperagemA: SQLiteSnapshotHelper.intCol(validStmt, 7),
                    temperatureCelsius: normalizedTemp,
                    isCharging: chargingInt.map { $0 != 0 }
                )
            )
        }
        return samples
    }

    private static func queryThermalEvents(db: OpaquePointer) -> [ThermalTelemetryEvent] {
        let tables = SQLiteSnapshotHelper.allTables(in: db)
        let candidates = [
            "PLThermalAgent_EventPoint_ThermalStatus",
            "PLXPCAgent_EventPoint_ThermalLevel",
            "PLThermalMonitorAgent_EventPoint_ThermalLevel"
        ]
        guard let tableName = candidates.first(where: { tables.contains($0) }) ?? tables.first(where: { $0.localizedCaseInsensitiveContains("Thermal") && $0.contains("Event") }) else {
            return []
        }

        let cols = SQLiteSnapshotHelper.columnNames(in: tableName, db: db)
        guard cols.contains("timestamp") else { return [] }
        let levelCol = ["ThermalLevel", "thermalLevel", "Level", "State"].first(where: { cols.contains($0) })
        guard let levelCol else { return [] }

        let sql = "SELECT timestamp, \"\(levelCol)\" FROM \"\(tableName)\" ORDER BY timestamp DESC LIMIT 20;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let validStmt = stmt else {
            return []
        }
        defer { sqlite3_finalize(validStmt) }

        var out: [ThermalTelemetryEvent] = []
        while sqlite3_step(validStmt) == SQLITE_ROW {
            guard let ts = SQLiteSnapshotHelper.doubleCol(validStmt, 0),
                  let lvl = SQLiteSnapshotHelper.intCol(validStmt, 1) else { continue }
            let desc: String
            switch lvl {
            case ..<1: desc = L("散热恢复正常 (Nominal)")
            case 1...10: desc = L("轻度温控介入 (Light / Fair)")
            case 11...20: desc = L("中度降频限帧 (Moderate / Serious)")
            case 21...30: desc = L("重度性能限制与降亮度 (Heavy)")
            default: desc = L("过热保护阈值触发 (Critical)")
            }
            out.append(ThermalTelemetryEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: ts), levelCode: lvl, summary: desc))
        }
        return out
    }

    private func exportJSONReport() {
        struct ExportPayload: Codable {
            let exportedAt: Date
            let deviceModel: String
            let osBuild: String
            let latestBattery: BatteryTelemetrySample?
            let recentSamples: [BatteryTelemetrySample]
            let thermalEvents: [ThermalTelemetryEvent]
        }
        let payload = ExportPayload(
            exportedAt: Date(),
            deviceModel: machineName(),
            osBuild: buildNumber(),
            latestBattery: latestBattery,
            recentSamples: recentBatterySamples,
            thermalEvents: thermalEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            let outURL = fm.temporaryDirectory.appendingPathComponent("Erosion_PowerTelemetry_\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: outURL, options: .atomic)
            presentShareSheet(with: outURL)
        }
    }
}
