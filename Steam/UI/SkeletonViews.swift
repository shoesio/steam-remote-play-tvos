import SwiftUI
import UIKit

extension Color {
    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
}

// MARK: - Shimmer ViewModifier

struct SkeletonShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let width = geo.size.width * 2.5
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.15), location: 0.4),
                            .init(color: .white.opacity(0.3), location: 0.5),
                            .init(color: .white.opacity(0.15), location: 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width)
                    .offset(x: phase * width)
                    .blendMode(.screen)
                }
                .clipped()
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(SkeletonShimmerModifier())
    }
}

// MARK: - Game Card Skeleton

struct GameCardSkeleton: View {
    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(2/3, contentMode: .fit)
            .shimmer()
    }
}
