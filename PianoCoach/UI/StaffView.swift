import SwiftUI

/// 大谱表（高音 + 低音）绘制，音符颜色随判定结果变化：
/// 绿 = 音对节奏对　橙 = 音对但节奏偏差　红 = 弹错　灰 = 漏弹
struct StaffView: View {
    let score: Score
    let activeHand: Hand
    let results: [Int: NoteResult]
    /// 当前待弹音符的 ScoreNote.id，nil 表示未开始或已结束
    let currentNoteID: Int?

    static let barsPerSystem = 2
    static let systemHeight: CGFloat = 235
    private let s: CGFloat = 9               // 谱线间距
    private let leftMargin: CGFloat = 46
    private let barPadding: CGFloat = 16

    private var systemCount: Int {
        Int(ceil(Double(score.barCount) / Double(Self.barsPerSystem)))
    }

    var body: some View {
        Canvas { ctx, size in
            drawAll(&ctx, size: size)
        }
        .frame(height: CGFloat(systemCount) * Self.systemHeight)
    }

    // MARK: 布局

    private func trebleTop(system: Int) -> CGFloat { CGFloat(system) * Self.systemHeight + 52 }
    private func bassTop(system: Int) -> CGFloat { trebleTop(system: system) + 4 * s + 66 }

    private func barWidth(_ width: CGFloat) -> CGFloat {
        (width - leftMargin - 8) / CGFloat(Self.barsPerSystem)
    }

    private func x(forBeat beat: Double, width: CGFloat) -> CGFloat {
        let bar = Int(floor(beat / Double(score.beatsPerBar)))
        let beatInBar = beat - Double(bar) * Double(score.beatsPerBar)
        let barInSystem = bar % Self.barsPerSystem
        let bw = barWidth(width)
        let left = leftMargin + CGFloat(barInSystem) * bw
        return left + barPadding + CGFloat(beatInBar / Double(score.beatsPerBar)) * (bw - 2 * barPadding)
    }

    private func system(forBeat beat: Double) -> Int {
        Int(floor(beat / Double(score.beatsPerBar))) / Self.barsPerSystem
    }

    private func color(for note: ScoreNote) -> Color {
        guard note.hand == activeHand else { return Color.gray.opacity(0.35) }
        if currentNoteID == note.id { return Color.accentColor }  // 当前待弹：蓝色
        switch results[note.id]?.state ?? .pending {
        case .pending: return Color.primary
        case .correct: return Color.green
        case .timing:  return Color.orange
        case .wrong:   return Color.red
        case .missed:  return Color.gray
        }
    }

    // MARK: 绘制

    private func drawAll(_ ctx: inout GraphicsContext, size: CGSize) {
        let lineColor = Color.primary.opacity(0.55)

        for sys in 0..<systemCount {
            let tTop = trebleTop(system: sys)
            let bTop = bassTop(system: sys)
            let right = size.width - 8

            // 谱线
            for top in [tTop, bTop] {
                for k in 0..<5 {
                    var p = Path()
                    let y = top + CGFloat(k) * s
                    p.move(to: CGPoint(x: leftMargin - 6, y: y))
                    p.addLine(to: CGPoint(x: right, y: y))
                    ctx.stroke(p, with: .color(lineColor), lineWidth: 0.8)
                }
            }
            // 谱号与手标记
            ctx.draw(Text("𝄞").font(.system(size: 50)).foregroundColor(.primary),
                     at: CGPoint(x: 22, y: tTop + 2 * s), anchor: .center)
            ctx.draw(Text("𝄢").font(.system(size: 34)).foregroundColor(.primary),
                     at: CGPoint(x: 22, y: bTop + 1.6 * s), anchor: .center)
            ctx.draw(Text("右手").font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: 22, y: tTop - 14), anchor: .center)
            ctx.draw(Text("左手").font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: 22, y: bTop - 14), anchor: .center)

            // 系统起始线 + 小节线
            var start = Path()
            start.move(to: CGPoint(x: leftMargin - 6, y: tTop))
            start.addLine(to: CGPoint(x: leftMargin - 6, y: bTop + 4 * s))
            ctx.stroke(start, with: .color(lineColor), lineWidth: 1.2)

