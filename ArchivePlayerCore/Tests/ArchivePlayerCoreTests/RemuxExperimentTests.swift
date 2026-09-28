import XCTest
import AVFoundation
import Darwin

/// Local macOS experiment, not a decoder support declaration for all Apple devices.
@MainActor
final class RemuxExperimentTests: XCTestCase {
    func testLocalOriginalAndFragmentedMP4Capabilities() async throws {
        guard let directory = ProcessInfo.processInfo.environment["REMUX_EXPERIMENT_DIR"] else {
            throw XCTSkip("Generate fixtures with Scripts/RemuxExperiment.sh and set REMUX_EXPERIMENT_DIR")
        }
        for original in ["h264-aac.mkv", "mpeg2-ac3.vob", "mpeg2-ac3.ts"] {
            for name in [original, original + ".fragmented.mp4"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let start = ProcessInfo.processInfo.systemUptime
                let cpuStart = Double(clock()) / Double(CLOCKS_PER_SEC)
                let asset = AVURLAsset(url: url)
                do {
                    let playable = try await asset.load(.isPlayable)
                    let tracks = try await asset.load(.tracks)
                    var descriptions = [String]()
                    for track in tracks {
                        let language = try await track.load(.languageCode) ?? "unknown"
                        let formats = try await track.load(.formatDescriptions)
                        let types = formats.map { String(CMFormatDescriptionGetMediaSubType($0), radix: 16) }.joined(separator: ",")
                        descriptions.append("\(track.mediaType.rawValue):\(types):\(language)")
                    }
                    let assetWall = ProcessInfo.processInfo.systemUptime - start
                    var audioDecode = [Bool]()
                    for track in tracks where track.mediaType == .audio {
                        let reader = try AVAssetReader(asset: asset)
                        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                        guard reader.canAdd(decoded) else { audioDecode.append(false); continue }
                        reader.add(decoded)
                        let started = reader.startReading()
                        let sample = started ? decoded.copyNextSampleBuffer() : nil
                        audioDecode.append(sample.map { CMSampleBufferGetNumSamples($0) > 0 } ?? false)
                        reader.cancelReading()
                    }
                    let item = AVPlayerItem(asset: asset)
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    player.play()
                    let playerStart = ProcessInfo.processInfo.systemUptime
                    var gotFrame = false
                    while ProcessInfo.processInfo.systemUptime - playerStart < 5 {
                        if item.status == .failed { break }
                        let time = output.itemTime(forHostTime: CACurrentMediaTime())
                        if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                            gotFrame = true; break
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let firstFrameWall = ProcessInfo.processInfo.systemUptime - playerStart
                    let progress = player.currentTime().seconds
                    player.pause()
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    let totalCPU = Double(clock()) / Double(CLOCKS_PER_SEC) - cpuStart
                    print("REMUX_AV name=\(name) playable=\(playable) tracks=\(descriptions) audioPCM=\(audioDecode) assetWall=\(assetWall) firstFrame=\(gotFrame) frameWait=\(firstFrameWall) itemStatus=\(item.status.rawValue) time=\(progress) totalProcessCPU=\(totalCPU) processPeakRSS=\(usage.ru_maxrss) error=\(String(describing: item.error))")
                    if name == "h264-aac.mkv.fragmented.mp4" {
                        XCTAssertTrue(playable)
                        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 2)
                        XCTAssertTrue(gotFrame, "H.264 fragmented MP4 baseline should emit a decoded frame")
                        XCTAssertEqual(audioDecode, [true, true])
                    }
                } catch {
                    print("REMUX_AV name=\(name) assetError=\(error) wall=\(ProcessInfo.processInfo.systemUptime - start)")
                    if name == "h264-aac.mkv.fragmented.mp4" { throw error }
                }
            }
        }
    }
}
