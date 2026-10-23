import SwiftUI
import UIKit

@MainActor
private enum StreamingIdleTimerController {
    private static var holderCount = 0

    static func acquire() {
        holderCount += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holderCount = max(0, holderCount - 1)
        if holderCount == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct StreamingIdleTimerModifier: ViewModifier {
    @State private var isHoldingIdleTimer = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isHoldingIdleTimer else { return }
                isHoldingIdleTimer = true
                StreamingIdleTimerController.acquire()
            }
            .onDisappear {
                guard isHoldingIdleTimer else { return }
                isHoldingIdleTimer = false
                StreamingIdleTimerController.release()
            }
    }
}

extension View {
    func preventsTVOSScreenSaverDuringStream() -> some View {
        modifier(StreamingIdleTimerModifier())
    }
}
