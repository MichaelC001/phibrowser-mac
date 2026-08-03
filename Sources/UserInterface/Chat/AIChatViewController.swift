// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import PostHog

class AIChatViewController: NSViewController {
    private lazy var contentView = NSView()
    private lazy var loginRequiredOverlayView = LoginRequiredOverlayView()
    private lazy var cancellables = Set<AnyCancellable>()
    let state: BrowserState
    private var isInitialized = false

    /// Currently displayed AI Chat Tab
    private var currentAIChatTab: Tab?
    /// Identifier of the currently displayed AI Chat Tab
    private var currentIdentifier: String?
    private var aiChatPageViewStart: Date?
    
    init(with browserState: BrowserState) {
        self.state = browserState
        super.init(nibName: nil, bundle: nil)
        _ = self.view
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(contentView)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 6
        contentView.phiLayer?.backgroundColor = NSColor.white <> NSColor.black
        
        contentView.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.right.bottom.top.equalToSuperview().inset(WebContentConstant.edgesSpacing)
        }
        
        setupObservers()
        updateLoginRequiredPresentation()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        updateLoginRequiredPresentation()
        handleAIChatVisibilityChanged(collapsed: false)
        aiChatPageViewStart = Date()
        PostHogSDK.shared.capture("ai_chat_page_opened")
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let start = aiChatPageViewStart {
            PostHogSDK.shared.capture("ai_chat_page_viewed", properties: [
                "duration_seconds": Date().timeIntervalSince(start),
            ])
            aiChatPageViewStart = nil
        }
    }
    
    private func setupObservers() {
        guard !state.isIncognito, !isInitialized else {
            return
        }
        
        isInitialized = true
        
        state.$focusingTab
            .combineLatest(state.$aiChatCollapsed)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] focusingTab, collapsed in
                guard let self, !collapsed else { return }
                self.handleFocusingTabChanged(focusingTab)
            }
            .store(in: &cancellables)
        
        state.$aiChatTabs
            .sink { [weak self] tabs in
                guard let self,
                      self.canLoadAIChat,
                      let identifier = self.currentIdentifier,
                      let newTab = tabs[identifier],
                      newTab !== self.currentAIChatTab else { return }
                self.switchToAIChatTab(newTab, identifier: identifier)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateLoginRequiredPresentation()
                if self.canLoadAIChat {
                    self.handleAIChatVisibilityChanged(collapsed: false)
                }
            }
            .store(in: &cancellables)
    }
    
    /// Handles AI Chat panel visibility changes.
    private func handleAIChatVisibilityChanged(collapsed: Bool) {
        guard !collapsed, !state.isIncognito else { return }
        guard canLoadAIChat else {
            updateLoginRequiredPresentation()
            return
        }
        
        handleFocusingTabChanged(state.focusingTab)
    }
    
    /// Switches to or creates the AI Chat tab for the current focused tab.
    private func handleFocusingTabChanged(_ focusingTab: Tab?) {
        guard canLoadAIChat else {
            updateLoginRequiredPresentation()
            return
        }
        guard let focusingTab,
              state.isInPlaceholderMode == false else { return }

        let identifier = state.getTabIdentifier(for: focusingTab)
        guard identifier != currentIdentifier else { return }

        if let aiChatTab = state.aiChatTabs[identifier] {
            switchToAIChatTab(aiChatTab, identifier: identifier)
        } else {
            currentIdentifier = identifier

            let chromeTabId = focusingTab.guid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.canLoadAIChat else { return }
                if self.state.aiChatTabs[identifier] == nil {
                    self.state.createAIChatTab(for: identifier, chromeTabId: chromeTabId)
                }
            }
        }
    }
    
    /// Switches the embedded view to the specified AI Chat tab.
    private func switchToAIChatTab(_ tab: Tab, identifier: String) {
        guard canLoadAIChat else {
            updateLoginRequiredPresentation()
            return
        }
        currentAIChatTab?.webContentView?.removeFromSuperview()
        
        if let native = tab.webContentView {
            addWebContent(native)
        } else {
            observeWebContentReady(for: tab, identifier: identifier)
        }
        
        currentAIChatTab = tab
        currentIdentifier = identifier
    }
    
    /// Waits for the native web view to become available.
    private func observeWebContentReady(for tab: Tab, identifier: String) {
        var checkCount = 0
        let maxChecks = 20
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak tab] timer in
            checkCount += 1
            
            guard let self, let tab else {
                timer.invalidate()
                return
            }
            
            guard self.currentIdentifier == identifier else {
                timer.invalidate()
                return
            }

            guard self.canLoadAIChat else {
                timer.invalidate()
                self.updateLoginRequiredPresentation()
                return
            }
            
            if let native = tab.webContentView {
                timer.invalidate()
                self.addWebContent(native)
            } else if checkCount >= maxChecks {
                timer.invalidate()
            }
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        
    }
    
    private func addWebContent(_ native: NSView) {
        guard canLoadAIChat else {
            updateLoginRequiredPresentation()
            return
        }
        contentView.subviews.forEach { $0.removeFromSuperview() }
        
        contentView.addSubview(native)
        native.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private var shouldPresentLoginRequired: Bool {
        LoginRequiredPresentationPolicy.shouldPresent(
            for: .aiChat,
            isGuest: ApplicationState.shared.isGuest,
            isPhiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue()
        )
    }

    private var canLoadAIChat: Bool {
        ApplicationState.shared.isAuthenticated
    }

    private func updateLoginRequiredPresentation() {
        guard !canLoadAIChat else {
            loginRequiredOverlayView.removeFromSuperview()
            return
        }

        currentAIChatTab?.webContentView?.removeFromSuperview()
        currentAIChatTab = nil
        currentIdentifier = nil
        contentView.subviews
            .filter { $0 !== loginRequiredOverlayView }
            .forEach { $0.removeFromSuperview() }

        guard shouldPresentLoginRequired else {
            loginRequiredOverlayView.removeFromSuperview()
            return
        }

        guard loginRequiredOverlayView.superview !== contentView else { return }
        loginRequiredOverlayView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loginRequiredOverlayView)
        NSLayoutConstraint.activate([
            loginRequiredOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
            loginRequiredOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            loginRequiredOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            loginRequiredOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
    
    /// Reattaches the AI Chat view if another container moved it away.
//    private func reattachAIChatViewIfNeeded() {
//        guard let native = state.aiChatTab?.webContentWrapper?.nativeView else { return }
//        if native.superview == contentView { return }
//        addWebContent(native)
//    }
    
    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        self.view = view
    }
}
