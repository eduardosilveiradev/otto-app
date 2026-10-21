import SwiftUI

// MARK: - Model (`GET /app/stamps`, otto/stamps.ts)

struct StampPlace: Codable, Hashable {
    let name: String
    let kind: String
    let status: String
    var recommendedBy: String?
    var note: String?
}

struct TravelStamp: Codable, Identifiable, Hashable {
    let id: String
    var city: String?
    var code: String?
    var country: String?
    let first: String
    let last: String
    let visits: Int
    var places: [StampPlace] = []

    /// "ITALY", in the language the phone reads.
    var countryName: String? { country.flatMap { Locale.current.localizedString(forRegionCode: $0) }?.uppercased() }
    var headline: String { city ?? code ?? id }
}

struct StampsReply: Decodable { let stamps: [TravelStamp] }

// MARK: - The page

/// Every city they've landed in or stayed in, as the stamps a passport page would carry.
/// Tapping one shows what they saved there.
struct PassportScreen: View {
    @Environment(OttoStore.self) private var store
    @State private var stamps: [TravelStamp]?
    @State private var open: TravelStamp?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            if let stamps {
                VStack(alignment: .leading, spacing: 18) {
                    Text(summary(stamps))
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.6)
                    if stamps.isEmpty {
                        Text("No stamps yet. Forward Otto a booking, or tell it about a place you've been, and the first one lands here.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(stamps.enumerated()), id: \.element.id) { i, s in
                            Button { open = s } label: { InkStamp(stamp: s, index: i) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(s.headline), \(s.countryName ?? ""), first visited \(s.first)")
                        }
                    }
                }
                .padding(16)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(PaperBackground())
        .navigationTitle("Passport")
        .navigationBarTitleDisplayMode(.inline)
        .task { stamps = await store.backend.stamps()?.stamps ?? stamps ?? [] }
        .refreshable { if let s = await store.backend.stamps()?.stamps { stamps = s } }
        .sheet(item: $open) { StampDetail(stamp: $0) }
    }

    private func summary(_ s: [TravelStamp]) -> String {
        let countries = Set(s.compactMap(\.country)).count
        return "\(s.count) \(s.count == 1 ? "city" : "cities") · \(countries) \(countries == 1 ? "country" : "countries")"
    }
}

/// Faint security-paper guilloche behind the stamps.
private struct PaperBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { ctx, size in
            let ink = Color.primary.opacity(scheme == .dark ? 0.05 : 0.04)
            var y: CGFloat = 0
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                stride(from: 0, through: size.width, by: 6).forEach { x in
                    p.addLine(to: CGPoint(x: x, y: y + 5 * sin(x / 22 + y / 40)))
                }
                ctx.stroke(p, with: .color(ink), lineWidth: 0.7)
                y += 14
            }
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea()
    }
}

// MARK: - One stamp

/// Drawn, not an image: a shape, an ink and a tilt picked from the city itself, so the same
/// city always gets the same stamp and neighbours never match.
struct InkStamp: View {
    let stamp: TravelStamp
    let index: Int
    @Environment(\.colorScheme) private var scheme

    private var seed: UInt64 { stamp.id.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 } }
    private var ink: Color {
        let inks: [Color] = [Color(red: 0.12, green: 0.27, blue: 0.62), Color(red: 0.55, green: 0.12, blue: 0.2),
                             Color(red: 0.1, green: 0.42, blue: 0.3), Color(red: 0.36, green: 0.2, blue: 0.55), Color(red: 0.72, green: 0.33, blue: 0.08)]
        return inks[Int(seed % UInt64(inks.count))]
    }
    private var shape: Int { Int((seed >> 8) % 3) }
    private var tilt: Double { Double(Int((seed >> 16) % 19) - 9) }

    var body: some View {
        ZStack {
            outline
            VStack(spacing: 3) {
                if let c = stamp.countryName {
                    Text(c).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5).lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(stamp.code ?? String(stamp.headline.prefix(3)).uppercased())
                    .font(.system(size: 30, weight: .black, design: .rounded))
                if stamp.code != nil, let city = stamp.city {
                    Text(city.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                } else if stamp.code == nil {
                    Text(stamp.headline.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(Self.date(stamp.first)).font(.system(size: 10, weight: .bold, design: .monospaced))
                if stamp.visits > 1 {
                    Text("× \(stamp.visits)").font(.system(size: 9, weight: .bold, design: .monospaced))
                }
            }
            .padding(.horizontal, 18)
        }
        .foregroundStyle(ink)
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        // A real stamp never inks evenly.
        .mask(Speckle(seed: seed))
        .opacity(0.88)
        // The same inks read darker on night paper; lift them rather than pick new ones.
        .brightness(scheme == .dark ? 0.2 : 0)
        .rotationEffect(.degrees(tilt))
        .padding(6)
        .contentShape(.rect)
    }

    @ViewBuilder private var outline: some View {
        switch shape {
        case 0:
            ZStack { Circle().strokeBorder(lineWidth: 3); Circle().strokeBorder(lineWidth: 1).padding(6) }
                .frame(width: 138, height: 138)
        case 1:
            ZStack {
                RoundedRectangle(cornerRadius: 10).strokeBorder(lineWidth: 3)
                RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).padding(6)
            }
            .frame(width: 150, height: 120)
        default:
            ZStack { Ellipse().strokeBorder(lineWidth: 3); Ellipse().strokeBorder(lineWidth: 1).padding(6) }
                .frame(width: 158, height: 118)
        }
    }

    static func date(_ ymd: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: ymd) else { return ymd }
        let o = DateFormatter(); o.dateFormat = "dd MMM yyyy"; o.locale = Locale(identifier: "en_US_POSIX")
        return o.string(from: d).uppercased()
    }
}

/// Mostly solid with gaps where the ink didn't take, seeded per stamp.
private struct Speckle: View {
    let seed: UInt64
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            var s = seed | 1
            func next() -> CGFloat { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return CGFloat(s % 10_000) / 10_000 }
            ctx.blendMode = .destinationOut
            for _ in 0..<Int(size.width * size.height / 90) {
                let r = 0.6 + next() * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: next() * size.width, y: next() * size.height, width: r, height: r)), with: .color(.black))
            }
        }
    }
}

// MARK: - What's saved there

private struct StampDetail: View {
    let stamp: TravelStamp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    InkStamp(stamp: stamp, index: 0)
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    LabeledContent("First visit", value: InkStamp.date(stamp.first).capitalized)
                    if stamp.visits > 1 { LabeledContent("Latest", value: InkStamp.date(stamp.last).capitalized) }
                    LabeledContent("Visits", value: "\(stamp.visits)")
                }
                Section("Saved here") {
                    if stamp.places.isEmpty {
                        Text("Nothing saved here yet. Tell Otto about a place and it shows up on this stamp.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(stamp.places, id: \.self) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(p.name).font(.body.weight(.semibold))
                                if p.status == "loved" { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
                                if p.status == "avoid" { Image(systemName: "hand.thumbsdown.fill").font(.caption).foregroundStyle(.secondary) }
                            }
                            if let n = p.note { Text(n).font(.subheadline) }
                            Text([p.kind, p.status == "want" ? "want to go" : nil, p.recommendedBy.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(stamp.headline)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
