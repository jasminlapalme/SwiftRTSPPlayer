//
//  PanelColors.swift
//  SwiftRTSPPlayer
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
	/// Adaptive surface colour for the panel background. White-tinted
	/// veil in light mode, black-tinted veil in dark mode, both at low
	/// opacity so the underlying video stays visible. Tweak the alpha
	/// values below to push toward more video / more readability.
	static let panelSurface: Color = {
#if canImport(UIKit)
		return Color(UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor.black.withAlphaComponent(0.40)
				: UIColor.white.withAlphaComponent(0.35)
		})
#elseif canImport(AppKit)
		return Color(NSColor(name: nil, dynamicProvider: { appearance in
			let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			return isDark
				? NSColor.black.withAlphaComponent(0.40)
				: NSColor.white.withAlphaComponent(0.35)
		}))
#else
		return Color.black.opacity(0.40)
#endif
	}()

	/// Accent blue tuned for both color schemes. The system `Color.blue`
	/// reads as pastel against a light translucent material; this variant
	/// is a more saturated royal blue in light mode and a slightly brighter
	/// shade in dark mode for readability against the darkened blur.
	static let panelAccent: Color = {
#if canImport(UIKit)
		return Color(UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1.0)
				: UIColor(red: 0.00, green: 0.36, blue: 0.86, alpha: 1.0)
		})
#elseif canImport(AppKit)
		return Color(NSColor(name: nil, dynamicProvider: { appearance in
			let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			return isDark
				? NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1.0)
				: NSColor(red: 0.00, green: 0.36, blue: 0.86, alpha: 1.0)
		}))
#else
		return .blue
#endif
	}()
}
