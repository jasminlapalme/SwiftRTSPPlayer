// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// By default the FFmpeg.xcframework is fetched from the matching GitHub
// release. Set `SWIFTRTSP_LOCAL_FFMPEG=1` in the environment to use the
// xcframework under `Frameworks/` instead — useful when iterating on the
// FFmpeg build via `./Scripts/build_ffmpeg.sh`. The remote URL and checksum
// below are rewritten by `./Scripts/release_ffmpeg.sh` after each upload.
let useLocalFFmpeg = ProcessInfo.processInfo.environment["SWIFTRTSP_LOCAL_FFMPEG"] != nil

let ffmpegTarget: Target = useLocalFFmpeg
	? .binaryTarget(
		name: "FFmpeg",
		path: "Frameworks/FFmpeg.xcframework"
	)
	: .binaryTarget(
		name: "FFmpeg",
		url: "https://github.com/jasminlapalme/SwiftRTSPPlayer/releases/download/0.2.1/FFmpeg.xcframework.zip",
		checksum: "953a7b6cdc4ff51d8d1d0a8b63aa34b514258e9bf9257c292f6089b250503afe"
	)

let package = Package(
	name: "SwiftRTSPPlayer",
	defaultLocalization: "en",
	platforms: [
		.iOS(.v18),
		.macOS(.v15),
		.visionOS(.v2),
		.tvOS(.v18)
	],
	products: [
		// Products define the executables and libraries a package produces, making them visible to other packages.
		.library(
			name: "SwiftRTSPPlayer",
			targets: ["SwiftRTSPPlayer"]
		),
	],
	targets: [
		// Targets are the basic building blocks of a package, defining a module or a test suite.
		// Targets can depend on other targets in this package and products from dependencies.
		.target(
			name: "SwiftRTSPPlayer",
			dependencies: ["FFmpeg"],
			// The shaders also ship as source: SwiftPM has no Metal rule, so the
			// renderer compiles them at launch. See MetalVideoRenderer.
			resources: [.process("Resources"), .process("Shaders")],
			linkerSettings: [
				// Kept for the `static` flavour of FFmpeg.xcframework — the
				// .a archives reference symbols from these system libraries
				// (zlib, iconv, bz2). The `dynamic` flavour bakes them in as
				// load commands and these settings become a no-op.
				.linkedLibrary("z"),
				.linkedLibrary("iconv"),
				.linkedLibrary("bz2")
			]
		),
		.testTarget(
			name: "SwiftRTSPPlayerTests",
			dependencies: ["SwiftRTSPPlayer"]
		),
		ffmpegTarget
	],
	swiftLanguageModes: [.v6]
)
