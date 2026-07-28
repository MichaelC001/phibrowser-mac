// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// A theme-aware segmented picker with a `Picker`-like selection API.
///
/// Labels use their intrinsic width by default and can be distributed evenly.
/// The control owns the shared selection indicator and its transition.
struct PhiSegmentedPicker<SelectionValue: Hashable, Label: View>: View {
    private let options: [SelectionValue]
    private let equalSegmentWidths: Bool
    @Binding private var selection: SelectionValue
    private let label: (SelectionValue) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Namespace private var selectionNamespace

    init<Data: RandomAccessCollection>(
        _ options: Data,
        selection: Binding<SelectionValue>,
        equalSegmentWidths: Bool = false,
        @ViewBuilder label: @escaping (SelectionValue) -> Label
    ) where Data.Element == SelectionValue {
        self.options = Array(options)
        self.equalSegmentWidths = equalSegmentWidths
        _selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: PhiSegmentedPickerMetrics.segmentSpacing) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(PhiSegmentedPickerMetrics.controlPadding)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule()
                        .fill(appearance.isLight ? Color.white : Color.clear)
                }
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(PhiSegmentedPickerMetrics.borderOpacity))
        }
        .shadow(
            color: .black.opacity(PhiSegmentedPickerMetrics.shadowOpacity),
            radius: PhiSegmentedPickerMetrics.shadowRadius,
            y: PhiSegmentedPickerMetrics.shadowOffset
        )
        .fixedSize(horizontal: !equalSegmentWidths, vertical: true)
        .opacity(isEnabled ? 1 : PhiSegmentedPickerMetrics.disabledOpacity)
        .animation(selectionAnimation, value: selection)
    }

    private func segment(_ option: SelectionValue) -> some View {
        let isSelected = selection == option

        return Button {
            selection = option
        } label: {
            label(option)
                .font(.system(size: PhiSegmentedPickerMetrics.fontSize, weight: .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(height: PhiSegmentedPickerMetrics.labelHeight)
                .padding(.horizontal, segmentHorizontalPadding)
                .padding(.vertical, PhiSegmentedPickerMetrics.verticalPadding)
                .frame(maxWidth: equalSegmentWidths ? .infinity : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: equalSegmentWidths ? .infinity : nil)
        .background {
            if isSelected {
                Capsule()
                    .fill(selectionColor)
                    .matchedGeometryEffect(
                        id: PhiSegmentedPickerSelectionIndicator.id,
                        in: selectionNamespace
                    )
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectionColor: Color {
        ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var segmentHorizontalPadding: CGFloat {
        equalSegmentWidths
            ? PhiSegmentedPickerMetrics.equalWidthHorizontalPadding
            : PhiSegmentedPickerMetrics.horizontalPadding
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: PhiSegmentedPickerMetrics.animationDuration)
    }
}

private enum PhiSegmentedPickerSelectionIndicator {
    static let id = "selectedSegment"
}

private enum PhiSegmentedPickerMetrics {
    static let controlPadding: CGFloat = 2
    static let segmentSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 16
    static let equalWidthHorizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 3
    static let labelHeight: CGFloat = 16
    static let fontSize: CGFloat = 12
    static let borderOpacity: CGFloat = 0.1
    static let shadowOpacity: CGFloat = 0.06
    static let shadowRadius: CGFloat = 25
    static let shadowOffset: CGFloat = 20
    static let disabledOpacity: CGFloat = 0.5
    static let animationDuration: TimeInterval = 0.18
}
