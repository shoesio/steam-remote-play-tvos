import SwiftUI

struct AppActionButtonStyle: ButtonStyle {
    enum Tone: Equatable {
        case primary
        case secondary
        case destructive
    }

    @Environment(\.colorScheme) private var colorScheme

    let tone: Tone
    var minWidth: CGFloat = 180

    private var foreground: Color {
        switch tone {
        case .primary:
            return colorScheme == .dark ? .white : .black
        case .secondary:
            return .primary
        case .destructive:
            return .red
        }
    }

    private var wash: Color {
        switch tone {
        case .primary:
            return colorScheme == .dark ? .white.opacity(0.22) : .white.opacity(0.58)
        case .secondary:
            return .white.opacity(colorScheme == .dark ? 0.08 : 0.34)
        case .destructive:
            return .red.opacity(colorScheme == .dark ? 0.16 : 0.11)
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary:
            return .white.opacity(colorScheme == .dark ? 0.48 : 0.72)
        case .secondary:
            return .white.opacity(colorScheme == .dark ? 0.20 : 0.52)
        case .destructive:
            return .red.opacity(0.38)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(minWidth: minWidth, minHeight: 50)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(wash))
                    .shadow(color: .black.opacity(0.18), radius: tone == .primary ? 18 : 8, y: tone == .primary ? 8 : 4)
            )
            .overlay {
                Capsule()
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .brightness(configuration.isPressed ? -0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassBadge: View {
    let text: String
    var systemImage: String? = nil
    var tone: AppActionButtonStyle.Tone = .secondary

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        switch tone {
        case .primary: return .white.opacity(colorScheme == .dark ? 0.82 : 0.55)
        case .secondary: return .white.opacity(colorScheme == .dark ? 0.34 : 0.55)
        case .destructive: return .red.opacity(0.55)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(accent.opacity(tone == .primary ? 0.20 : 0.10)))
        )
        .overlay {
            Capsule()
                .strokeBorder(accent, lineWidth: 1)
        }
    }
}
