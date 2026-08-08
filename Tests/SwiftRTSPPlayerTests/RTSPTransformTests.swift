import CoreGraphics
import Testing
#if os(macOS)
import AppKit
#endif
@testable import SwiftRTSPPlayer

@Suite("RTSPTransform gestures")
struct RTSPTransformTests {

	private let limits = RTSPTransformLimits()

	// MARK: - Pan

	@Test("A drag moves the image by the same amount")
	func panFollowsTheDrag() {
		let panned = RTSPTransform().panned(by: CGPoint(x: 30, y: -20), limits: limits)
		#expect(panned.translation == CGPoint(x: 30, y: -20))
		#expect(panned.scale == 1)
	}

	@Test("A drag past the limit stops at it")
	func panClampsToLimits() {
		let panned = RTSPTransform(translation: CGPoint(x: 480, y: 0))
			.panned(by: CGPoint(x: 100, y: -900), limits: limits)
		#expect(panned.translation == CGPoint(x: 500, y: -500))
	}

	// MARK: - Zoom

	@Test("Zooming at the centre scales in place")
	func zoomAtCentreKeepsTranslation() {
		let zoomed = RTSPTransform().zoomed(by: 2, around: .zero, limits: limits)
		#expect(zoomed.scale == 2)
		#expect(zoomed.translation == .zero)
	}

	@Test("Zooming keeps the detail under the pointer where it is")
	func zoomPinsTheAnchor() {
		let anchor = CGPoint(x: 120, y: -60)
		let before = RTSPTransform(scale: 1.5, translation: CGPoint(x: 20, y: 10))
		let after = before.zoomed(by: 1.4, around: anchor, limits: limits)

		// The detail at `anchor` sits at (anchor - translation) / scale in image
		// space, up to the rotation; it must land back on `anchor` afterwards.
		let ratio = after.scale / before.scale
		#expect(after.translation.x.isApproximately(anchor.x - ratio * (anchor.x - before.translation.x)))
		#expect(after.translation.y.isApproximately(anchor.y - ratio * (anchor.y - before.translation.y)))
	}

	@Test("Zooming in at the top of the range moves nothing")
	func zoomStopsAtMaximumScale() {
		let atMaximum = RTSPTransform(scale: limits.scale.upperBound, translation: CGPoint(x: 40, y: 40))
		let zoomed = atMaximum.zoomed(by: 1.5, around: CGPoint(x: 100, y: 100), limits: limits)
		#expect(zoomed == atMaximum)
	}

	@Test("Zooming out stops at the bottom of the range")
	func zoomStopsAtMinimumScale() {
		let zoomed = RTSPTransform(scale: 0.2).zoomed(by: 0.1, around: .zero, limits: limits)
		#expect(zoomed.scale == limits.scale.lowerBound)
	}

	@Test("A zoom that would push the translation out of range is clamped")
	func zoomClampsTranslation() {
		let zoomed = RTSPTransform(scale: 1, translation: CGPoint(x: 400, y: 0))
			.zoomed(by: 3, around: CGPoint(x: -600, y: 0), limits: limits)
		#expect(zoomed.translation.x == limits.translationX.upperBound)
	}

	@Test("A degenerate scale is left alone")
	func zoomIgnoresNonPositiveFactors() {
		let transform = RTSPTransform(scale: 1.2)
		#expect(transform.zoomed(by: 0, around: .zero, limits: limits) == transform)
		#expect(transform.zoomed(by: -1, around: .zero, limits: limits) == transform)
	}

	// MARK: - Rotate

	@Test("Rotating adds to the current angle")
	func rotateAddsDegrees() {
		#expect(RTSPTransform(rotation: 30).rotated(by: -45, limits: limits).rotation == -15)
	}

	@Test("Rotating past the limit stops at it")
	func rotateClampsToLimits() {
		#expect(RTSPTransform(rotation: 170).rotated(by: 40, limits: limits).rotation == 180)
	}

	// MARK: - Room to pan when zoomed in

	/// A 16:9 image filling a 1600x900 view — one screen point per fitted point.
	private var fitted: RTSPTransformLimits {
		var limits = RTSPTransformLimits()
		limits.layout = RTSPContentLayout(
			fittedSize: CGSize(width: 1600, height: 900),
			viewSize: CGSize(width: 1600, height: 900)
		)
		return limits
	}

	@Test("An image that fits keeps the configured range")
	func noOverhangKeepsConfiguredRange() {
		let ranges = fitted.translationRanges(scale: 1, rotation: 0)
		#expect(ranges.x == -500...500)
		#expect(ranges.y == -500...500)
	}

	@Test("Zooming in opens the range up to the image's edges")
	func zoomOpensTheRange() {
		// At 3x the image is 4800x2700 in a 1600x900 view: 1600 hangs off each
		// side, 900 off the top and bottom.
		let ranges = fitted.translationRanges(scale: 3, rotation: 0)
		#expect(ranges.x == -1600...1600)
		#expect(ranges.y == -900...900)
	}

	@Test("The configured range stays a floor when the overhang is smaller")
	func smallOverhangKeepsTheFloor() {
		// At 1.2x only 160 hangs off each side — less than the configured 500.
		let ranges = fitted.translationRanges(scale: 1.2, rotation: 0)
		#expect(ranges.x == -500...500)
	}

