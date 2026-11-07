import SwiftUI

enum DS {
    static let cardRadius: CGFloat = 14
    static let cardFill = Color(nsColor: .textBackgroundColor).opacity(0.55)
    static let stroke = Color.primary.opacity(0.08)
    static let width: CGFloat = 340
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.cardFill))
            .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.stroke))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(DS.stroke).frame(height: 1).padding(.horizontal, 14)
    }
}

struct Row<Trailing: View>: View {
    var icon: String
    var tint: Color = .secondary
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 11 : 8)
    }
}

extension Row where Trailing == EmptyView {
    init(icon: String, tint: Color = .secondary, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Value: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 150, alignment: .trailing)
    }
}

struct SectionHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            accessory
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

struct TabItem<T: Hashable>: Identifiable {
    let tag: T
    let icon: String
    let help: String
    var id: String { icon }
}

struct IconTabBar<T: Hashable>: View {
    let items: [TabItem<T>]
    @Binding var selection: T
    var showLabels = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = item.tag == selection
                Button { selection = item.tag } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: showLabels ? 15 : 17))
                        if showLabels {
                            Text(item.help).font(.system(size: 10, weight: .medium))
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .frame(height: showLabels ? 46 : 38)
                        .foregroundStyle(selected ? Brand.indigo : Color.primary.opacity(0.7))
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selected ? Brand.indigo.opacity(0.13) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.cardFill))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.stroke))
    }
}

struct FooterButton: View {
    var title: String
    var icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13.5))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Filled brand-color footer button, same size as FooterButton.
struct FooterPrimaryButton: View {
    var title: String
    var icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.gradient))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryButton: View {
    var title: String
    var icon: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.gradient))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LevelBar: View {
    var value: Float
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(6, geo.size.width * CGFloat(value)))
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.1), value: value)
    }
}

struct Sparkline: View {
    var values: [Float]
    var tint: Color

    static func smooth(_ points: [CGPoint], into path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        if let last = points.last { path.addLine(to: last) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: h - CGFloat(v) * (h - 4) - 2)
            }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1))
                    p.addLine(to: CGPoint(x: w, y: 1))
                }
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    Self.smooth(points, into: &p)
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))

                Path { p in Self.smooth(points, into: &p) }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The app's mark: a rounded waveform in the brand gradient.
struct LogoMark: View {
    var size: CGFloat = 40
    private let heights: [CGFloat] = [0.3, 0.58, 0.9, 0.62, 1.0, 0.7, 0.44, 0.26]

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.075) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().frame(width: size * 0.1, height: size * heights[i])
            }
        }
        .frame(height: size)
        .foregroundStyle(Brand.gradient)
    }
}

enum Brand {
    static let indigo = Color(red: 0.36, green: 0.33, blue: 0.96)
    static let violet = Color(red: 0.62, green: 0.30, blue: 0.93)
    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}
