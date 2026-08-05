// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

struct NextStepConsentState {
    // UN M49 region code for geographic Europe.
    private static let geographicEuropeRegion = Locale.Region("150")
    private static let europeanUnionRegions = Set(Locale.Region("EU").subRegions)

    var hasAcceptedLegalTerms = false
    var sharesUsageMetrics: Bool

    init(locale: Locale = .current) {
        guard let region = locale.region else {
            sharesUsageMetrics = false
            return
        }

        let isEuropeanPrivacyRegion =
            region.continent == Self.geographicEuropeRegion ||
            Self.europeanUnionRegions.contains(region)
        sharesUsageMetrics = !isEuropeanPrivacyRegion
    }

    var canBegin: Bool {
        hasAcceptedLegalTerms
    }
}

final class NextStepViewController: OnboardingBaseViewController {
    private enum Metrics {
        static let contentWidth: CGFloat = 472
        static let screenshotInset: CGFloat = 8
        static let screenshotHeight: CGFloat = 264
        static let screenshotCornerRadius: CGFloat = 8
        static let containerCornerRadius: CGFloat = 14
        static let consentSpacing: CGFloat = 14
    }

    private static let privacyURL = URL(string: "http://phibrowser.com/privacy/")!
    private static let termsURL = URL(string: "http://phibrowser.com/terms/")!

    private var consentState = NextStepConsentState()
    private var isSavingMetricsConsent = false

    private lazy var screenshotContainer: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.cornerRadius = Metrics.containerCornerRadius
        return container
    }()

    private lazy var screenshotImageView: NSImageView = {
        let imageView = NSImageView(image: selectedLayoutScreenshot)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Metrics.screenshotCornerRadius
        imageView.layer?.masksToBounds = true
        return imageView
    }()

    private lazy var legalConsentRow = OnboardingCheckboxRow(
        attributedTitle: legalAgreementTitle,
        accessibilityTitle: legalAgreementTitle.string,
        isChecked: consentState.hasAcceptedLegalTerms
    )

    private lazy var metricsConsentRow = OnboardingCheckboxRow(
        title: NSLocalizedString(
            "oobe.nextSteps.metricsConsent",
            value: "Help make Phi better by sharing usage metrics and crash reports",
            comment: "Onboarding next steps - Optional checkbox for sharing usage metrics and crash reports"
        ),
        isChecked: consentState.sharesUsageMetrics
    )

    private lazy var consentStackView: NSStackView = {
        let stackView = NSStackView(views: [legalConsentRow, metricsConsentRow])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = Metrics.consentSpacing
        return stackView
    }()

    private var selectedLayoutScreenshot: NSImage {
        switch PhiPreferences.GeneralSettings.loadLayoutMode() {
        case .performance:
            return NSImage(resource: .tabLayoutPerformanceOobe)
        case .balanced:
            return NSImage(resource: .tabLayoutBalancedOobe)
        case .comfortable:
            return NSImage(resource: .tabLayoutComfortableOobe)
        }
    }

    private var legalAgreementTitle: NSAttributedString {
        let privacyTitle = NSLocalizedString(
            "oobe.nextSteps.privacyLink",
            value: "Privacy",
            comment: "Onboarding next steps - Link title for the Phi privacy policy"
        )
        let termsTitle = NSLocalizedString(
            "oobe.nextSteps.termsLink",
            value: "Terms",
            comment: "Onboarding next steps - Link title for the Phi terms of service"
        )
        let format = NSLocalizedString(
            "oobe.nextSteps.legalAgreement",
            value: "I agree to the %1$@ and %2$@",
            comment: "Onboarding next steps - Required legal agreement; first placeholder is the Privacy link and second is the Terms link"
        )
        let title = String(format: format, privacyTitle, termsTitle)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraphStyle
            ]
        )
        addLink(
            to: attributedTitle,
            title: privacyTitle,
            url: Self.privacyURL
        )
        addLink(
            to: attributedTitle,
            title: termsTitle,
            url: Self.termsURL
        )
        return attributedTitle
    }

    override func loadView() {
        super.loadView()

        titleLabel.stringValue = NSLocalizedString(
            "oobe.nextSteps.title",
            value: "Next steps",
            comment: "Onboarding next steps - Page title"
        )
        skipButton.isHidden = true
        nextButton.title = NSLocalizedString(
            "oobe.nextSteps.beginButton",
            value: "Let's Begin",
            comment: "Onboarding next steps - Final button that completes onboarding"
        )

        setupContent()
        setupActions()
        updateBeginButton()
    }

    override func nextButtonTapped(_ sender: NSButton? = nil) {
        guard consentState.canBegin, !isSavingMetricsConsent else { return }

        isSavingMetricsConsent = true
        updateBeginButton()

        if let bridge = ChromiumLauncher.sharedInstance().bridge {
            bridge.setMetricsReportingEnabled(consentState.sharesUsageMetrics) { _ in }
        } else {
            AppLogError("[NextStep] Unable to save metrics consent without the Chromium bridge")
        }

        nextClosure?(true)
    }

    private func setupContent() {
        view.addSubview(screenshotContainer)
        screenshotContainer.addSubview(screenshotImageView)
        view.addSubview(consentStackView)

        screenshotContainer.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(28)
            make.centerX.equalToSuperview()
            make.width.equalTo(Metrics.contentWidth)
        }

        screenshotImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Metrics.screenshotInset)
            make.height.equalTo(Metrics.screenshotHeight)
        }

        consentStackView.snp.makeConstraints { make in
            make.top.equalTo(screenshotContainer.snp.bottom).offset(28)
            make.left.right.equalTo(screenshotContainer)
            make.bottom.lessThanOrEqualTo(nextButton.snp.top).offset(-40)
        }

        for row in [legalConsentRow, metricsConsentRow] {
            row.snp.makeConstraints { make in
                make.width.equalTo(Metrics.contentWidth)
            }
        }
    }

    private func setupActions() {
        legalConsentRow.onToggle = { [weak self] isChecked in
            guard let self else { return }
            self.consentState.hasAcceptedLegalTerms = isChecked
            self.updateBeginButton()
        }
        metricsConsentRow.onToggle = { [weak self] isChecked in
            self?.consentState.sharesUsageMetrics = isChecked
        }
    }

    private func updateBeginButton() {
        let isEnabled = consentState.canBegin && !isSavingMetricsConsent
        nextButton.isEnabled = isEnabled
        nextButton.alphaValue = isEnabled ? 1 : 0.5
    }

    private func addLink(
        to attributedTitle: NSMutableAttributedString,
        title: String,
        url: URL
    ) {
        let range = (attributedTitle.string as NSString).range(of: title)
        guard range.location != NSNotFound else { return }
        attributedTitle.addAttributes(
            [
                .link: url,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ],
            range: range
        )
    }
}

