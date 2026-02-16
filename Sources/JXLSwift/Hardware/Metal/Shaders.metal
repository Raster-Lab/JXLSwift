/// Metal Compute Shaders for JPEG XL Encoding
///
/// This file contains GPU compute kernels for hardware-accelerated encoding operations.

#include <metal_stdlib>
using namespace metal;

// MARK: - Constants

/// DCT normalization factors (precomputed)
constant float DCT_NORM_8[8] = {
    0.35355339059327376,  // 1/sqrt(8)
    0.49039264020161516,  // sqrt(2/8)
    0.49039264020161516,
    0.49039264020161516,
    0.49039264020161516,
    0.49039264020161516,
    0.49039264020161516,
    0.49039264020161516
};

/// DCT cosine table for 8-point DCT
constant float DCT_COS_TABLE[8][8] = {
    {1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0},
    {0.98078528, 0.83146961, 0.55557023, 0.19509032, -0.19509032, -0.55557023, -0.83146961, -0.98078528},
    {0.92387953, 0.38268343, -0.38268343, -0.92387953, -0.92387953, -0.38268343, 0.38268343, 0.92387953},
    {0.83146961, -0.19509032, -0.98078528, -0.55557023, 0.55557023, 0.98078528, 0.19509032, -0.83146961},
    {0.70710678, -0.70710678, -0.70710678, 0.70710678, 0.70710678, -0.70710678, -0.70710678, 0.70710678},
    {0.55557023, -0.98078528, 0.19509032, 0.83146961, -0.83146961, -0.19509032, 0.98078528, -0.55557023},
    {0.38268343, -0.92387953, 0.92387953, -0.38268343, -0.38268343, 0.92387953, -0.92387953, 0.38268343},
    {0.19509032, -0.55557023, 0.83146961, -0.98078528, 0.98078528, -0.83146961, 0.55557023, -0.19509032}
};

// MARK: - RGB to YCbCr Color Conversion

