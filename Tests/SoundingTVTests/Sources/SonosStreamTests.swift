import XCTest
import Network
@testable import SoundingTV

final class SonosStreamTests: XCTestCase {
    private func withChannels(_ left: [Float], _ right: [Float], _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> Void) {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: max(1, left.count))
        let r = UnsafeMutablePointer<Float>.allocate(capacity: max(1, right.count))
        l.initialize(from: left, count: left.count)
        r.initialize(from: right, count: right.count)
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        pointers[0] = l
        pointers[1] = r
        body(UnsafePointer(pointers))
        l.deallocate()
        r.deallocate()
        pointers.deallocate()
    }

    private func readAll(_ ring: SonosAudioRingBuffer, frames: Int) -> ([Float], [Float]) {
        var left = [Float](repeating: -1, count: frames)
        var right = [Float](repeating: -1, count: frames)
        var count = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
                pointers[0] = l.baseAddress!
                pointers[1] = r.baseAddress!
                count = ring.read(into: UnsafePointer(pointers), channelCount: 2, frames: frames)
                pointers.deallocate()
            }
        }
        return (Array(left.prefix(count)), Array(right.prefix(count)))
    }

    func testRingBufferWrapsAround() {
        let ring = SonosAudioRingBuffer(capacityFrames: 8, channels: 2)
        withChannels([1, 2, 3, 4, 5, 6], [11, 12, 13, 14, 15, 16]) { XCTAssertEqual(ring.write($0, channelCount: 2, frames: 6), 6) }
        XCTAssertEqual(readAll(ring, frames: 4).0, [1, 2, 3, 4])
        withChannels([7, 8, 9, 10, 11], [17, 18, 19, 20, 21]) { XCTAssertEqual(ring.write($0, channelCount: 2, frames: 5), 5) }
        let (left, right) = readAll(ring, frames: 16)
        XCTAssertEqual(left, [5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(right, [15, 16, 17, 18, 19, 20, 21])
        XCTAssertEqual(ring.framesWritten, 11)
        XCTAssertEqual(ring.droppedFrames, 0)
    }

    func testRingBufferDropsOnOverflow() {
        let ring = SonosAudioRingBuffer(capacityFrames: 4, channels: 2)
        withChannels([1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 6]) { XCTAssertEqual(ring.write($0, channelCount: 2, frames: 6), 4) }
        XCTAssertEqual(ring.droppedFrames, 2)
        withChannels([9], [9]) { XCTAssertEqual(ring.write($0, channelCount: 2, frames: 1), 0) }
        XCTAssertEqual(ring.droppedFrames, 3)
        XCTAssertEqual(readAll(ring, frames: 8).0, [1, 2, 3, 4])
    }

    func testRingBufferUpmixesMono() {
        let ring = SonosAudioRingBuffer(capacityFrames: 4, channels: 2)
        withChannels([0.5, 0.25], []) { XCTAssertEqual(ring.write($0, channelCount: 1, frames: 2), 2) }
        let (left, right) = readAll(ring, frames: 2)
        XCTAssertEqual(left, [0.5, 0.25])
        XCTAssertEqual(right, [0.5, 0.25])
    }

    func testRingBufferSPSCConcurrentKeepsOrder() {
        let ring = SonosAudioRingBuffer(capacityFrames: 1000, channels: 2)
        let total = 200_000
        let done = expectation(description: "consumer")
        let producer = Thread {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: 97)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: 97)
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            pointers[0] = l
            pointers[1] = r
            var next = 0
            while next < total {
                let count = min(97, total - next)
                for i in 0..<count {
                    l[i] = Float(next + i)
                    r[i] = -Float(next + i)
                }
                while ring.availableFrames > ring.capacityFrames - count {}
                next += ring.write(UnsafePointer(pointers), channelCount: 2, frames: count)
            }
        }
        let consumer = Thread {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: 61)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: 61)
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
            pointers[0] = l
            pointers[1] = r
            var expected = 0
            var ok = true
            while expected < total {
                let count = ring.read(into: UnsafePointer(pointers), channelCount: 2, frames: 61)
                for i in 0..<count where l[i] != Float(expected + i) || r[i] != -Float(expected + i) {
                    ok = false
                }
                expected += count
            }
            XCTAssertTrue(ok)
            done.fulfill()
        }
        producer.start()
        consumer.start()
        wait(for: [done], timeout: 20)
        XCTAssertEqual(ring.droppedFrames, 0)
        XCTAssertEqual(ring.framesWritten, UInt64(total))
    }

    func testADTSHeaderLayout44k() throws {
        let header = try XCTUnwrap(ADTSHeader.make(payloadLength: 500, sampleRate: 44_100, channels: 2))
        XCTAssertEqual(header.count, 7)
        XCTAssertEqual(header[0], 0xFF)
        XCTAssertEqual(header[1] & 0xF0, 0xF0)
        XCTAssertEqual(header[1] & 0x01, 1)
        XCTAssertEqual(header[2] >> 6, 1)
        XCTAssertEqual((header[2] >> 2) & 0xF, 4)
        let channels = ((header[2] & 0x1) << 2) | (header[3] >> 6)
        XCTAssertEqual(channels, 2)
        let length = (Int(header[3] & 0x3) << 11) | (Int(header[4]) << 3) | Int(header[5] >> 5)
        XCTAssertEqual(length, 507)
        XCTAssertEqual(header[5] & 0x1F, 0x1F)
        XCTAssertEqual(header[6], 0xFC)
        XCTAssertEqual(header, [0xFF, 0xF1, 0x50, 0x80, 0x3F, 0x7F, 0xFC])
    }

    func testADTSHeaderLayout48k() throws {
        let header = try XCTUnwrap(ADTSHeader.make(payloadLength: 1000, sampleRate: 48_000, channels: 2))
        XCTAssertEqual((header[2] >> 2) & 0xF, 3)
        let length = (Int(header[3] & 0x3) << 11) | (Int(header[4]) << 3) | Int(header[5] >> 5)
        XCTAssertEqual(length, 1007)
        XCTAssertNil(ADTSHeader.make(payloadLength: 10, sampleRate: 12_345, channels: 2))
        XCTAssertNil(ADTSHeader.make(payloadLength: 9000, sampleRate: 48_000, channels: 2))
    }

    func testICYMetadataInjectedAtMetaInterval() {
        var interleaver = SonosICYInterleaver(metaInterval: 16)
        let audio = Data((0..<40).map { UInt8($0) })
        let out = interleaver.interleave(audio, title: "A'B")
        XCTAssertEqual(out.prefix(16), audio.prefix(16))
        let length = Int(out[16]) * 16
        XCTAssertGreaterThan(length, 0)
        let block = out[17..<(17 + length)]
        let text = String(decoding: block.prefix(while: { $0 != 0 }), as: UTF8.self)
        XCTAssertEqual(text, "StreamTitle='A\u{2019}B';")
        let resume = 17 + length
        XCTAssertEqual(out[resume..<(resume + 16)], audio[16..<32])
        XCTAssertEqual(out[resume + 16], 0)
        XCTAssertEqual(out.suffix(from: resume + 17), audio.suffix(8))
        XCTAssertEqual(interleaver.bytesUntilMetadata, 8)
        let next = interleaver.interleave(Data(count: 8), title: "Changed")
        XCTAssertGreaterThan(next.count, 9)
    }

    func testHTTPRequestParsing() throws {
        let request = try XCTUnwrap(SonosHTTPRequest(Data("GET /sounding/abc.aac?x=1 HTTP/1.1\r\nHost: a\r\nIcy-MetaData:1\r\nRange: bytes=0-\r\n\r\n".utf8)))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/sounding/abc.aac")
        XCTAssertTrue(request.wantsICYMetadata)
        XCTAssertNil(SonosHTTPRequest(Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)))
    }

    func testLatencyEstimatorMedianAndClamp() {
        var estimator = SonosLatencyEstimator()
        XCTAssertNil(estimator.current)
        let rate = 44_100.0
        var last: TimeInterval?
        for (index, jitter) in [0.0, 0.1, -0.1, 5.0, 0.05, -0.05, 0.0, 0.02].enumerated() {
            let elapsed = Double(index * 10)
            let produced = UInt64((elapsed + 2 + jitter) * rate) + 1000
            last = estimator.add(producedFrame: produced, streamStartFrame: 1000, sonosElapsed: elapsed, sampleRate: rate)
        }
        XCTAssertEqual(try XCTUnwrap(last), 2.02, accuracy: 0.03)
        var tiny = SonosLatencyEstimator()
        XCTAssertEqual(tiny.add(producedFrame: 44_100, streamStartFrame: 0, sonosElapsed: 1, sampleRate: rate), 0.2)
        var huge = SonosLatencyEstimator()
        XCTAssertEqual(huge.add(producedFrame: UInt64(30 * rate), streamStartFrame: 0, sonosElapsed: 1, sampleRate: rate), 10)
        XCTAssertEqual(huge.add(producedFrame: 0, streamStartFrame: 10, sonosElapsed: 1, sampleRate: rate), 10)
    }

    func testLatencyEstimatorKeepsWindow() {
        var estimator = SonosLatencyEstimator(window: 8)
        for index in 0..<20 {
            _ = estimator.add(producedFrame: UInt64(index + 3) * 44_100, streamStartFrame: 0, sonosElapsed: Double(index), sampleRate: 44_100)
        }
        XCTAssertEqual(estimator.samples.count, 8)
        XCTAssertEqual(estimator.current ?? 0, 3, accuracy: 0.001)
    }

    private func fetch(_ url: URL, headers: [String: String] = [:], method: String = "GET", minimumBytes: Int) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var data = Data()
        if method == "GET", http.statusCode == 200 {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= minimumBytes { break }
            }
        }
        bytes.task.cancel()
        return (http, data)
    }

    private func feedNoise(_ ring: SonosAudioRingBuffer, seconds: Double) {
        let frames = Int(seconds * 44_100)
        var generator = SystemRandomNumberGenerator()
        let left = (0..<frames).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        let right = (0..<frames).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        withChannels(left, right) { ring.write($0, channelCount: 2, frames: frames) }
    }

    private func loopback(_ url: URL, path: String? = nil) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.host = "127.0.0.1"
        if let path { components.path = path }
        return components.url!
    }

    func testServerStreamsADTSAndRejectsWrongPath() async throws {
        let server = SonosStreamServer()
        let url = try await server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))
        feedNoise(server.ringBuffer, seconds: 1)
        XCTAssertTrue(url.path.hasPrefix("/sounding/"))
        XCTAssertTrue(url.path.hasSuffix(".aac"))
        XCTAssertGreaterThanOrEqual(url.lastPathComponent.count, 36)

        let (missing, _) = try await fetch(loopback(url, path: "/sounding/guess.aac"), minimumBytes: 1)
        XCTAssertEqual(missing.statusCode, 404)

        let (head, _) = try await fetch(loopback(url), method: "HEAD", minimumBytes: 0)
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Type"), "audio/aac")

        let (response, data) = try await fetch(loopback(url), headers: ["Range": "bytes=0-"], minimumBytes: 2048)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "audio/aac")
        XCTAssertNil(response.value(forHTTPHeaderField: "icy-metaint"))
        XCTAssertGreaterThanOrEqual(data.count, 2048)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1] & 0xF0, 0xF0)
        XCTAssertGreaterThan(server.framesServedToClient, 0)
    }

    func testServerInjectsICYMetadataWhenRequested() async throws {
        let server = SonosStreamServer()
        let url = try await server.start()
        defer { server.stop() }
        server.setStreamTitle("Artist - Track")
        try await Task.sleep(for: .milliseconds(100))
        feedNoise(server.ringBuffer, seconds: 1)
        let (response, data) = try await fetch(loopback(url), headers: ["Icy-MetaData": "1"], minimumBytes: 16_200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "icy-metaint"), "16000")
        XCTAssertEqual(data[0], 0xFF)
        let length = Int(data[16_000]) * 16
        XCTAssertGreaterThan(length, 0)
        let block = data[16_001..<(16_001 + min(length, data.count - 16_001))]
        let text = String(decoding: block.prefix(while: { $0 != 0 }), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("StreamTitle='Artist - Track'"), text)
    }
}
