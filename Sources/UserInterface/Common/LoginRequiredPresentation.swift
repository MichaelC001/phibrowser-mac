// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

enum LoginRequiredSurface {
    case newTabPage
    case aiChat
    case browserMemory
    case connectors
    case imChannels
}

enum LoginRequiredPresentationPolicy {
    static func shouldPresent(
        for surface: LoginRequiredSurface,
        isGuest: Bool,
        isPhiAIEnabled: Bool
    ) -> Bool {
        guard isGuest else { return false }

        switch surface {
        case .newTabPage, .aiChat:
            return isPhiAIEnabled
        case .browserMemory, .connectors, .imChannels:
            return true
        }
    }

    static func isBrowserMemoryURL(_ rawURL: String?) -> Bool {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "chrome" || scheme == "phi" else {
            return false
        }
        return components.host?.lowercased() == "memory"
    }
}

struct LoginRequiredPresentationView: View {
    enum Layout {
        case embedded
        case overlay
    }

    let layout: Layout
    let loginAction: () -> Void

    init(
        layout: Layout = .embedded,
        loginAction: @escaping () -> Void = {
            Task { @MainActor in
                LoginController.shared.showLoginWindow()
            }
        }
    ) {
        self.layout = layout
        self.loginAction = loginAction
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(NSLocalizedString(
                "accountRequired.phiAI.title",
                value: "Sign in to use Phi AI",
                comment: "Account-required presentation - Title shown when a Guest opens a Phi AI feature"
            ))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color(nsColor: .labelColor))

            Text(NSLocalizedString(
                "accountRequired.phiAI.detail",
                value: "This feature requires a Phi account.",
                comment: "Account-required presentation - Detail shown when a Guest opens a Phi AI feature"
            ))
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            Button(action: loginAction) {
                Text(NSLocalizedString(
                    "accountRequired.phiAI.loginButton",
                    value: "Sign in",
                    comment: "Account-required presentation - Button that opens the Phi sign-in window"
                ))
                .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(
            maxWidth: .infinity,
            minHeight: layout == .overlay ? 220 : 156,
            maxHeight: layout == .overlay ? .infinity : 156
        )
        .background(
            layout == .overlay
                ? Color(nsColor: .windowBackgroundColor)
                : Color.clear
        )
    }
}

final class LoginRequiredOverlayView: NSView {
    init(loginAction: @escaping () -> Void = {
        Task { @MainActor in
            LoginController.shared.showLoginWindow()
        }
    }) {
        super.init(frame: .zero)
        wantsLayer = true

        let hostingView = NSHostingView(
            rootView: LoginRequiredPresentationView(
                layout: .overlay,
                loginAction: loginAction
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
