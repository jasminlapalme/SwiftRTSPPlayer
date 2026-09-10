//
//  PanelTabBar.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The control panel's tab strip: a segmented picker on iOS and macOS, and on
/// tvOS a pill of focusable icons, since the remote has no pointer to tap one.
struct PanelTabBar<Tab: Hashable>: View {

	struct Item: Identifiable {
		let tab: Tab
		let systemImage: String
		let label: String

		var id: Tab { tab }
	}

	let items: [Item]
	@Binding var selection: Tab
#if os(tvOS)
	let focusedTab: FocusState<Tab?>.Binding
#endif

	var body: some View {
#if os(tvOS)
		HStack(spacing: 16) {
			ForEach(items) { tabButton($0) }
		}
		.padding(.vertical, 2)
		.background(
			Capsule(style: .continuous)
				.fill(Color.primary.opacity(0.10))
		)
#else
		Picker(selection: $selection) {
			ForEach(items) { item in
				Text(item.label).tag(item.tab)
			}
		} label: {
			EmptyView()
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.fixedSize()
#endif
	}

#if os(tvOS)
	@ViewBuilder
	private func tabButton(_ item: Item) -> some View {
		let isActive = (selection == item.tab)
		let isFocus = (focusedTab.wrappedValue == item.tab)
		Image(systemName: item.systemImage)
			.font(.body)
			.fontWeight(isFocus || isActive ? .semibold : .regular)
			.foregroundStyle(
				isFocus
					? Color.black
					: (isActive ? Color.primary : Color.primary.opacity(0.6))
			)
			.frame(width: 24, height: 20)
			.padding(.vertical, 14)
			.padding(.horizontal, 32)
			.background(
				Capsule(style: .continuous)
					.fill(isFocus ? Color.white : Color.clear)
					.shadow(
						color: Color.black.opacity(isFocus ? 0.30 : 0),
						radius: isFocus ? 12 : 0,
						y: isFocus ? 8 : 0
					)
			)
			.scaleEffect(isFocus ? 1.1 : 1.0)
			.animation(.easeInOut(duration: 0.18), value: isFocus)
			.animation(.easeInOut(duration: 0.18), value: isActive)
			.contentShape(Capsule())
			.accessibilityLabel(item.label)
			.focusable(true)
			.focused(focusedTab, equals: item.tab)
	}
#endif
}
