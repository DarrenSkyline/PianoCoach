import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = PracticeSession()
    @StateObject private var library = ScoreLibrary()
    @State private var showSettings = false
    @State private var showImporter = false

    private var isBusy: Bool { session.phase == .playing }

    var body: some View {
        VStack(spacing: 10) {
            controls
            ScrollView {
                StaffView(score: session.score,
                          activeHand: session.hand,
                          results: session.results,
                          currentNoteIDs: Set(session.currentStep.map(\.id)))
                    .padding(.horizontal, 4)
            }

            legend
            statusBar
            transport
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: Binding(
            get: { session.phase == .finished },
            set: { if !$0 { session.reset() } })
        ) {
            if let summary = session.summary {
                SummaryView(summary: summary, title: session.score.title, hand: session.hand,
                            onRetry: { session.reset(); session.start() },
                            onClose: { session.reset() })
                    .presentationDetents([.medium])
            }
        }
        .alert("需要麦克风权限", isPresented: $session.micDenied) {
            Button("好") {}
        } message: {
            Text("请在 设置 → PianoCoach 中允许使用麦克风，App 才能听到孩子弹的音。录音只在手机上实时分析，不会保存或上传。")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                session.score = try library.importFile(at: url)
            } catch {
                session.errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("好") {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    // MARK: 顶部设置

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    Section("示例曲目") {
                        ForEach(SampleScores.all) { score in
                            Button(score.title) { session.score = score }
                        }
                    }
                    if !library.imported.isEmpty {
                        Section("我导入的") {
                            ForEach(library.imported) { score in
                                Button(score.title) { session.score = score }
                            }
                        }
                    }
                    Section {
                        Button {
                            showImporter = true
                        } label: {
                            Label("导入 MusicXML…", systemImage: "square.and.arrow.down")
                        }
                        if library.contains(session.score) {
                            Button(role: .destructive) {
                                library.remove(session.score)
                                session.score = SampleScores.twinkle
                            } label: {
                                Label("删除《\(session.score.title)》", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Label(session.score.title, systemImage: "music.note.list")
                        .font(.headline)
                }
                .disabled(isBusy)
                Spacer()
                Button { showSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }

            Picker("练习的手", selection: $session.hand) {
                Text("右手").tag(Hand.right)
                Text("左手").tag(Hand.left)
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)

            Text("双手同时弹奏的检测还在开发中，目前请左右手分开练。和弦弹对其中一个音即可。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("速度 \(Int(session.bpm))")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 70, alignment: .leading)
                Slider(value: $session.bpm, in: 40...120, step: 1)
                    .disabled(isBusy)
            }

            if showSettings {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("延迟校准 \(Int(session.calibration * 1000)) ms")
                            .font(.footnote.monospacedDigit())
                        Slider(value: $session.calibration, in: -0.15...0.15, step: 0.01)
                            .disabled(isBusy)
                    }
                    Text("如果总是显示\"早了\"，往右调；总是\"晚了\"，往左调。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// .musicxml / .mxl 没有系统内置类型，按扩展名生成；.xml 用系统类型
    private static let importTypes: [UTType] =
        ["musicxml", "mxl"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) } + [.xml]

    // MARK: 图例 / 状态 / 按钮

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.accentColor, "待弹")
            legendItem(.green, "正确")
            legendItem(.red, "弹错")
            legendItem(.gray, "未弹")
        }
        .font(.caption)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    private var statusBar: some View {
        HStack {
            Label("听到：\(session.liveNote)", systemImage: "ear")
                .font(.subheadline.monospacedDigit())
            Spacer()
            ProgressView(value: Double(session.level))
                .frame(width: 90)
        }
        .padding(.horizontal, 4)
    }

    private var transport: some View {
        Button {
            if isBusy { session.stop() } else { session.start() }
        } label: {
            Text(isBusy ? "停止" : "开始练习")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(isBusy ? .red : .accentColor)
    }
}

// MARK: 总结页

struct SummaryView: View {
    let summary: PracticeSummary
    let title: String
    let hand: Hand
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("\(title) · \(hand.title)").font(.headline)
            HStack(spacing: 24) {
                stat("音准", summary.pitchAccuracy)
            }
            Text("正确 \(summary.correct)　弹错 \(summary.wrong)　漏弹 \(summary.missed)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !summary.worstBars.isEmpty {
                Text("建议重点练：第 \(summary.worstBars.map(String.init).joined(separator: "、")) 小节")
                    .font(.subheadline)
            } else {
                Text("全部正确，太棒了！🎉").font(.subheadline)
            }
            HStack {
                Button("关闭", action: onClose).buttonStyle(.bordered)
                Button("再弹一遍", action: onRetry).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func stat(_ name: String, _ value: Double) -> some View {
        VStack {
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text(name).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
