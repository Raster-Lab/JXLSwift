import XCTest
@testable import JXLSwift
import Foundation

/// Thread safety tests for concurrent encoding and decoding operations.
/// Tests that the library can handle multiple concurrent operations safely.
final class ThreadSafetyTests: XCTestCase {
    
    // MARK: - Concurrent Encoding Tests
    
    func testEncoder_ConcurrentEncodingSeparateInstances_Succeeds() {
        let expectation = self.expectation(description: "Concurrent encoding")
        expectation.expectedFulfillmentCount = 10
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<10 {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                // Fill with unique pattern per thread
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i * 10))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                let encoder = JXLEncoder(options: .fast)
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    func testEncoder_ConcurrentEncodingSharedEncoder_Succeeds() {
        let expectation = self.expectation(description: "Concurrent encoding with shared encoder")
        expectation.expectedFulfillmentCount = 10
        
        let encoder = JXLEncoder(options: .fast)
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<10 {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i * 10))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    func testEncoder_ConcurrentEncodingDifferentQuality_Succeeds() {
        let expectation = self.expectation(description: "Concurrent encoding different qualities")
        expectation.expectedFulfillmentCount = 9
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let qualities = [25, 50, 75, 90, 95, 98, 99, 100]
        
        for (index, quality) in qualities.enumerated() {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(y))
                        frame.setPixel(x: x, y: y, channel: 2, value: 128.0)
                    }
                }
                
                let encoder = JXLEncoder(options: quality < 100 ? .lossy(quality: quality) : .lossless)
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed for quality \(quality) (thread \(index)): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    // MARK: - Concurrent Decoding Tests
    
    func testDecoder_ConcurrentDecodingSeparateInstances_Succeeds() throws {
        // First, encode a test image
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: Float(x))
                frame.setPixel(x: x, y: y, channel: 1, value: Float(y))
                frame.setPixel(x: x, y: y, channel: 2, value: 128.0)
            }
        }
        
        let encoder = JXLEncoder(options: .fast)
        let encoded = try encoder.encode(frame)
        let jxlData = encoded.data
        
        let expectation = self.expectation(description: "Concurrent decoding")
        expectation.expectedFulfillmentCount = 10
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<10 {
            queue.async {
                let decoder = JXLDecoder()
                do {
                    _ = try decoder.decode(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Decoding failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    func testDecoder_ConcurrentDecodingSharedDecoder_Succeeds() throws {
        // Encode test image
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: Float(x * 2))
                frame.setPixel(x: x, y: y, channel: 1, value: Float(y * 2))
                frame.setPixel(x: x, y: y, channel: 2, value: 200.0)
            }
        }
        
        let encoder = JXLEncoder(options: .fast)
        let encoded = try encoder.encode(frame)
        let jxlData = encoded.data
        
        let expectation = self.expectation(description: "Concurrent decoding shared decoder")
        expectation.expectedFulfillmentCount = 10
        
        let decoder = JXLDecoder()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<10 {
            queue.async {
                do {
                    _ = try decoder.decode(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Decoding failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    // MARK: - Concurrent Encode/Decode Tests
    
    func testConcurrentEncodeAndDecode_Succeeds() throws {
        let expectation = self.expectation(description: "Concurrent encode and decode")
        expectation.expectedFulfillmentCount = 20  // 10 encodes + 10 decodes
        
        // Create initial encoded data
        var initialFrame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<initialFrame.height {
            for x in 0..<initialFrame.width {
                initialFrame.setPixel(x: x, y: y, channel: 0, value: 100.0)
                initialFrame.setPixel(x: x, y: y, channel: 1, value: 150.0)
                initialFrame.setPixel(x: x, y: y, channel: 2, value: 200.0)
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let encoded = try encoder.encode(initialFrame)
        let jxlData = encoded.data
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        // Start encoding operations
        for i in 0..<10 {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i * 10))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                let encoder = JXLEncoder(options: .fast)
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed in thread \(i): \(error)")
                }
            }
        }
        
        // Start decoding operations
        for i in 0..<10 {
            queue.async {
                let decoder = JXLDecoder()
                do {
                    _ = try decoder.decode(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Decoding failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    // MARK: - Concurrent Hardware Detection Tests
    
    func testHardwareCapabilities_ConcurrentDetection_Consistent() {
        let expectation = self.expectation(description: "Concurrent hardware detection")
        expectation.expectedFulfillmentCount = 20
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        var results: [HardwareCapabilities] = []
        let resultsLock = NSLock()
        
        for _ in 0..<20 {
            queue.async {
                let capabilities = HardwareCapabilities.detect()
                
                resultsLock.lock()
                results.append(capabilities)
                resultsLock.unlock()
                
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 10.0)
        
        // All detections should return the same values
        let first = results[0]
        for capability in results {
            XCTAssertEqual(capability.cpuArchitecture, first.cpuArchitecture)
            XCTAssertEqual(capability.coreCount, first.coreCount)
            XCTAssertEqual(capability.hasNEON, first.hasNEON)
            XCTAssertEqual(capability.hasAccelerate, first.hasAccelerate)
        }
    }
    
    // MARK: - Concurrent ImageFrame Manipulation Tests
    
    func testImageFrame_ConcurrentPixelAccess_DifferentFrames() {
        let expectation = self.expectation(description: "Concurrent pixel access")
        expectation.expectedFulfillmentCount = 10
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<10 {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                
                // Write pixels
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                // Read pixels
                var sum: Float = 0.0
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        sum += frame.getPixel(x: x, y: y, channel: 0)
                        sum += frame.getPixel(x: x, y: y, channel: 1)
                        sum += frame.getPixel(x: x, y: y, channel: 2)
                    }
                }
                
                XCTAssertGreaterThan(sum, 0)
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 30.0)
    }
    
    // MARK: - Stress Tests
    
    func testEncoder_HighConcurrencyStress_Succeeds() {
        let expectation = self.expectation(description: "High concurrency stress")
        expectation.expectedFulfillmentCount = 50
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<50 {
            queue.async {
                var frame = ImageFrame(width: 32, height: 32, channels: 3)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i % 256))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                let encoder = JXLEncoder(options: .fastest)
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed in high-concurrency thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 60.0)
    }
    
    func testDecoder_HighConcurrencyStress_Succeeds() throws {
        // Encode test data once
        var frame = ImageFrame(width: 32, height: 32, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: Float(x))
                frame.setPixel(x: x, y: y, channel: 1, value: Float(y))
                frame.setPixel(x: x, y: y, channel: 2, value: 128.0)
            }
        }
        
        let encoder = JXLEncoder(options: .fastest)
        let encoded = try encoder.encode(frame)
        let jxlData = encoded.data
        
        let expectation = self.expectation(description: "High concurrency decode stress")
        expectation.expectedFulfillmentCount = 50
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<50 {
            queue.async {
                let decoder = JXLDecoder()
                do {
                    _ = try decoder.decode(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Decoding failed in high-concurrency thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 60.0)
    }
    
    // MARK: - Mixed Operations Tests
    
    func testMixedOperations_EncodingDecodingMetadata_Succeeds() throws {
        // Create test data with metadata
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: Float(x))
                frame.setPixel(x: x, y: y, channel: 1, value: Float(y))
                frame.setPixel(x: x, y: y, channel: 2, value: 128.0)
            }
        }
        
        let encoder = JXLEncoder(options: .fast)
        let encoded = try encoder.encode(frame)
        let jxlData = encoded.data
        
        let expectation = self.expectation(description: "Mixed operations")
        expectation.expectedFulfillmentCount = 30  // 10 encode + 10 decode + 10 metadata
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        // Encoding operations
        for i in 0..<10 {
            queue.async {
                var frame = ImageFrame(width: 64, height: 64, channels: 3)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        frame.setPixel(x: x, y: y, channel: 0, value: Float(i))
                        frame.setPixel(x: x, y: y, channel: 1, value: Float(x))
                        frame.setPixel(x: x, y: y, channel: 2, value: Float(y))
                    }
                }
                
                let encoder = JXLEncoder(options: .fast)
                do {
                    _ = try encoder.encode(frame)
                    expectation.fulfill()
                } catch {
                    XCTFail("Encoding failed: \(error)")
                }
            }
        }
        
        // Decoding operations
        for i in 0..<10 {
            queue.async {
                let decoder = JXLDecoder()
                do {
                    _ = try decoder.decode(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Decoding failed in thread \(i): \(error)")
                }
            }
        }
        
        // Metadata extraction operations
        for i in 0..<10 {
            queue.async {
                let decoder = JXLDecoder()
                do {
                    _ = try decoder.extractMetadata(jxlData)
                    expectation.fulfill()
                } catch {
                    XCTFail("Metadata extraction failed in thread \(i): \(error)")
                }
            }
        }
        
        waitForExpectations(timeout: 60.0)
    }
    
    // MARK: - Data Race Detection Tests
    
    func testEncodingOptions_ConcurrentAccess_NoDataRace() {
        let expectation = self.expectation(description: "Concurrent options access")
        expectation.expectedFulfillmentCount = 20
        
        let options = EncodingOptions.fast
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<20 {
            queue.async {
                // Read operations
                _ = options.mode
                _ = options.effort
                _ = options.threadCount
                _ = options.useAccelerate
                _ = options.useMetal
                
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 10.0)
    }
    
    func testCompressionStats_ConcurrentAccess_NoDataRace() throws {
        var frame = ImageFrame(width: 64, height: 64, channels: 3)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, channel: 0, value: Float(x))
                frame.setPixel(x: x, y: y, channel: 1, value: Float(y))
                frame.setPixel(x: x, y: y, channel: 2, value: 128.0)
            }
        }
        
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        let stats = result.stats
        
        let expectation = self.expectation(description: "Concurrent stats access")
        expectation.expectedFulfillmentCount = 20
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for _ in 0..<20 {
            queue.async {
                // Read stats concurrently
                _ = stats.originalSize
                _ = stats.compressedSize
                _ = stats.compressionRatio
                _ = stats.encodingTime
                _ = stats.peakMemoryUsage
                
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 10.0)
    }
}
