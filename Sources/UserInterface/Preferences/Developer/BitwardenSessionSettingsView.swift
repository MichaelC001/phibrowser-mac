// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Session-policy rows embedded in the Agent Password Manager card: how long
/// the unlocked Bitwarden vault lasts and what happens when it ends. Both
/// selections drive `BitwardenService.applyTimeoutPolicy()` so a running
/// helper adopts them immediately (they also travel with the next login).
struct BitwardenSessionTimeoutRows: View {
    @AppStorage(BitwardenSessionTimeout.storageKey)
    private var timeout = BitwardenSessionTimeout.defaultValue
    @AppStorage(BitwardenTimeoutAction.storageKey)
    private var action = BitwardenTimeoutAction.defaultValue

    var body: some View {
        row("clock.fill", .blue,
            NSLocalizedString("Session timeout", comment: "Phi & AI settings - Row title for how long the unlocked Bitwarden vault lasts")) {
            BitwardenDropdown(
                selection: $timeout,
                options: BitwardenSessionTimeout.allCases,
                label: { $0.label }
            ) { _ in Task { await BitwardenService.shared.applyTimeoutPolicy() } }
        }
        Divider()
        row("lock.fill", .purple,
            NSLocalizedString("Timeout action", comment: "Phi & AI settings - Row title for what happens when the Bitwarden session times out")) {
            BitwardenDropdown(
                selection: $action,
                options: BitwardenTimeoutAction.allCases,
                label: { $0.label }
            ) { _ in Task { await BitwardenService.shared.applyTimeoutPolicy() } }
        }
    }

    private func row<Content: View>(_ symbol: String, _ color: Color, _ title: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            SettingsIconChip(systemName: symbol, color: color)
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            content()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared dropdown

/// The native macOS pop-up button for a settings row: current value +
/// chevrons, standard menu with a checkmark on the selection. (Replaces an
/// earlier hand-rolled bordered Menu whose borderless label rendered
/// inconsistently across themes.)
struct BitwardenDropdown<Value: Identifiable & Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var onChange: (Value) -> Void = { _ in }

    var body: some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                onChange(newValue)
            }
        )) {
            ForEach(options) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
