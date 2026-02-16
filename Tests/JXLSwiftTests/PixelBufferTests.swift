import XCTest
@testable import JXLSwift

final class PixelBufferTests: XCTestCase {

    // MARK: - Initialization Tests

    func testPixelBuffer_DefaultInit_CreatesZeroedBuffer() {
        let buffer = PixelBuffer(width: 8, height: 8, channels: 3)

        XCTAssertEqual(buffer.width, 8)
        XCTAssertEqual(buffer.height, 8)
        XCTAssertEqual(buffer.channels, 3)
        XCTAssertEqual(buffer.pixelType, .uint8)
        XCTAssertEqual(buffer.data.count, 8 * 8 * 3 * 1) // 192 bytes
        XCTAssertTrue(buffer.data.allSatisfy { $0 == 0 })
    }

    func testPixelBuffer_UInt16Init_CorrectSize() {
        let buffer = PixelBuffer(width: 4, height: 4, channels: 1, pixelType: .uint16)

        XCTAssertEqual(buffer.data.count, 4 * 4 * 1 * 2) // 32 bytes
    }

    func testPixelBuffer_Float32Init_CorrectSize() {
        let buffer = PixelBuffer(width: 2, height: 2, channels: 3, pixelType: .float32)

        XCTAssertEqual(buffer.data.count, 2 * 2 * 3 * 4) // 48 bytes
    }

    func testPixelBuffer_InitFromData_Success() throws {
        let data = [UInt8](repeating: 42, count: 4 * 4 * 3)
        let buffer = try PixelBuffer(data: data, width: 4, height: 4, channels: 3)

        XCTAssertEqual(buffer.width, 4)
        XCTAssertEqual(buffer.height, 4)
        XCTAssertEqual(buffer.data.count, 48)
        XCTAssertTrue(buffer.data.allSatisfy { $0 == 42 })
    }

    func testPixelBuffer_InitFromData_SizeMismatch_Throws() {
        let data = [UInt8](repeating: 0, count: 10) // Wrong size
        XCTAssertThrowsError(try PixelBuffer(data: data, width: 4, height: 4, channels: 3)) { error in
            XCTAssertTrue(error is PixelBufferError)
            if case PixelBufferError.dataSizeMismatch(let expected, let actual) = error {
                XCTAssertEqual(expected, 48)
                XCTAssertEqual(actual, 10)
            } else {
                XCTFail("Expected dataSizeMismatch error")
            }
        }
    }

    // MARK: - Tiling Tests

    func testPixelBuffer_Tiles_ExactDivision() {
        let buffer = PixelBuffer(width: 16, height: 16, channels: 1)
        let tiles = buffer.tiles(size: 8)

        XCTAssertEqual(tiles.count, 4) // 2x2 tiles
        XCTAssertEqual(tiles[0].originX, 0)
        XCTAssertEqual(tiles[0].originY, 0)
        XCTAssertEqual(tiles[0].width, 8)
        XCTAssertEqual(tiles[0].height, 8)

        XCTAssertEqual(tiles[1].originX, 8)
        XCTAssertEqual(tiles[1].originY, 0)

        XCTAssertEqual(tiles[2].originX, 0)
        XCTAssertEqual(tiles[2].originY, 8)

        XCTAssertEqual(tiles[3].originX, 8)
        XCTAssertEqual(tiles[3].originY, 8)
    }

    func testPixelBuffer_Tiles_NonExactDivision() {
        let buffer = PixelBuffer(width: 10, height: 10, channels: 1)
        let tiles = buffer.tiles(size: 8)

        XCTAssertEqual(tiles.count, 4) // 2x2 tiles
        // Top-left: full 8x8
        XCTAssertEqual(tiles[0].width, 8)
        XCTAssertEqual(tiles[0].height, 8)
        // Top-right: 2x8 (partial width)
        XCTAssertEqual(tiles[1].width, 2)
        XCTAssertEqual(tiles[1].height, 8)
        // Bottom-left: 8x2 (partial height)
        XCTAssertEqual(tiles[2].width, 8)
        XCTAssertEqual(tiles[2].height, 2)
        // Bottom-right: 2x2 (partial both)
        XCTAssertEqual(tiles[3].width, 2)
        XCTAssertEqual(tiles[3].height, 2)
    }

    func testPixelBuffer_Tiles_SinglePixel() {
        let buffer = PixelBuffer(width: 1, height: 1, channels: 1)
        let tiles = buffer.tiles(size: 256)

        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].width, 1)
        XCTAssertEqual(tiles[0].height, 1)
    }

    func testPixelBuffer_Tiles_LargerThanImage() {
        let buffer = PixelBuffer(width: 4, height: 4, channels: 1)
        let tiles = buffer.tiles(size: 256)

        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].width, 4)
        XCTAssertEqual(tiles[0].height, 4)
    }

    // MARK: - Tile Data Extraction and Writing

    func testPixelBuffer_ExtractAndWriteTileData_RoundTrip() {
        var buffer = PixelBuffer(width: 8, height: 8, channels: 1)

        // Fill buffer with known pattern
        for i in 0..<buffer.data.count {
            buffer.data[i] = UInt8(i % 256)
        }

        let tile = PixelBuffer.Tile(originX: 2, originY: 2, width: 4, height: 4)
        let tileData = buffer.extractTileData(tile: tile, channel: 0)

        // Verify extracted data
        XCTAssertEqual(tileData.count, 4 * 4)

        // First row of tile should be buffer[2*8+2 .. 2*8+5] = [18,19,20,21]
        XCTAssertEqual(tileData[0], UInt8((2 * 8 + 2) % 256))
        XCTAssertEqual(tileData[1], UInt8((2 * 8 + 3) % 256))
        XCTAssertEqual(tileData[2], UInt8((2 * 8 + 4) % 256))
        XCTAssertEqual(tileData[3], UInt8((2 * 8 + 5) % 256))

        // Now write it back to a zeroed buffer
        var buffer2 = PixelBuffer(width: 8, height: 8, channels: 1)
        buffer2.writeTileData(tileData, tile: tile, channel: 0)

        // Verify only the tile region was written
        let extracted = buffer2.extractTileData(tile: tile, channel: 0)
        XCTAssertEqual(extracted, tileData)

        // Verify outside the tile is still zero
        XCTAssertEqual(buffer2.data[0], 0)
        XCTAssertEqual(buffer2.data[1], 0)
    }

    // MARK: - Conversion Tests

    func testPixelBuffer_ToImageFrame_RoundTrip() {
        var buffer = PixelBuffer(width: 4, height: 4, channels: 3)
        buffer.data[0] = 100
        buffer.data[1] = 200

        let frame = buffer.toImageFrame()
        XCTAssertEqual(frame.width, 4)
        XCTAssertEqual(frame.height, 4)
        XCTAssertEqual(frame.channels, 3)
        XCTAssertEqual(frame.data[0], 100)
        XCTAssertEqual(frame.data[1], 200)
    }

    func testPixelBuffer_FromImageFrame() {
        var frame = ImageFrame(width: 4, height: 4, channels: 3)
        frame.data[0] = 55

        let buffer = PixelBuffer.from(frame: frame)
        XCTAssertEqual(buffer.width, 4)
        XCTAssertEqual(buffer.height, 4)
        XCTAssertEqual(buffer.channels, 3)
        XCTAssertEqual(buffer.data[0], 55)
    }

    // MARK: - Error Description Tests

    func testPixelBufferError_Description() {
        let error = PixelBufferError.dataSizeMismatch(expected: 100, actual: 50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("100"))
        XCTAssertTrue(error.errorDescription!.contains("50"))
    }
}
