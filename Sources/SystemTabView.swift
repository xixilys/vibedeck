import SwiftUI

/// System page instruments: one hue per subsystem, a live chart in every tile, readings sampled at the monitor’s current cadence.
struct SystemVitalsView: View {
    @ObservedObject var monitor = SystemMonitor.shared
    let report: ScanReport

    var body: some View {
        let s = monitor.latest, h = monitor.series
        VStack(alignment: .leading, spacing: 8) {
            cpuTile(s, h)
            HStack(alignment: .top, spacing: 8) {
                gpuTile(s, h).frame(maxHeight: .infinity)
                memoryTile(s, h).frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            sensors(s)
            diskTile(s, h)
        }
    }

    // MARK: CPU

    private func cpuTile(_ s: SystemSample, _ h: SystemSeries) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RingGauge(value: s.cpu, tint: Glass.load(s.cpu), lineWidth: 6)
                    VStack(spacing: -1) {
                        Text(s.cpu.map { String(format: "%.0f", $0 * 100) } ?? "—")
                            .font(.system(size: 17 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("%").font(VG.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56 * VG.scale, height: 56 * VG.scale)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CPU").font(VG.headline)
                            Text(String(format: L("负载 %.2f · %d 核", "Load %.2f · %d cores"), s.load1, s.cores.count))
                                .font(VG.caption).foregroundStyle(.secondary).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(SystemFormat.temperature(s.cpuTemp))
                                .font(.system(size: 20 * VG.scale, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Glass.thermal(s.cpuTemp)).fixedSize()
                            Text(L("平均核心温度", "Mean core temp")).font(VG.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                        .help(s.cpuTempMax.map { L("最高 ", "Hottest ") + SystemFormat.temperature($0) } ?? L("此机型未提供温度传感器", "No temperature sensors on this model"))
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            legend(Glass.cpu, L("用户", "User"), SystemFormat.percent(s.cpuUser))
                            legend(Glass.compressed, L("系统", "System"), SystemFormat.percent(s.cpuSystem))
                        }.fixedSize()
                        VStack(alignment: .leading, spacing: 3) {
                            legend(Glass.cpu, L("用户", "User"), SystemFormat.percent(s.cpuUser))
                            legend(Glass.compressed, L("系统", "System"), SystemFormat.percent(s.cpuSystem))
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                CoreBars(cores: s.cores, efficiencyCores: s.efficiencyCores)
                    .frame(width: max(60, CGFloat(s.cores.count) * 9 * VG.scale), height: 34)
                Sparkline(values: h.cpu, tint: Glass.cpu, ceiling: 1)
                    .frame(height: 34)
            }
            if s.efficiencyCores > 0 {
                HStack(spacing: 10) {
                    legend(Glass.efficiency, L("能效核", "E-cores"), "\(s.efficiencyCores)")
                    legend(Glass.cpu, L("性能核", "P-cores"), "\(max(0, s.cores.count - s.efficiencyCores))")
                    Spacer()
                    Text(L("近期 \(h.cpu.count) 个样本", "Recent \(h.cpu.count) samples")).font(VG.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .glassTile(tint: Glass.load(s.cpu))
    }

    // MARK: GPU · Memory

    /// Same reading order as the memory tile beside it (title · value, bar, detail, history); the ring stays CPU-only.
    private func gpuTile(_ s: SystemSample, _ h: SystemSeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("GPU").font(VG.headline)
                Spacer(minLength: 2)
                Text(SystemFormat.percent(s.gpu)).font(.system(size: 17 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
            }
            SegmentBar(parts: s.gpu.map { [SegmentBar.Part(id: L("利用率 ", "Utilization ") + SystemFormat.percent($0), value: max(0, min(1, $0)), tint: Glass.gpu)] } ?? [],
                       total: 1, height: 7)
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").foregroundStyle(Glass.thermal(s.gpuTemp))
                Text(s.gpuTemp != nil ? SystemFormat.temperature(s.gpuTemp) : L("温度未知", "Temp unknown"))
                    .foregroundStyle(s.gpuTemp != nil ? Glass.thermal(s.gpuTemp) : .secondary).monospacedDigit()
                Spacer(minLength: 2)
                Text(s.gpu == nil ? L("利用率未知", "Usage unknown") : L("利用率", "Utilization")).foregroundStyle(.tertiary)
            }
            .font(VG.caption).fixedSize(horizontal: false, vertical: true)
            Sparkline(values: h.gpu, tint: Glass.gpu, ceiling: 1).frame(height: 22)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassTile(tint: Glass.gpu, padding: 10)
        .accessibilityElement(children: .combine)
    }

    private func memoryTile(_ s: SystemSample, _ h: SystemSeries) -> some View {
        let pressure: (String, Color) = s.memPressure >= 4 ? (L("紧张", "Critical"), .red)
            : s.memPressure >= 2 ? (L("偏高", "Warning"), .orange) : (L("正常", "Normal"), Glass.memory)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L("内存", "Memory")).font(VG.headline)
                Spacer(minLength: 2)
                Text(SystemFormat.percent(s.memFraction)).font(.system(size: 17 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
            }
            SegmentBar(parts: [
                .init(id: L("应用 ", "App ") + SystemFormat.size(s.memApp), value: s.memApp, tint: Glass.memory),
                .init(id: L("联动 ", "Wired ") + SystemFormat.size(s.memWired), value: s.memWired, tint: Glass.wired),
                .init(id: L("压缩 ", "Compressed ") + SystemFormat.size(s.memCompressed), value: s.memCompressed, tint: Glass.compressed),
            ], total: s.memTotal, height: 7)
            HStack(spacing: 4) {
                Circle().fill(pressure.1).frame(width: 6, height: 6)
                Text(L("压力", "Pressure") + " " + pressure.0).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(SystemFormat.size(s.memUsed) + " / " + SystemFormat.size(s.memTotal)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(VG.caption).fixedSize(horizontal: false, vertical: true)
            .help(L("应用 \(SystemFormat.size(s.memApp)) · 联动 \(SystemFormat.size(s.memWired)) · 压缩 \(SystemFormat.size(s.memCompressed)) · 可回收缓存 \(SystemFormat.size(s.memCached)) · Swap \(SystemFormat.size(s.swapUsed))",
                    "App \(SystemFormat.size(s.memApp)) · wired \(SystemFormat.size(s.memWired)) · compressed \(SystemFormat.size(s.memCompressed)) · cached \(SystemFormat.size(s.memCached)) · swap \(SystemFormat.size(s.swapUsed))"))
            Sparkline(values: h.mem, tint: Glass.memory, ceiling: 1).frame(height: 22)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassTile(tint: pressure.1, padding: 10)
    }

    // MARK: Sensors

    private func sensors(_ s: SystemSample) -> some View {
        var pills: [(String, String, String, Color)] = []
        if s.cpuTempMax != nil { pills.append(("flame", L("CPU 最高", "CPU peak"), SystemFormat.temperature(s.cpuTempMax), Glass.thermal(s.cpuTempMax))) }
        if s.gpuTemp != nil { pills.append(("square.stack.3d.up", L("GPU 温度", "GPU temp"), SystemFormat.temperature(s.gpuTemp), Glass.thermal(s.gpuTemp))) }
        if s.ssdTemp != nil { pills.append(("internaldrive", L("SSD 温度", "SSD temp"), SystemFormat.temperature(s.ssdTemp), Glass.thermal(s.ssdTemp))) }
        if s.power != nil { pills.append(("bolt.fill", L("整机功耗", "System power"), SystemFormat.watts(s.power), Glass.power)) }
        for (index, rpm) in s.fans.enumerated() {
            pills.append(("fan", s.fans.count > 1 ? L("风扇 \(index + 1)", "Fan \(index + 1)") : L("风扇", "Fan"), "\(rpm) rpm", Glass.download))
        }
        if let battery = s.battery {
            pills.append((s.charging ? "battery.100.bolt" : "battery.75", L("电池", "Battery"), SystemFormat.percent(battery), battery < 0.2 ? .orange : Glass.memory))
        }
        let thermal = report.thermalStateString
        if thermal != "正常" && !thermal.isEmpty { pills.append(("thermometer.sun", L("热状态", "Thermal"), L(thermal, "Elevated"), .orange)) }
        return Group {
            if !pills.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: VG.scale > 1.1 ? 2 : 3), spacing: 6) {
                    ForEach(pills.indices, id: \.self) { index in
                        SensorPill(symbol: pills[index].0, title: pills[index].1, value: pills[index].2, tint: pills[index].3)
                    }
                }
            }
        }
    }

    // MARK: Disk

    private func diskTile(_ s: SystemSample, _ h: SystemSeries) -> some View {
        let usedFraction = report.diskTotalGB > 0 ? max(0, min(1, 1 - report.diskFreePct / 100)) : nil
        let low = report.diskTotalGB > 0 && report.diskFreePct < 10
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(Glass.disk)
                Text(L("磁盘", "Disk")).font(VG.headline)
                Spacer(minLength: 4)
                Text(report.diskTotalGB > 0 ? String(format: L("剩 %.0f GB · %.0f%%", "%.0f GB free · %.0f%%"), report.diskFreeGB, report.diskFreePct) : "—")
                    .font(VG.caption).monospacedDigit().foregroundStyle(low ? Color.orange : .secondary)
            }
            if let usedFraction {
                SegmentBar(parts: [.init(id: L("已用", "Used"), value: usedFraction, tint: low ? .orange : Glass.disk)], total: 1, height: 6)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    legend(Glass.download, L("读", "Read"), SystemFormat.rate(s.diskRead))
                    legend(Glass.upload, L("写", "Write"), SystemFormat.rate(s.diskWrite))
                }
                .frame(width: 120 * VG.scale, alignment: .leading)
                MirrorAreaChart(up: h.diskRead, down: h.diskWrite).frame(height: 30)
            }
        }
        .glassTile(tint: low ? .orange : Glass.disk)
    }

    private func legend(_ tint: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(VG.caption).lineLimit(1)
    }

}

/// Live interface throughput for the Network page.
struct NetworkTrafficTile: View {
    @ObservedObject var monitor = SystemMonitor.shared
    let interface: String

    var body: some View {
        let s = monitor.latest, h = monitor.series
        VStack(alignment: .leading, spacing: 8) {
            if VG.scale > 1.1 {
                HStack { Spacer(minLength: 0); interfaceBadge(s) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                rate(symbol: "arrow.down", tint: Glass.download, title: L("下行", "Down"), value: s.netIn)
                rate(symbol: "arrow.up", tint: Glass.upload, title: L("上行", "Up"), value: s.netOut)
                Spacer(minLength: 4)
                if VG.scale <= 1.1 { interfaceBadge(s) }
            }
            MirrorAreaChart(up: h.netIn, down: h.netOut).frame(height: 52)
            HStack {
                Text(L("接口累计", "Interface totals")).foregroundStyle(.tertiary)
                Text("↓ " + SystemFormat.networkSize(s.netCountersAvailable ? s.netTotalIn : nil)).foregroundStyle(Glass.download)
                Text("↑ " + SystemFormat.networkSize(s.netCountersAvailable ? s.netTotalOut : nil)).foregroundStyle(Glass.upload)
                Spacer()
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    .help(L("速率与累计均统计当前 en* 物理接口，包含局域网和远程挂载；不重复计入隧道、桥接和回环。累计从各接口计数器最近重置起算，非完整开机总量。", "Rates and totals cover current en* physical interfaces, including LAN and remote mounts; tunnels, bridges and loopback are excluded. Totals start at each interface counter reset, not necessarily boot."))
            }
            .font(VG.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        .glassTile(tint: Glass.download)
    }

    private func interfaceBadge(_ s: SystemSample) -> some View {
                Text(s.netInterfaces.isEmpty ? L("物理网卡", "Physical") : s.netInterfaces.count == 1 ? s.netInterfaces[0] : L("物理网卡 \(s.netInterfaces.count)", "Physical · \(s.netInterfaces.count)")).font(VG.caption.weight(.semibold))
                    .help(s.netInterfaces.isEmpty ? L("等待网卡采样", "Waiting for interface sampling") : s.netInterfaces.joined(separator: ", "))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func rate(symbol: String, tint: Color, title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10 * VG.scale, weight: .bold)).foregroundStyle(tint)
                Text(title).font(VG.caption).foregroundStyle(.secondary)
            }
            Text(SystemFormat.networkRate(value)).font(.system(size: 17 * VG.scale, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
    }
}
