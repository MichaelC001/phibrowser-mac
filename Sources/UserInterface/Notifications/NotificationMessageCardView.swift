// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import PostHog

@MainActor
private enum NotificationCardAnalytics {
    static func capture(_ action: String) {
        PostHogSDK.shared.capture("notification_card_action", properties: ["action": action])
    }
}

/// Tracks presentation while AppKit keeps the SwiftUI card mounted.
final class NotificationCardPresentation: ObservableObject {
    @Published var isPresented: Bool

    init(isPresented: Bool = true) {
        self.isPresented = isPresented
    }
}

// MARK: - Layout Mode

/// Layout mode for notification card view
/// Determines the stacking direction and rotation anchor for background cards
enum NotificationCardLayoutMode {
    /// Sidebar mode: card appears above the button, stacks toward top-left
    case sidebar
    /// Legacy mode: card appears below the button, stacks toward bottom-left
    case legacy
}

struct NotificationMessageCardView: View {
    @ObservedObject var manager: NotificationCardManager
    @State private var isHovered: Bool = false
    
    /// Layout mode determines stacking direction
    let layoutMode: NotificationCardLayoutMode

    @ObservedObject var presentation: NotificationCardPresentation

    var onChat: ((NotificationCardManager.Card) -> Void)?
    var onRun: ((NotificationCardManager.Card) -> Void)?
    var onDismiss: ((NotificationCardManager.Card) -> Void)?
    var onMute: ((NotificationCardManager.Card) -> Void)?
    var onDelete: ((NotificationCardManager.Card) -> Void)?

    /// Horizontal offset for stacked cards (negative = left)
    private let stackOffsetX: CGFloat = -6
    /// Vertical offset for stacked cards (depends on layout mode)
    private var stackOffsetY: CGFloat {
        layoutMode == .legacy ? 12 : -12
    }
    /// Rotation angle for background cards (depends on layout mode)
    private var stackRotation: Double {
        layoutMode == .legacy ? -2 : 2
    }
    /// Rotation anchor point (depends on layout mode)
    private var rotationAnchor: UnitPoint {
        layoutMode == .legacy ? .topTrailing : .bottomTrailing
    }
    /// Scale factor for background cards
    private let stackScale: CGFloat = 0.9
    /// Corner radius for cards
    private let cornerRadius: CGFloat = 8

    init(
        manager: NotificationCardManager = .shared,
        layoutMode: NotificationCardLayoutMode = .sidebar,
        presentation: NotificationCardPresentation = NotificationCardPresentation(),
        onChat: ((NotificationCardManager.Card) -> Void)? = nil,
        onRun: ((NotificationCardManager.Card) -> Void)? = nil,
        onDismiss: ((NotificationCardManager.Card) -> Void)? = nil,
        onMute: ((NotificationCardManager.Card) -> Void)? = nil,
        onDelete: ((NotificationCardManager.Card) -> Void)? = nil
    ) {
        self.manager = manager
        self.layoutMode = layoutMode
        self.presentation = presentation
        self.onChat = onChat
        self.onRun = onRun
        self.onDismiss = onDismiss
        self.onMute = onMute
        self.onDelete = onDelete
    }

    var body: some View {
        Group {
            if let currentCard = manager.currentCard {
                NotificationMessageCardContent(
                    card: currentCard,
                    totalCards: manager.allCards.count,
                    currentIndex: manager.currentIndex,
                    isHovered: isHovered,
                    isAnimating: presentation.isPresented,
                    onChat: onChat,
                    onRun: { card in
                        NotificationCardAnalytics.capture("run")
                        onRun?(card)
                    },
                    onDismiss: { card in
                        NotificationCardAnalytics.capture("dismiss")
                        onDismiss?(card)
                    },
                    onMute: onMute,
                    onDelete: { card in
                        NotificationCardAnalytics.capture("delete")
                        onDelete?(card)
                    },
                    onPrevious: { manager.showPrevious() },
                    onNext: { manager.showNext() }
                )
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notification.card")
                .background(
                    Group {
                        if manager.allCards.count > 1 {
                            stackedCardBackground
                        }
                    }
                )
                .shadow(
                    color: layoutMode == .legacy ? Color.black.opacity(0.15) : Color.clear,
                    radius: 8,
                    x: 0,
                    y: 4
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onChange(of: presentation.isPresented ? manager.currentCard?.id : nil, initial: true) { _, cardID in
            if cardID != nil {
                NotificationCardAnalytics.capture("show")
            }
        }
    }
    
    /// Stacked card background to show there are more cards
    private var stackedCardBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .themedFill(ThemedColor(lightHex: 0xF5F5F5, darkHex: 0x0A2230))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .themedStroke(.border)
            )
            .scaleEffect(stackScale)
            .rotationEffect(.degrees(stackRotation), anchor: rotationAnchor)
            .offset(x: stackOffsetX, y: stackOffsetY)
    }
}

struct NotificationMessageCardContent: View {
    let card: NotificationCardManager.Card
    let totalCards: Int
    let currentIndex: Int
    let isHovered: Bool
    /// Runs the working card's animations; off while AppKit keeps the card
    /// mounted but hidden.
    var isAnimating: Bool = true

