// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// AI memory entry button. Reused in `SidebarBottomBar` (rounded rect hover) and
/// `WebContentHeader` trailing area (circular hover).
struct MemoryButton: View {
    let action: () -> Void
    var useCircularHoverShape: Bool = false

    @StateObject private var lottieState = LottieAnimationViewState()

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6

    var body: some View {
        let config = LottieAnimationViewConfig(
            animationName: "memory",
            size: CGSize(width: buttonSize, height: buttonSize),
            hoverBackgroundColor: Color.sidebarTabHovered,
            cornerRadius: useCircularHoverShape ? 999 : cornerRadius,
            animationTrigger: .onHoverEnter,
            themedTintColor: .custom(light: .black, dark: .white),
            reverseOnHoverExit: true
        )

        LottieAnimationView(config: config, state: lottieState, action: action)
            .help(NSLocalizedString("sidebar.memoryButton.helpText", value: "Browser Memory",
                comment: "Memory button - Tooltip & Accessibility label for the AI memory entry button shown in the sidebar bottom bar and the web content header trailing area"
            ))
            .accessibilityLabel(NSLocalizedString("sidebar.memoryButton.accessibilityLabel", value: "Browser Memory",
                comment: "Memory button - Tooltip & Accessibility label for the AI memory entry button shown in the sidebar bottom bar and the web content header trailing area"
            ))
    }
}