private final class OnboardingCheckboxRow: NSView {
    var onToggle: ((Bool) -> Void)?

    private var isChecked: Bool

    private lazy var checkboxButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggleCheckbox)
        button.setAccessibilityRole(.checkBox)
        return button
    }()

    private let titleLabel: NSTextField

    convenience init(title: String, isChecked: Bool) {
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85)
            ]
        )
        self.init(
            attributedTitle: attributedTitle,
            accessibilityTitle: title,
            isChecked: isChecked
        )
    }

    init(
        attributedTitle: NSAttributedString,
        accessibilityTitle: String,
        isChecked: Bool
    ) {
        self.isChecked = isChecked
        self.titleLabel = NSTextField(wrappingLabelWithString: "")
        super.init(frame: .zero)

        titleLabel.attributedStringValue = attributedTitle
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.isSelectable = attributedTitle.containsAttachmentsOrLinks
        titleLabel.allowsEditingTextAttributes = attributedTitle.containsAttachmentsOrLinks

        checkboxButton.setAccessibilityLabel(accessibilityTitle)
        addSubview(checkboxButton)
        addSubview(titleLabel)

        checkboxButton.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.top.equalToSuperview().offset(1)
            make.width.height.equalTo(18)
        }

        titleLabel.snp.makeConstraints { make in
            make.left.equalTo(checkboxButton.snp.right).offset(10)
            make.top.right.bottom.equalToSuperview()
        }

        updateCheckboxAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleCheckbox() {
        isChecked.toggle()
        updateCheckboxAppearance()
        onToggle?(isChecked)
    }

    private func updateCheckboxAppearance() {
        checkboxButton.image = isChecked
            ? NSImage(resource: .check)
            : NSImage(resource: .uncheck)
        checkboxButton.setAccessibilityValue(
            isChecked ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue
        )
    }
}

private extension NSAttributedString {
    var containsAttachmentsOrLinks: Bool {
        var containsLink = false
        enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: length)
        ) { value, _, stop in
            guard value != nil else { return }
            containsLink = true
            stop.pointee = true
        }
        return containsLink
    }
}