            let bw = barWidth(size.width)
            for b in 1...Self.barsPerSystem {
                let barIndex = sys * Self.barsPerSystem + b - 1
                guard barIndex < score.barCount else { break }
                let bx = leftMargin + CGFloat(b) * bw
                var p = Path()
                p.move(to: CGPoint(x: bx, y: tTop))
                p.addLine(to: CGPoint(x: bx, y: bTop + 4 * s))
                let isFinalBar = barIndex == score.barCount - 1
                ctx.stroke(p, with: .color(lineColor), lineWidth: isFinalBar ? 2 : 0.9)
            }
            // 每个小节的编号（标在小节开头上方）
            for b in 0..<Self.barsPerSystem {
                let barIndex = sys * Self.barsPerSystem + b
                guard barIndex < score.barCount else { break }
                ctx.draw(Text("\(barIndex + 1)").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: leftMargin + CGFloat(b) * bw + 8, y: tTop - 10), anchor: .center)
            }
        }

        // 播放位置光标（已移除，改用音符高亮圆圈）

        // 音符
        for note in score.notes {
            let sys = system(forBeat: note.beat)
            guard sys < systemCount else { continue }
            let nx = x(forBeat: note.beat, width: size.width)
            let top = note.hand == .right ? trebleTop(system: sys) : bassTop(system: sys)
            drawNote(&ctx, note: note, x: nx, staffTop: top, color: color(for: note),
                     detail: note.hand == activeHand ? results[note.id]?.detail : nil)
        }
    }

    private func drawNote(_ ctx: inout GraphicsContext, note: ScoreNote, x: CGFloat,
                          staffTop: CGFloat, color: Color, detail: String?) {
        let bottomLineY = staffTop + 4 * s
        let bottomDiatonic = note.hand == .right ? StaffPosition.trebleBottom : StaffPosition.bassBottom
        let pos = StaffPosition.make(midi: note.midi)
        let y = bottomLineY - CGFloat(pos.diatonic - bottomDiatonic) * s / 2
        let headW = s * 1.3
        let headH = s * 0.95
        let ledgerColor = Color.primary.opacity(0.55)

        // 当前待弹音符：高亮背景圆
        if currentNoteID == note.id {
            let r = headW * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Color.accentColor.opacity(0.18)))
        }

        // 加线
        var ly = staffTop - s
        while ly >= y - 0.5 {
            var p = Path()
            p.move(to: CGPoint(x: x - headW, y: ly)); p.addLine(to: CGPoint(x: x + headW, y: ly))
            ctx.stroke(p, with: .color(ledgerColor), lineWidth: 0.9)
            ly -= s
        }
        ly = bottomLineY + s
        while ly <= y + 0.5 {
            var p = Path()
            p.move(to: CGPoint(x: x - headW, y: ly)); p.addLine(to: CGPoint(x: x + headW, y: ly))
            ctx.stroke(p, with: .color(ledgerColor), lineWidth: 0.9)
            ly += s
        }

        // 升号
        if pos.sharp {
            ctx.draw(Text("♯").font(.system(size: 14)).foregroundColor(color),
                     at: CGPoint(x: x - headW - 6, y: y), anchor: .center)
        }

        // 符头
        let head = Path(ellipseIn: CGRect(x: x - headW / 2, y: y - headH / 2, width: headW, height: headH))
        if note.duration >= 2 {
            ctx.stroke(head, with: .color(color), lineWidth: 1.8)
        } else {
            ctx.fill(head, with: .color(color))
        }

        // 符干 + 符尾
        if note.duration < 4 {
            let up = y > staffTop + 2 * s       // 在中线以下 → 符干向上
            let sx = up ? x + headW / 2 - 0.5 : x - headW / 2 + 0.5
            let endY = up ? y - 3.4 * s : y + 3.4 * s
            var stem = Path()
            stem.move(to: CGPoint(x: sx, y: y))
            stem.addLine(to: CGPoint(x: sx, y: endY))
            ctx.stroke(stem, with: .color(color), lineWidth: 1.4)
            if note.duration <= 0.75 {
                var flag = Path()
                flag.move(to: CGPoint(x: sx, y: endY))
                flag.addQuadCurve(to: CGPoint(x: sx + 7, y: endY + (up ? 12 : -12)),
                                  control: CGPoint(x: sx + 8, y: endY + (up ? 3 : -3)))
                ctx.stroke(flag, with: .color(color), lineWidth: 1.4)
            }
        }

        // 附点
        if [0.75, 1.5, 3.0].contains(note.duration) {
            let dotY = (Int(round((y - bottomLineY) / (s / 2))) % 2 == 0) ? y - s / 2 : y
            ctx.fill(Path(ellipseIn: CGRect(x: x + headW / 2 + 3, y: dotY - 1.5, width: 3, height: 3)),
                     with: .color(color))
        }

        // 判定提示（"偏高"、"晚了"…）
        if let detail = detail, !detail.isEmpty {
            ctx.draw(Text(detail).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                     at: CGPoint(x: x, y: staffTop + (note.hand == .right ? -26 : 4 * s + 20)),
                     anchor: .center)
        }
    }
}
