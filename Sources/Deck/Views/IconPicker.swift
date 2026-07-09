import SwiftUI
import AppKit

// MARK: - IconView — tüm uygulamanın ortak ikon görseli

struct IconView: View {
    let spec: IconSpec
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [spec.color.opacity(0.95), spec.color.opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
            if spec.isEmoji {
                Text(spec.symbol)
                    .font(.system(size: size * 0.52))
            } else {
                Image(systemName: spec.symbol.isEmpty ? "questionmark" : spec.symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
    }
}

// MARK: - Claude ikonu (orijinal marka görünümü: krem zemin + mercan sunburst)

struct ClaudeIconView: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: "#F0EEE4"), Color(hex: "#E7E3D6")],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )
            ClaudeSunburst()
                .fill(Color(hex: "#D97757"))
                .frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
    }
}

/// Claude'un sunburst sembolü: merkezden dışa uzanan, uçları yuvarlatılmış
/// kalınca "ışık patlaması" ışınları (dolu şekil — çizgi değil, daha tanınır).
struct ClaudeSunburst: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOut = min(rect.width, rect.height) / 2
        let rays = 11
        let halfW = (2 * .pi / CGFloat(rays)) * 0.19   // ışın yarı-genişliği (açı)
        var p = Path()
        for i in 0..<rays {
            let a = (CGFloat(i) / CGFloat(rays)) * 2 * .pi - .pi / 2
            // Merkeze yakın dar taban → dışta yuvarlak uç (damla/ışın formu).
            let baseR = rOut * 0.14
            let tipR = rOut * (i % 2 == 0 ? 1.0 : 0.82)
            let bl = CGPoint(x: c.x + cos(a - halfW) * baseR, y: c.y + sin(a - halfW) * baseR)
            let br = CGPoint(x: c.x + cos(a + halfW) * baseR, y: c.y + sin(a + halfW) * baseR)
            let tl = CGPoint(x: c.x + cos(a - halfW * 0.5) * tipR, y: c.y + sin(a - halfW * 0.5) * tipR)
            let tr = CGPoint(x: c.x + cos(a + halfW * 0.5) * tipR, y: c.y + sin(a + halfW * 0.5) * tipR)
            let tip = CGPoint(x: c.x + cos(a) * (tipR + rOut * 0.05), y: c.y + sin(a) * (tipR + rOut * 0.05))
            p.move(to: bl)
            p.addLine(to: tl)
            p.addQuadCurve(to: tr, control: tip)
            p.addLine(to: br)
            p.closeSubpath()
        }
        // Merkez göbek.
        p.addEllipse(in: CGRect(x: c.x - rOut * 0.16, y: c.y - rOut * 0.16,
                                width: rOut * 0.32, height: rOut * 0.32))
        return p
    }
}

// MARK: - IconPicker — sembol/emoji + renk seçimi

struct IconPicker: View {
    @Binding var spec: IconSpec

    private enum Mode: String, CaseIterable {
        case symbols = "Symbols"
        case emoji = "Emoji"
    }

    @State private var mode: Mode
    @State private var customSymbol: String
    @State private var emojiText: String

    init(spec: Binding<IconSpec>) {
        _spec = spec
        let s = spec.wrappedValue
        _mode = State(initialValue: s.isEmoji ? .emoji : .symbols)
        _customSymbol = State(initialValue: s.isEmoji ? "" : s.symbol)
        _emojiText = State(initialValue: s.isEmoji ? s.symbol : "")
    }

    static let palette: [String] = [
        "#D97757", "#F97066", "#F7B955", "#3DDC84", "#2DD4BF",
        "#38BDF8", "#5E8DF7", "#B47CF7", "#F472B6", "#94A3B8"
    ]

