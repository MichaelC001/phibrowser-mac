// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Auth0

extension NSNotification.Name {
    static let loginCompleted = NSNotification.Name("LoginCompleted")
}

class OnboardingWindowController: NSWindowController {
    private(set) var presentsGuestMigrationRecovery = false

    private(set) lazy var loginViewController: LoginViewController = {
        let vc = LoginViewController()
        vc.presentationMode = presentsGuestMigrationRecovery
            ? .guestMigrationRecovery
            : .standard
        vc.onLoginSuccess = { [weak self] credentials in
            guard let credentials, let self else { return }
            self.routeToCurrentPhase(using: credentials)
        }
        vc.onContinueAsGuest = { [weak self] in
            self?.showGuestPrivacyConfirmation()
        }
        return vc
    }()

    private lazy var guestPrivacyConfirmationViewController: GuestPrivacyConfirmationViewController = {
        let vc = GuestPrivacyConfirmationViewController()
        vc.onConfirm = { [weak self, weak vc] sharesUsageMetrics in
            Task { @MainActor [weak self, weak vc] in
                guard ChromiumLauncher.sharedInstance().bridge != nil else {
                    AppLogError(
                        "[GuestPrivacy] Cannot enter Guest Mode before the Chromium bridge is ready"
                    )
                    vc?.resetAfterGuestEntryFailure()
                    return
                }

                let result = LoginController.shared.continueAsGuest(
                    metricsReportingPreference: sharesUsageMetrics
                )
                switch result {
                case .enteredGuestMode:
                    return
                case .requiresAccountRecovery:
                    guard let self else { return }
                    self.setContent(self.loginViewController)
                case .failed:
                    vc?.resetAfterGuestEntryFailure()
                }
            }
        }
        return vc
    }()
    
    private lazy var welcomeViewController: OnboardingWelcomeViewController = {
        let vc = OnboardingWelcomeViewController()
        vc.nextClosure = { [weak self] _ in
            guard let self else { return }
            LoginController.shared.phase = .layoutSelection
            ChromiumLauncher.sharedInstance().bridge?.notifyLoginCompleted()
            setContent(layoutSelectionViewController)
        }
        return vc
    }()

    private lazy var layoutSelectionViewController: LayoutSelectionViewController = {
        let vc = LayoutSelectionViewController()
        vc.nextClosure = { [weak self] _ in
            guard let self else { return }
            self.showPasswordManagerPage()
        }
        return vc
    }()

    private lazy var passwordManagerViewController: PasswordManagerViewController = {
        let vc = PasswordManagerViewController()
        vc.nextClosure = { [weak self] _ in
            self?.showNextStepPage()
        }
        return vc
    }()

    private lazy var nextStepViewController: NextStepViewController = {
        let vc = NextStepViewController()
        vc.nextClosure = { [weak self] _ in
            self?.finish()
        }
        return vc
    }()

    private lazy var setNameViewController: SetNameViewController = {
        let vc = SetNameViewController()
        vc.newNameSettled = { [weak self] name in
            guard let self else { return }
            LoginController.shared.phase = .setTheme
            welcomeViewController.userName = name
            setContent(welcomeViewController)
        }
        return vc
    }()
    
    convenience init(presentsGuestMigrationRecovery: Bool = false) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.animationBehavior = .default

        
        self.init(window: window)
        self.presentsGuestMigrationRecovery = presentsGuestMigrationRecovery
        setupContentViewController()
    }

    private func setupContentViewController() {
        let contentVc: NSViewController = {
            if let credentials = AuthManager.shared.currentCredentials {
                LoginController.shared.initAccountIfNeeded(credentials)
                let loginPhase = LoginController.shared.phase
                guard loginPhase != .done else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finish()
                    }
                    return loginViewController
                }
                return viewController(for: loginPhase, credentials: credentials, isFirstPage: true)
            }

            if let storedUserInfo = AuthManager.shared.storedUserInfo() {
                LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
                let loginPhase = LoginController.shared.phase
                guard loginPhase != .done else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finish()
                    }
                    return loginViewController
                }
                return viewController(for: loginPhase, credentials: nil, isFirstPage: true)
            }

            return loginViewController
        }()
        contentViewController = contentVc
    }
    
    // MARK: - Content Management

    private func setContent(_ vc: NSViewController) {
        window?.contentViewController = vc
    }
    
    private func routeToCurrentPhase(using credentials: Credentials) {
        let loginPhase = LoginController.shared.phase
        guard loginPhase != .done else {
            finish()
            return
        }

        setContent(viewController(for: loginPhase, credentials: credentials, isFirstPage: false))
    }

    private func viewController(for phase: LoginController.Phase, credentials: Credentials?, isFirstPage: Bool) -> NSViewController {
        setNameViewController.isFisrtPage = false
        passwordManagerViewController.isFisrtPage = false
        nextStepViewController.isFisrtPage = false

        switch phase {
        case .login:
            return loginViewController
        case .setName:
            setNameViewController.credentials = credentials
            setNameViewController.isFisrtPage = isFirstPage
            return setNameViewController
        case .setTheme:
            if let credentials {
                let user = AuthManager.retriveUserInfo(from: credentials)
                welcomeViewController.userName = user.name
            } else {
                welcomeViewController.userName = LoginController.shared.accountForOnboarding?.userInfo?.name
            }
            return welcomeViewController
        case .layoutSelection:
            return layoutSelectionViewController
        case .passwordManager:
            passwordManagerViewController.isFisrtPage = isFirstPage
            return passwordManagerViewController
        case .nextStep:
            nextStepViewController.isFisrtPage = isFirstPage
            return nextStepViewController
        case .done:
            return loginViewController
        }
    }

    private func showPasswordManagerPage() {
        LoginController.shared.phase = .passwordManager
        setContent(passwordManagerViewController)
    }

    private func showNextStepPage() {
        LoginController.shared.phase = .nextStep
        setContent(nextStepViewController)
    }

    func showGuestPrivacyConfirmation() {
        setContent(guestPrivacyConfirmationViewController)
    }

    private func finish() {
        LoginController.shared.phase = .done

        Task { @MainActor in
            await LoginController.shared.completeCurrentLogin()
        }
    }
}
