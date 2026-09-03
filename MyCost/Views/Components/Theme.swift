import SwiftUI

/// Lightweight design system — one place for the accent, semantic colours and
/// the reusable row/tile chrome so screens stop looking like stock `Form`s.
enum Theme {
    /// App accent: a confident indigo that holds up on light and dark.
    static let accent = Color(light: 0x4B44D8, dark: 0x9B95FF)
    /// Refunds / credits / "money coming back".
    static let positive = Color(light: 0x0F9D58, dark: 0x37D399)
    static let warning = Color.orange

    static let cardCornerRadius: CGFloat = 18
    static let tileCornerRadius: CGFloat = 14
}

// MARK: - Colour helpers

extension Color {
    /// `#RRGGBB` / `#RRGGBBAA` (leading `#` optional), or `nil` if unparseable.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard let value = UInt64(cleaned, radix: 16) else { return nil }
        switch cleaned.count {
        case 8:
            self.init(.sRGB,
                      red: Double((value >> 24) & 0xFF) / 255,
                      green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255,
                      opacity: Double(value & 0xFF) / 255)
        case 6:
            self.init(.sRGB,
                      red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255,
                      opacity: 1)
        default:
            return nil
        }
    }

    /// A dynamic colour that resolves per light/dark trait.
    init(light: UInt32, dark: UInt32) {
        self = Color(uiColor: UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Reusable chrome

/// SF Symbol in a soft tinted rounded square — the leading glyph for rows/tiles.
struct IconBadge: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A labelled metric row: leading `IconBadge`, title (+ optional caption),
/// trailing value.
struct MetricTile: View {
    let title: String
    let value: String
    var systemImage: String
    var tint: Color = Theme.accent
    var caption: String?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

extension View {
    /// Hide the stock grouped-list backdrop and lay a soft themed wash.
    func themedListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.10), Color(.systemGroupedBackground)],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            )
    }

    /// Wrap custom row content as a rounded card. Pair with
    /// `.listRowBackground(Color.clear)` + `.listRowSeparator(.hidden)`.
    func cardSurface(_ padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
            )
    }
}