    private static let symbols: [String] = [
        // süreç / çalışma
        "play.fill", "stop.fill", "arrow.clockwise", "arrow.triangle.2.circlepath",
        "power", "bolt.fill", "sparkles", "timer",
        // sunucu / ağ
        "server.rack", "network", "wifi", "antenna.radiowaves.left.and.right",
        "externaldrive.fill", "internaldrive.fill", "cylinder.split.1x2.fill", "cloud.fill", "globe",
        // kod / araç
        "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer.fill", "wrench.adjustable.fill", "command", "gearshape.fill", "slider.horizontal.3",
        // dosya / veri
        "doc.text.fill", "folder.fill", "archivebox.fill", "shippingbox.fill",
        "cube.fill", "square.stack.3d.up.fill", "tray.full.fill", "tablecells.fill",
        // web / bağlantı
        "safari.fill", "link", "bookmark.fill", "tag.fill", "magnifyingglass", "paperplane.fill",
        // durum
        "checkmark.circle.fill", "exclamationmark.triangle.fill", "flag.fill", "star.fill", "heart.fill",
        // yapay zekâ / donanım
        "brain.head.profile", "cpu.fill", "memorychip.fill", "waveform",
        // iletişim / medya
        "envelope.fill", "message.fill", "bubble.left.fill", "video.fill", "music.note", "camera.fill",
        // cihaz
        "laptopcomputer", "desktopcomputer", "iphone", "display",
        // grafik
        "chart.bar.fill", "chart.line.uptrend.xyaxis", "speedometer",
        // çeşitli
        "house.fill", "building.2.fill", "lock.fill", "key.fill",
        "leaf.fill", "flame.fill", "drop.fill", "moon.fill", "sun.max.fill",
        "paintbrush.fill", "gamecontroller.fill", "trophy.fill"
    ]

    private static let quickEmojis: [String] = [
        "🚀", "🔥", "⚡️", "✨", "🧠", "🤖", "🌐", "🛠️",
        "📦", "🗄️", "🐘", "🐳", "🐍", "☕️", "🎯", "💡",
        "🧪", "📡", "🖥️", "📊", "🔑", "🧱", "🌙", "⭐️"
    ]

    private static let gridColumns: [GridItem] = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                IconView(spec: spec, size: 44)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if mode == .symbols {
                symbolSection
            } else {
                emojiSection
            }

            colorRow
        }
        .padding(14)
        .frame(width: 356)
    }

    // MARK: Semboller

    private var symbolSection: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { name in
                        symbolButton(name)
                    }
                }
                .padding(2)
            }
            .frame(height: 208)

            HStack(spacing: 6) {
                TextField("SF Symbol name", text: $customSymbol)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                if symbolExists(customSymbol) {
                    Image(systemName: customSymbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Button("Use") { pickSymbol(customSymbol) }
                    .controlSize(.small)
                    .disabled(!symbolExists(customSymbol))
            }
        }
    }

    private func symbolButton(_ name: String) -> some View {
        let selected = !spec.isEmoji && spec.symbol == name
        return Button {
            pickSymbol(name)
        } label: {
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? spec.color.opacity(0.8) : Color.secondary.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func symbolExists(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return NSImage(systemSymbolName: t, accessibilityDescription: nil) != nil
    }

    private func pickSymbol(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard symbolExists(t) else { return }
        spec.symbol = t
        spec.isEmoji = false
        customSymbol = t
    }

    // MARK: Emoji

    private var emojiSection: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: Self.gridColumns, spacing: 6) {
                    ForEach(Self.quickEmojis, id: \.self) { e in
                        Button {
                            pickEmoji(e)
                        } label: {
                            Text(e)
                                .font(.system(size: 20))
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(spec.isEmoji && spec.symbol == e
                                              ? spec.color.opacity(0.5)
                                              : Color.secondary.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
            }
            .frame(height: 118)

            HStack(spacing: 6) {
                TextField("Type an emoji", text: $emojiText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onChange(of: emojiText) { _, newValue in
                        guard let last = newValue.trimmingCharacters(in: .whitespaces).last else { return }
                        let e = String(last)
                        if emojiText != e { emojiText = e }
                        spec.symbol = e
                        spec.isEmoji = true
                    }
                Text("Only one character is used")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pickEmoji(_ e: String) {
        spec.symbol = e
        spec.isEmoji = true
        emojiText = e
    }

    // MARK: Renk paleti

    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(Self.palette, id: \.self) { hex in
                let selected = spec.colorHex.uppercased() == hex.uppercased()
                Button {
                    spec.colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0.15),
                                                  lineWidth: selected ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