	@Test("A quarter turn swaps which way the image hangs out")
	func rotationSwapsTheOverhang() {
		let ranges = fitted.translationRanges(scale: 2, rotation: 90)
		// Turned upright, the 3200x1800 image spans 1800 across and 3200 down.
		#expect(ranges.x == -500...500)
		#expect(ranges.y.upperBound.isApproximately(1150))
	}

	@Test("Without a known layout the configured range is all there is")
	func noLayoutKeepsConfiguredRange() {
		let ranges = RTSPTransformLimits().translationRanges(scale: 3, rotation: 0)
		#expect(ranges.x == -500...500)
	}

	@Test("Dragging a zoomed image reaches its far edge")
	func panReachesTheEdgeWhenZoomedIn() {
		let panned = RTSPTransform(scale: 3).panned(by: CGPoint(x: -3000, y: 0), limits: fitted)
		#expect(panned.translation.x == -1600)
	}

	@Test("The room a zoom creates counts for the same gesture")
	func zoomIsClampedAgainstItsOwnScale() {
		// Zooming to 3x around a point far off-centre demands more translation
		// than 1x allows; it is the room at 3x that decides.
		let zoomed = RTSPTransform().zoomed(by: 3, around: CGPoint(x: 700, y: 0), limits: fitted)
		#expect(zoomed.scale == 3)
		#expect(zoomed.translation.x.isApproximately(-1400))
	}

	@Test("Zooming back out pulls the image back into range")
	func zoomingOutReclampsTranslation() {
		let wide = RTSPTransform(scale: 3, translation: CGPoint(x: 1600, y: 0))
		let zoomedOut = wide.zoomed(by: 1.0 / 3.0, around: .zero, limits: fitted)
		#expect(zoomedOut.scale.isApproximately(1))
		#expect(zoomedOut.translation.x <= 500)
	}

	// MARK: - Interaction options

	@Test("`all` covers every gesture")
	func allCoversEveryGesture() {
		#expect(RTSPVideoInteraction.all.contains(.pan))
		#expect(RTSPVideoInteraction.all.contains(.zoom))
		#expect(RTSPVideoInteraction.all.contains(.rotate))
		#expect(!RTSPVideoInteraction().contains(.pan))
	}
}

private extension CGFloat {
	func isApproximately(_ other: CGFloat) -> Bool {
		abs(self - other) < 0.0001
	}
}

#if os(macOS)

// MARK: - Scroll wheel

/// Drives the real macOS path — synthesized scroll events through the gesture
/// controller and into the view — so the wiring from event to transform to
/// `onTransformChange` is covered, not just the arithmetic.
@Suite("Scroll wheel interaction")
@MainActor
struct RTSPScrollInteractionTests {

	private func makeView(interaction: RTSPVideoInteraction = .all) -> (RTSPMetalView, RTSPTransformGestureController) {
		let view = RTSPMetalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
		view.interaction = interaction
		return (view, RTSPTransformGestureController(view: view))
	}

	/// A precise (trackpad-style) scroll event; `option` makes it a zoom.
	private func scrollEvent(deltaX: Int32, deltaY: Int32, option: Bool = false) -> NSEvent {
		let cgEvent = CGEvent(
			scrollWheelEvent2Source: nil,
			units: .pixel,
			wheelCount: 2,
			wheel1: deltaY,
			wheel2: deltaX,
			wheel3: 0
		)
		cgEvent?.flags = option ? .maskAlternate : []
		return NSEvent(cgEvent: cgEvent!)!
	}

	@Test("Scrolling pans and reports the new transform")
	func scrollPans() {
		let (view, controller) = makeView()
		var reported: RTSPTransform?
		view.onTransformChange = { reported = $0 }

		#expect(controller.handleScroll(scrollEvent(deltaX: 30, deltaY: -20)))

		#expect(view.translation == CGPoint(x: 30, y: -20))
		#expect(view.scale == 1)
		#expect(reported?.translation == CGPoint(x: 30, y: -20))
	}

	@Test("Option-scrolling zooms instead of panning")
	func optionScrollZooms() {
		let (view, controller) = makeView()

		#expect(controller.handleScroll(scrollEvent(deltaX: 0, deltaY: 60, option: true)))

		#expect(view.scale > 1)
		#expect(view.rotation == 0)
	}

	@Test("Option-scrolling the other way zooms back out")
	func optionScrollOutShrinks() {
		let (view, controller) = makeView()

		#expect(controller.handleScroll(scrollEvent(deltaX: 0, deltaY: -60, option: true)))

		#expect(view.scale < 1)
	}

	@Test("A scroll is left to the responder chain when panning is off")
	func scrollIgnoredWhenDisabled() {
		let (view, controller) = makeView(interaction: .zoom)

		#expect(!controller.handleScroll(scrollEvent(deltaX: 30, deltaY: 0)))
		#expect(view.translation == .zero)
	}

	@Test("An empty scroll changes nothing")
	func emptyScrollIsIgnored() {
		let (view, controller) = makeView()
		var reported: RTSPTransform?
		view.onTransformChange = { reported = $0 }

		#expect(!controller.handleScroll(scrollEvent(deltaX: 0, deltaY: 0)))
		#expect(reported == nil)
	}
}

#endif
