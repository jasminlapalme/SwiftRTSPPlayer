# SwiftRTSPPlayer

Hardware-accelerated RTSP player for iOS, macOS, tvOS and visionOS, distributed as a Swift Package. The pipeline wires FFmpeg (RTSP demuxing), VideoToolbox (H.264 decoding) and Metal (zero-copy rendering) under Swift 6 strict concurrency.

## Platforms

- iOS 18+
- macOS 15+
- tvOS 18+
- visionOS 1+

Swift 6.3 / Swift Tools 6.3, with `swiftLanguageModes: [.v6]`.

## Installation

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jasminlapalme/SwiftRTSPPlayer.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "SwiftRTSPPlayer", package: "SwiftRTSPPlayer")
        ]
    )
]
```

Or via Xcode: *File → Add Package Dependencies…* and paste the repository URL.

The package ships `Frameworks/FFmpeg.xcframework` (minimal build: RTSP/TCP/UDP, RTSP demuxer, H.264/HEVC parser, H.264 decoder, VideoToolbox). The binary is checked in — no FFmpeg compilation is required to consume the package.

## Usage

```swift
import SwiftUI
import SwiftRTSPPlayer

struct ContentView: View {
    var body: some View {
        RTSPPlayerView(url: URL(string: "rtsp://192.168.1.42:554/stream")!)
    }
}
```

### Transforms

`RTSPPlayerView` accepts rotation, scale, translation and a fisheye correction model:

```swift
RTSPPlayerView(
    url: url,
    rotation: .pi / 2,
    scale: 1.2,
    translation: CGPoint(x: 0.05, y: 0),
    fisheyeCorrection: FisheyeCorrection(k1v: 0.3)
)
```

`FisheyeCorrection` parameterizes a polynomial undistortion in `θ = atan(r)`, suited to wide-angle lenses (~110–130° FOV). Use `FisheyeCorrection.identity` to disable the correction.

### Direct manipulation

Pass the transforms as bindings instead of values and the viewer can adjust the framing on the video itself — the gestures write back through the bindings, so a `RTSPTransformControlPanel` driven by the same state follows along:

```swift
RTSPPlayerView(
    url: url,
    rotation: $rotation,
    scale: $scale,
    translation: $translation
)
```

| Gesture | macOS | iOS / visionOS |
| --- | --- | --- |
| Move | click-drag, or two-finger scroll | one-finger drag |
| Zoom | trackpad pinch, or Option-scroll | pinch |
| Rotate | trackpad two-finger rotate | two-finger rotate |

Zooming keeps the detail under the pointer (or under the pinch) in place. `interaction:` selects which gestures are accepted — `.all` by default, or any combination of `.pan`, `.zoom` and `.rotate`. tvOS has no pointer, so the gestures are unavailable there and the panel remains the way to adjust the framing.

`transformLimits:` bounds how far the gestures may go. Its translation ranges are a *floor*, not a ceiling: whenever the image hangs outside the view — zoomed in, or turned — the range opens up to half the overhang, which is exactly what it takes to bring any edge of the image into view. The rotation of the image is accounted for, so the room is right at any angle. Below that the configured range still applies, so an image smaller than its view can be pushed around as freely as before. The control panel's sliders keep their own (fixed) ranges but widen to carry a value a gesture has taken further, rather than clamping it back when touched.

### Control panel

`RTSPTransformControlPanel` exposes the transforms — and optionally fisheye correction and ONVIF camera selection — through a tabbed panel, intended as an `.overlay`. On iOS and macOS the tabs use native controls (sliders with numeric fields, segmented tabs); on tvOS they use a focus-driven, swipe-based UI suited to the Siri remote:

```swift
RTSPPlayerView(url: url, rotation: rotation, scale: scale, translation: translation, fisheyeCorrection: fisheye)
    .overlay(alignment: .bottom) {
        RTSPTransformControlPanel(
            scale: $scale,
            translation: $translation,
            rotation: $rotation,
            fisheyeCorrection: $fisheye
        )
        .padding()
    }
```

The three tabs are also public views, for apps that want to compose their own panel instead of using `RTSPTransformControlPanel`:

- `RTSPTransformControls` — scale / translation / rotation sliders
- `RTSPFisheyeControls` — the four `FisheyeCorrection` coefficients
- `RTSPCameraListView` — ONVIF discovery, credentials and manual RTSP URL entry, writing the chosen stream to a `Binding<RTSPCameraSelection?>`

### Playback state

`RTSPPlaybackStatusOverlay` provides visual feedback on the connection state (`stopped`, `connecting`, `playing`, `failed`). The overlay is attached automatically by `RTSPPlayerView`.

## Architecture

```
RTSP URL
  → RTSPDemuxer (actor)        — FFmpeg: connects, extracts SPS/PPS + Annex-B frames
  → VideoToolboxDecoder         — VTDecompressionSession: H.264 → CVPixelBuffer (NV12)
  → DecodedFrame                — (CVPixelBuffer, PTS)
  → MetalVideoRenderer          — CVMetalTextureCache zero-copy → Metal → CAMetalLayer
```

`RTSPPipeline` (actor) orchestrates demuxer and decoder, bridges their `AsyncStream`s, and handles reconnection with exponential backoff plus cancellation cleanup.

Notable details:

- The demuxer converts Annex-B (MPEG-TS start codes) to AVCC (length-prefixed) for VideoToolbox.
- NALU filtering keeps only IDR (type 5) and non-IDR (type 1) slices and drops leading P-frames until an IDR is seen, avoiding decoder corruption on attach.
- The Metal fragment shader performs limited-range YUV→RGB conversion using BT.709 coefficients.

## Demo

`Demos/DemoSwiftRTSPPlayer` is an iOS/macOS app that consumes the library as an external client. Set the `RTSP_URL` environment variable in the Xcode scheme to point at a real camera (schemes live under `.xcuserdata/` and are not committed, so credentials embedded in the URL stay on your machine).

## Development

```bash
# Build
swift build

# Tests
swift test

# Single test
swift test --filter SwiftRTSPPlayerTests/<TestName>

# Lint (requires: brew install swiftlint)
./Scripts/lint.sh

# Rebuild FFmpeg.xcframework from source (rarely needed)
./Scripts/build_ffmpeg.sh           # dynamic (default, required for SwiftUI Previews)
./Scripts/build_ffmpeg.sh static    # static
```

### Style

- Tab indentation, indent size 2, LF line endings (`.editorconfig`).
- Line length: warn at 140, error at 180.
- SwiftLint strict mode — run `./Scripts/lint.sh` before committing.

## License

TBD.
