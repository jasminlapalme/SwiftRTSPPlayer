//
//  RTSPPipeline.swift
//  SwiftRTSPPlayer
//

import Foundation

public actor RTSPPipeline {

	private let demuxer = RTSPDemuxer()
	private let decoder = VideoToolboxDecoder()

	public init() {
		_ = FFmpegLog.install
	}

	public func stop() async {
		await demuxer.stop()
		await decoder.flush()
		await decoder.invalidate()
	}

	public func frames(url: URL) -> AsyncThrowingStream<DecodedFrame, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let decodeStream = await decoder.frames()

					// Forward decoded frames
					let decodeTask = Task {
						for await frame in decodeStream {
							continuation.yield(frame)
						}
					}

					// Feed decoder
					for try await event in await demuxer.events(url: url) {

						switch event {

						case .format(let paramsSet):
							try await decoder.configure(parameterSet: paramsSet)

						case .frame(let videoFrame):
							await decoder.decode(
								avccData: videoFrame.data,
								pts: videoFrame.pts,
								dts: videoFrame.dts
							)

						case .stopped:
							break
						}
					}

					await decoder.flush()
					await decoder.invalidate()
					decodeTask.cancel()
					continuation.finish()

				} catch {
					await decoder.invalidate()
					continuation.finish(throwing: error)
				}
			}

			continuation.onTermination = { _ in
				task.cancel()
				Task { await self.stop() }
			}
		}
	}
}