    var onChat: ((NotificationCardManager.Card) -> Void)?
    var onRun: ((NotificationCardManager.Card) -> Void)?
    var onDismiss: ((NotificationCardManager.Card) -> Void)?
    var onMute: ((NotificationCardManager.Card) -> Void)?
    var onDelete: ((NotificationCardManager.Card) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let cornerRadius: CGFloat = 8
    
    /// Whether to show pagination buttons
    private var showPagination: Bool {
        totalCards > 1
    }

    private var runButtonTitle: String {
        if let buttonTitle = card.buttonTitle, !buttonTitle.isEmpty {
            return buttonTitle
        }
        return NSLocalizedString("notifications.card.runButton", value: "Run", comment: "Notification card run button - Executes the suggested action")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            switch card.kind {
            case .action:
                messageBlock
                actionRow
            case .working:
                workingBlock
                if showPagination {
                    paginationRow
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .themedFill(.contentOverlayBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .themedStroke(.border)
        )
    }

    private var headerRow: some View {
        HStack {
            NotificationCardAgentAvatarView(refreshID: card.id)

            if card.kind == .working {
                NotificationCardWorkingStatus(isAnimating: isAnimating)
            }

            Spacer()

            HStack(spacing: 2) {
                NotificationCardMenuButton()
                NotificationCardIconButton(resource: .cardClose) {
                    onDelete?(card)
                }
                NotificationCardIconButton(resource: .cardHide) {
                    onDismiss?(card)
                }
            }
        }
    }

    /// Maximum lines for message text
    private let messageMaxLines: Int = 8
    
    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !card.title.isEmpty {
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            if !card.message.isEmpty {
                Text(card.message)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineSpacing(4)
                    .lineLimit(messageMaxLines)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The working card's body, laid out like a running reply in Phi Chat:
    /// what the agent is working on, then its current activity beside the
    /// wandering dot.
    private var workingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !card.title.isEmpty {
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            if !card.message.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    NotificationCardWorkingDot(isAnimating: isAnimating)
                    Text(card.message)
                        .font(.system(size: 12))
                        .themedForeground(.custom(
                            light: NSColor.black.withAlphaComponent(0.4),
                            dark: NSColor.white.withAlphaComponent(0.6)
                        ))
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paginationRow: some View {
        HStack {
            NotificationCardPaginationButton(direction: .previous, isVisible: isHovered) {
                onPrevious?()
            }
            Spacer()
            NotificationCardPaginationButton(direction: .next, isVisible: isHovered) {
                onNext?()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            // Previous button (shown when hovering and multiple cards)
            if showPagination {
                NotificationCardPaginationButton(
                    direction: .previous,
                    isVisible: isHovered
                ) {
                    onPrevious?()
                }
            }
            NotificationCardActionButton(
                title: runButtonTitle,
                style: .primary
            ) {
                onRun?(card)
            }
            
            if showPagination {
                NotificationCardPaginationButton(
                    direction: .next,
                    isVisible: isHovered
                ) {
                    onNext?()
                }
            }
        }
    }

    private struct NotificationCardIconButton: View {
        let resource: ImageResource
        let action: () -> Void

        @State private var isHovered: Bool = false

        var body: some View {
            Button(action: action) {
                Image(resource)
                    .font(.system(size: 12))
                    .foregroundColor(.black)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .themedFill(isHovered ? .hover : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }
    
    /// Menu button for notification popup settings (Pop up / Mute)
    /// Uses NSMenu instead of SwiftUI Menu for better compatibility in overlay environments
    private struct NotificationCardMenuButton: View {
        @State private var isHovered: Bool = false
        @State private var currentMode: AccountUserDefaults.NotificationPopupMode = .popup
        
        var body: some View {
            Button {
                showNSMenu()
            } label: {
                Image(.cardQuiet)
                    .font(.system(size: 12))
                    .foregroundColor(.black)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .themedFill(isHovered ? .hover : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
            .onAppear {
                loadCurrentMode()
            }
        }
        
        private func showNSMenu() {
            loadCurrentMode()
            
            let menu = NSMenu()
            
            let popupItem = NSMenuItem(
                title: NSLocalizedString("notifications.contextMenu.enablePopupAction", value: "Pop up", comment: "Notification menu option - Enable auto popup for notification cards"),
                action: #selector(NotificationCardMenuHelper.setPopupMode),
                keyEquivalent: ""
            )
            popupItem.target = NotificationCardMenuHelper.shared
            popupItem.state = currentMode == .popup ? .on : .off
            menu.addItem(popupItem)
            
            let muteItem = NSMenuItem(
                title: NSLocalizedString("notifications.contextMenu.disablePopupAction", value: "Mute", comment: "Notification menu option - Disable auto popup for notification cards"),
                action: #selector(NotificationCardMenuHelper.setMuteMode),
                keyEquivalent: ""
            )
            muteItem.target = NotificationCardMenuHelper.shared
            muteItem.state = currentMode == .mute ? .on : .off
            menu.addItem(muteItem)
            
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    loadCurrentMode()
                }
            }
        }
        
        private func loadCurrentMode() {
            if let account = AccountController.shared.account {
                currentMode = account.userDefaults.notificationPopupMode
            }
        }
    }
    
    /// Helper class to handle NSMenu actions (NSMenu requires @objc selectors)
    @MainActor
    private class NotificationCardMenuHelper: NSObject {
        static let shared = NotificationCardMenuHelper()
        
        @objc func setPopupMode() {
            NotificationCardAnalytics.capture("popup")
            if let account = AccountController.shared.account {
                account.userDefaults.setNotificationPopupMode(.popup)
            }
        }
        
        @objc func setMuteMode() {
            NotificationCardAnalytics.capture("mute")
            if let account = AccountController.shared.account {
                account.userDefaults.setNotificationPopupMode(.mute)
            }
        }
    }

    private struct NotificationCardActionButton: View {
        enum Style {
            case primary
            case secondary
        }

        let title: String
        let style: Style
        let action: () -> Void

        @State private var isHovered: Bool = false

        private let buttonHeight: CGFloat = 20
        
        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .themedForeground(style == .primary ? .custom(light: .white, dark: .white) : .textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                    .overlay(border)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(height: buttonHeight)
            .onHover { hovering in
                isHovered = hovering
            }
        }

        private var background: some View {
            Group {
                if style == .primary {
                    if isHovered {
                        Color.clear
                            .themedBackground(.themeColorOnHover)
                    } else {
                        Color.clear
                            .themedBackground(.themeColor)
                    }
                } else {
                    if isHovered {
                        Color.clear
                            .themedBackground(.hover)
                    } else {
                        Color.clear
                    }
                }
            }
        }

        private var border: some View {
            Group {
                if style == .secondary {
                    Capsule()
                        .themedStroke(.border)
                }
            }
        }
    }
    
    /// Pagination button for navigating between cards
    private struct NotificationCardPaginationButton: View {
        enum Direction {
            case previous
            case next
            
            var systemImage: String {
                switch self {
                case .previous: return "chevron.left"
                case .next: return "chevron.right"
                }
            }
        }
        
        let direction: Direction
        let isVisible: Bool
        let action: () -> Void
        
        @State private var isHovered: Bool = false
        
        var body: some View {
            Button(action: action) {
                Image(systemName: direction.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .themedForeground(.textPrimary)
                    .frame(width: 24, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .themedFill(isHovered ? .hover : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isVisible)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }
}

private struct NotificationCardAgentAvatarView: View {
    let refreshID: String

    /// Starts from the last known avatar so the card never opens blank.
    @State private var image: NSImage? = AgentAvatarStore.cachedImage()

    private let size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.clear)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .task(id: refreshID) {
            await loadAvatar()
        }
    }

    @MainActor
    private func loadAvatar() async {
        // Follows account switches and sign-out before the fetch returns.
        image = AgentAvatarStore.cachedImage()
        if let fresh = await AgentAvatarStore.refresh(), !Task.isCancelled {
            image = fresh
        }
    }
}

// MARK: - Working Card

/// The working card's status label: Phi Chat's "Thinking…" treatment, a
/// sweeping shimmer over faint text with cycling dots.
private struct NotificationCardWorkingStatus: View {
    let isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    private static let shimmerPeriod: TimeInterval = 2
    private static let dotsPeriod: TimeInterval = 1.5
    private static let dotFrames = [".", "..", "...", ".."]

    private var label: String {
        NSLocalizedString(
            "notifications.card.workingStatus",
            value: "Working",
            comment: "Notification card - Status beside the agent avatar while the agent is still working on a task"
        )
    }

    private var textColor: Color {
        ThemedColor.custom(
            light: NSColor.black.withAlphaComponent(0.3),
            dark: NSColor.white.withAlphaComponent(0.3)
        ).swiftUIColor(theme: theme, appearance: appearance)
    }

    var body: some View {
        Group {
            if reduceMotion {
                statusText(dots: "...", shimmerProgress: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let dotIndex = Int(time.truncatingRemainder(dividingBy: Self.dotsPeriod)
                        / (Self.dotsPeriod / Double(Self.dotFrames.count)))
                    statusText(
                        dots: Self.dotFrames[min(dotIndex, Self.dotFrames.count - 1)],
                        shimmerProgress: time.truncatingRemainder(dividingBy: Self.shimmerPeriod)
                            / Self.shimmerPeriod
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func statusText(dots: String, shimmerProgress: Double?) -> some View {
        // The dots stay in the same text run so the shimmer sweeps them too;
        // their width changes as they cycle, as in Phi Chat.
        Text(verbatim: label + dots)
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(shimmerStyle(progress: shimmerProgress))
    }

    /// Phi Chat's shimmer: a gradient three times the text's width, faint
    /// everywhere except a clear band at its middle, sliding right so the
    /// band sweeps the text from left to right.
    private func shimmerStyle(progress: Double?) -> AnyShapeStyle {
        guard let progress else { return AnyShapeStyle(textColor) }
        let start = -2 + 2 * progress
        return AnyShapeStyle(LinearGradient(
            stops: [
                .init(color: textColor, location: 0),
                .init(color: textColor, location: 0.4),
                .init(color: textColor.opacity(0), location: 0.5),
                .init(color: textColor, location: 0.6),
                .init(color: textColor, location: 1),
            ],
            startPoint: UnitPoint(x: start, y: 0.5),
            endPoint: UnitPoint(x: start + 3, y: 0.5)
        ))
    }
}

/// Phi Chat's activity indicator: a small accent dot wandering smoothly
/// between irregular spots in a 16pt square, trailed by fainter, later copies.
private struct NotificationCardWorkingDot: View {
    let isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let boxSize: CGFloat = 16
    private static let dotSize: CGFloat = 4.8
    private static let period: TimeInterval = 1.5
    /// The leading dot first, then its afterimages.
    private static let copies: [(delay: TimeInterval, opacity: Double)] = [
        (0, 1), (0.08, 0.42), (0.16, 0.3), (0.24, 0.2), (0.32, 0.11),
    ]
    /// Keyframes as (fraction of the period, x, y), eased in and out between.
    private static let keyframes: [(at: Double, x: CGFloat, y: CGFloat)] = [
        (0, 0, 1), (0.12, 7, 8), (0.26, 10, 2), (0.37, 2, 9), (0.51, 9, 5),
        (0.63, 4, 0), (0.79, 1, 6), (0.91, 8, 3), (1, 0, 1),
    ]

    var body: some View {
        Group {
            if reduceMotion {
                dots(at: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating)) { context in
                    dots(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: Self.boxSize, height: Self.boxSize, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func dots(at time: TimeInterval?) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.copies.enumerated().reversed()), id: \.offset) { _, copy in
                let point = time.map { Self.position(at: $0 - copy.delay) }
                    ?? CGPoint(x: Self.keyframes[0].x, y: Self.keyframes[0].y)
                Circle()
                    .themedFill(.themeColor)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .opacity(time == nil && copy.delay > 0 ? 0 : copy.opacity)
                    .offset(x: point.x, y: point.y)
            }
        }
    }

    static func position(at time: TimeInterval) -> CGPoint {
        var phase = time.truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        for (from, to) in zip(keyframes, keyframes.dropFirst()) where phase <= to.at {
            let linear = (phase - from.at) / (to.at - from.at)
            let eased = CGFloat(0.5 - 0.5 * cos(Double.pi * linear))
            return CGPoint(x: from.x + (to.x - from.x) * eased,
                           y: from.y + (to.y - from.y) * eased)
        }
        return CGPoint(x: keyframes[0].x, y: keyframes[0].y)
    }
}

#if DEBUG
/// Interactive preview wrapper with state management
struct InteractiveCardPreview: View {
    let cards: [NotificationCardManager.Card]
    @State private var currentIndex: Int = 0
    @State private var isHovered: Bool = false
    
    private let cornerRadius: CGFloat = 8
    private let stackOffsetX: CGFloat = -6
    private let stackOffsetY: CGFloat = -12
    private let stackRotation: Double = 2
    private let stackScale: CGFloat = 0.98
    
    private var currentCard: NotificationCardManager.Card {
        cards[currentIndex]
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text("Card \(currentIndex + 1) of \(cards.count)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Current card with stacked background
            NotificationMessageCardContent(
                card: currentCard,
                totalCards: cards.count,
                currentIndex: currentIndex,
                isHovered: isHovered,
                onChat: { _ in print("Chat tapped") },
                onRun: { _ in print("Run tapped") },
                onDismiss: { _ in print("Dismiss tapped") },
                onMute: { _ in print("Mute tapped") },
                onDelete: { _ in print("Hint tapped") },
                onPrevious: {
                    currentIndex = (currentIndex - 1 + cards.count) % cards.count
                },
                onNext: {
                    currentIndex = (currentIndex + 1) % cards.count
                }
            )
            .background(
                Group {
                    if cards.count > 1 {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color.gray.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .scaleEffect(stackScale)
                            .rotationEffect(.degrees(stackRotation), anchor: .bottomTrailing)
                            .offset(x: stackOffsetX, y: stackOffsetY)
                    }
                }
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
    }
}

struct NotificationMessageCardContent_Previews: PreviewProvider {
    static let sampleCards: [NotificationCardManager.Card] = [
        NotificationCardManager.Card(
            taskId: "flight-search", 
            messageId: "msg-1",
            taskType: "research",
            timestamp: 1706500000000,
            title: "Trip ideas",
            message: "Looking for flights from LAX to Melbourne? I can compare prices across different platforms.",
            buttonTitle: "Compare",
            expiresAt: 0,
            correlationId: nil,
            timer: nil
        ),
        NotificationCardManager.Card(
            taskId: "weather-alert",
            messageId: "msg-2",
            taskType: "notification",
            timestamp: 1706500100000,
            title: "Weather Update",
            message: "Rain expected tomorrow in San Francisco. Would you like me to suggest indoor activities?",
            buttonTitle: "Suggest",
            expiresAt: 0,
            correlationId: nil,
            timer: nil
        ),
        NotificationCardManager.Card(
            taskId: "meeting-reminder",
            messageId: "msg-3",
            taskType: "reminder",
            timestamp: 1706500200000,
            title: "Upcoming Meeting",
            message: "You have a team standup in 15 minutes. I can prepare a summary of yesterday's progress.",
            buttonTitle: "Prepare",
            expiresAt: 0,
            correlationId: nil,
            timer: nil
        ),
        NotificationCardManager.Card(
            taskId: "price-drop",
            messageId: "msg-4",
            taskType: "alert",
            timestamp: 1706500300000,
            title: "Price Drop Alert",
            message: "The MacBook Pro you've been tracking just dropped $200. Should I show you the deal?",
            buttonTitle: "View Deal",
            expiresAt: 0,
            correlationId: nil,
            timer: nil
        ),
        NotificationCardManager.Card(
            taskId: "news-digest",
            messageId: "msg-5",
            taskType: "digest",
            timestamp: 1706500400000,
            title: "Morning News",
            message: "I've compiled today's top tech news. 5 articles about AI, 3 about startups, and 2 about cybersecurity.",
            buttonTitle: "Read",
            expiresAt: 0,
            correlationId: nil,
            timer: nil
        )
    ]
    
    static var previews: some View {
        VStack(spacing: 30) {
            // Single card (no pagination)
            Text("Single Card")
                .font(.headline)
            InteractiveCardPreview(cards: [sampleCards[0]])
            
            Divider()
            
            // Multiple cards - interactive
            Text("Multiple Cards (Interactive)")
                .font(.headline)
            InteractiveCardPreview(cards: sampleCards)
        }
        .padding(40)
        .background(Color.gray.opacity(0.1))
        .frame(width: 320)
    }
}
#endif