/// RGB to YCbCr color space conversion kernel (BT.601)
///
/// Converts RGB pixels to YCbCr color space in parallel on the GPU.
///
/// - Parameters:
///   - rgbBuffer: Input RGB data (3 floats per pixel, interleaved)
///   - ycbcrBuffer: Output YCbCr data (3 floats per pixel, planar)
///   - width: Image width in pixels
///   - height: Image height in pixels
kernel void rgb_to_ycbcr(
    device const float* rgbBuffer [[buffer(0)]],
    device float* ycbcrBuffer [[buffer(1)]],
    constant uint& width [[buffer(2)]],
    constant uint& height [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    uint pixelIndex = gid.y * width + gid.x;
    uint rgbOffset = pixelIndex * 3;
    
    float r = rgbBuffer[rgbOffset + 0];
    float g = rgbBuffer[rgbOffset + 1];
    float b = rgbBuffer[rgbOffset + 2];
    
    // BT.601 conversion coefficients
    float y  =  0.299f * r + 0.587f * g + 0.114f * b;
    float cb = -0.168736f * r - 0.331264f * g + 0.5f * b;
    float cr =  0.5f * r - 0.418688f * g - 0.081312f * b;
    
    // Write to planar YCbCr buffer
    uint planeSize = width * height;
    ycbcrBuffer[pixelIndex] = y;
    ycbcrBuffer[planeSize + pixelIndex] = cb;
    ycbcrBuffer[2 * planeSize + pixelIndex] = cr;
}

// MARK: - 2D DCT Transform

/// 2D Discrete Cosine Transform (DCT) on 8×8 blocks
///
/// Performs 2D DCT-II transform on 8×8 image blocks in parallel.
/// Each thread processes one 8×8 block.
///
/// - Parameters:
///   - inputBuffer: Input spatial domain data (float)
///   - outputBuffer: Output frequency domain data (float)
///   - width: Image width in pixels (must be multiple of 8)
///   - height: Image height in pixels (must be multiple of 8)
kernel void dct_8x8(
    device const float* inputBuffer [[buffer(0)]],
    device float* outputBuffer [[buffer(1)]],
    constant uint& width [[buffer(2)]],
    constant uint& height [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Calculate 8×8 block position
    uint blockX = gid.x;
    uint blockY = gid.y;
    uint blocksPerRow = width / 8;
    
    if (blockX >= blocksPerRow || blockY >= (height / 8)) {
        return;
    }
    
    // Load 8×8 block into local memory
    float block[8][8];
    for (uint y = 0; y < 8; y++) {
        for (uint x = 0; x < 8; x++) {
            uint pixelX = blockX * 8 + x;
            uint pixelY = blockY * 8 + y;
            uint pixelIndex = pixelY * width + pixelX;
            block[y][x] = inputBuffer[pixelIndex];
        }
    }
    
    // 2D DCT via separable 1D DCTs (row-column decomposition)
    float temp[8][8];
    
    // 1D DCT on rows
    for (uint i = 0; i < 8; i++) {
        for (uint u = 0; u < 8; u++) {
            float sum = 0.0f;
            for (uint x = 0; x < 8; x++) {
                sum += block[i][x] * DCT_COS_TABLE[u][x];
            }
            temp[i][u] = sum * DCT_NORM_8[u];
        }
    }
    
    // 1D DCT on columns
    float dctBlock[8][8];
    for (uint v = 0; v < 8; v++) {
        for (uint u = 0; u < 8; u++) {
            float sum = 0.0f;
            for (uint y = 0; y < 8; y++) {
                sum += temp[y][u] * DCT_COS_TABLE[v][y];
            }
            dctBlock[v][u] = sum * DCT_NORM_8[v];
        }
    }
    
    // Write back to output buffer
    for (uint y = 0; y < 8; y++) {
        for (uint x = 0; x < 8; x++) {
            uint pixelX = blockX * 8 + x;
            uint pixelY = blockY * 8 + y;
            uint pixelIndex = pixelY * width + pixelX;
            outputBuffer[pixelIndex] = dctBlock[y][x];
        }
    }
}

// MARK: - Quantization

/// Quantize DCT coefficients
///
/// Applies frequency-dependent quantization to DCT coefficients.
/// Each thread processes one coefficient.
///
/// - Parameters:
///   - inputBuffer: Input DCT coefficients (float)
///   - outputBuffer: Output quantized coefficients (int16)
///   - quantTable: Quantization table (64 floats)
///   - count: Total number of coefficients
kernel void quantize(
    device const float* inputBuffer [[buffer(0)]],
    device short* outputBuffer [[buffer(1)]],
    constant float* quantTable [[buffer(2)]],
    constant uint& count [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= count) {
        return;
    }
    
    // Get quantization step for this coefficient position
    uint blockIndex = gid / 64;
    uint coeffIndex = gid % 64;
    
    float coefficient = inputBuffer[gid];
    float quantStep = quantTable[coeffIndex];
    
    // Quantize: divide by quantization step and round
    float quantized = coefficient / quantStep;
    outputBuffer[gid] = (short)round(quantized);
}

// MARK: - Dequantization (for validation)

/// Dequantize DCT coefficients (inverse of quantization)
///
/// Restores DCT coefficients from quantized values.
///
/// - Parameters:
///   - inputBuffer: Input quantized coefficients (int16)
///   - outputBuffer: Output dequantized coefficients (float)
///   - quantTable: Quantization table (64 floats)
///   - count: Total number of coefficients
kernel void dequantize(
    device const short* inputBuffer [[buffer(0)]],
    device float* outputBuffer [[buffer(1)]],
    constant float* quantTable [[buffer(2)]],
    constant uint& count [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= count) {
        return;
    }
    
    uint coeffIndex = gid % 64;
    
    short quantized = inputBuffer[gid];
    float quantStep = quantTable[coeffIndex];
    
    // Dequantize: multiply by quantization step
    outputBuffer[gid] = (float)quantized * quantStep;
}

// MARK: - Inverse DCT (for validation)

/// 2D Inverse Discrete Cosine Transform (IDCT) on 8×8 blocks
///
/// Performs 2D IDCT (DCT-III) transform on 8×8 frequency blocks.
///
/// - Parameters:
///   - inputBuffer: Input frequency domain data (float)
///   - outputBuffer: Output spatial domain data (float)
///   - width: Image width in pixels (must be multiple of 8)
///   - height: Image height in pixels (must be multiple of 8)
kernel void idct_8x8(
    device const float* inputBuffer [[buffer(0)]],
    device float* outputBuffer [[buffer(1)]],
    constant uint& width [[buffer(2)]],
    constant uint& height [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Calculate 8×8 block position
    uint blockX = gid.x;
    uint blockY = gid.y;
    uint blocksPerRow = width / 8;
    
    if (blockX >= blocksPerRow || blockY >= (height / 8)) {
        return;
    }
    
    // Load 8×8 frequency block
    float freqBlock[8][8];
    for (uint y = 0; y < 8; y++) {
        for (uint x = 0; x < 8; x++) {
            uint pixelX = blockX * 8 + x;
            uint pixelY = blockY * 8 + y;
            uint pixelIndex = pixelY * width + pixelX;
            freqBlock[y][x] = inputBuffer[pixelIndex];
        }
    }
    
    // 2D IDCT via separable 1D IDCTs
    float temp[8][8];
    
    // 1D IDCT on rows
    for (uint i = 0; i < 8; i++) {
        for (uint x = 0; x < 8; x++) {
            float sum = 0.0f;
            for (uint u = 0; u < 8; u++) {
                sum += freqBlock[i][u] * DCT_COS_TABLE[u][x] * DCT_NORM_8[u];
            }
            temp[i][x] = sum;
        }
    }
    
    // 1D IDCT on columns
    float spatialBlock[8][8];
    for (uint y = 0; y < 8; y++) {
        for (uint u = 0; u < 8; u++) {
            float sum = 0.0f;
            for (uint v = 0; v < 8; v++) {
                sum += temp[v][u] * DCT_COS_TABLE[v][y] * DCT_NORM_8[v];
            }
            spatialBlock[y][u] = sum;
        }
    }
    
    // Write back to output buffer
    for (uint y = 0; y < 8; y++) {
        for (uint x = 0; x < 8; x++) {
            uint pixelX = blockX * 8 + x;
            uint pixelY = blockY * 8 + y;
            uint pixelIndex = pixelY * width + pixelX;
            outputBuffer[pixelIndex] = spatialBlock[y][x];
        }
    }
}
