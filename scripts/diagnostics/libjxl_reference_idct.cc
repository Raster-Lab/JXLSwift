// Standalone test: hand-port libjxl's IDCTSlow + DCTSlow from
// dct_for_test.h, run on known test inputs, print results.
// Compile: clang++ -std=c++17 test_libjxl_idct.cc -o test_libjxl_idct

#include <cmath>
#include <cstdio>
#include <vector>

inline double alpha(int u) { return u == 0 ? 0.7071067811865475 : 1.0; }

// Vanilla 1D-DCT (libjxl convention: scale = sqrt(2)/N).
template <size_t N>
void DCT1D(const double* block, double* out, size_t M) {
  std::vector<double> matrix(N * N);
  const double scale = std::sqrt(2.0) / N;
  for (size_t y = 0; y < N; y++) {
    for (size_t u = 0; u < N; u++) {
      matrix[N * u + y] = alpha(u) * std::cos((y + 0.5) * u * (M_PI / N)) * scale;
    }
  }
  for (size_t x = 0; x < M; x++) {
    for (size_t u = 0; u < N; u++) {
      out[M * u + x] = 0;
      for (size_t y = 0; y < N; y++) {
        out[M * u + x] += matrix[N * u + y] * block[M * y + x];
      }
    }
  }
}

// Vanilla 1D-IDCT (libjxl convention: scale = sqrt(2)).
template <size_t N>
void IDCT1D(const double* block, double* out, size_t M) {
  std::vector<double> matrix(N * N);
  const double scale = std::sqrt(2.0);
  for (size_t y = 0; y < N; y++) {
    for (size_t u = 0; u < N; u++) {
      matrix[N * y + u] = alpha(u) * std::cos((y + 0.5) * u * (M_PI / N)) * scale;
    }
  }
  for (size_t x = 0; x < M; x++) {
    for (size_t u = 0; u < N; u++) {
      out[M * u + x] = 0;
      for (size_t y = 0; y < N; y++) {
        out[M * u + x] += matrix[N * u + y] * block[M * y + x];
      }
    }
  }
}

template <size_t N>
void TransposeBlock(const double* in, double* out) {
  for (size_t x = 0; x < N; x++) {
    for (size_t y = 0; y < N; y++) {
      out[y * N + x] = in[x * N + y];
    }
  }
}

template <size_t N>
void DCTSlow(double* block) {
  std::vector<double> g(N * N);
  DCT1D<N>(block, g.data(), N);
  TransposeBlock<N>(g.data(), block);
  DCT1D<N>(block, g.data(), N);
  TransposeBlock<N>(g.data(), block);
}

template <size_t N>
void IDCTSlow(double* block) {
  std::vector<double> g(N * N);
  IDCT1D<N>(block, g.data(), N);
  TransposeBlock<N>(g.data(), block);
  IDCT1D<N>(block, g.data(), N);
  TransposeBlock<N>(g.data(), block);
}

void print_block_8(const char* label, const double* block) {
  printf("%s:\n", label);
  for (int y = 0; y < 8; y++) {
    printf("  ");
    for (int x = 0; x < 8; x++) {
      printf("%10.4f ", block[y * 8 + x]);
    }
    printf("\n");
  }
}

int main() {
  // Test 1: DC = 1.0, all AC = 0. Expect all-1.0 output.
  {
    double block[64] = {0};
    block[0] = 1.0;
    IDCTSlow<8>(block);
    print_block_8("Test 1: IDCTSlow(DC=1, rest=0)", block);
  }

  // Test 2: AC at flat position 1 (vanilla [0, 1] = horizontal AC1).
  {
    double block[64] = {0};
    block[1] = 1.0;
    IDCTSlow<8>(block);
    print_block_8("Test 2: IDCTSlow(coef[0,1]=1)", block);
  }

  // Test 3: AC at flat position 8 (vanilla [1, 0] = vertical AC1).
  {
    double block[64] = {0};
    block[8] = 1.0;
    IDCTSlow<8>(block);
    print_block_8("Test 3: IDCTSlow(coef[1,0]=1)", block);
  }

  // Test 4: Forward DCT of constant block (all 1.0). Expect DC=1.0, rest=0.
  {
    double block[64];
    for (int i = 0; i < 64; i++) block[i] = 1.0;
    DCTSlow<8>(block);
    print_block_8("Test 4: DCTSlow(constant=1)", block);
  }

  // Test 5: Forward DCT of horizontal ramp pixels[y][x] = x.
  {
    double block[64];
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        block[y * 8 + x] = x;
      }
    }
    DCTSlow<8>(block);
    print_block_8("Test 5: DCTSlow(pixels[y][x]=x, horizontal ramp)", block);
  }

  // Test 6: ComputeScaledDCT-equivalent (= DCTSlow without final
  // transpose) on horizontal ramp. This is what libjxl's encoder
  // actually writes to the bitstream.
  {
    double block[64];
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        block[y * 8 + x] = x;
      }
    }
    // ComputeScaledDCT = DCT, transpose, DCT (no final transpose).
    std::vector<double> g(64);
    DCT1D<8>(block, g.data(), 8);
    TransposeBlock<8>(g.data(), block);
    DCT1D<8>(block, g.data(), 8);
    // No final transpose. Copy g back to block.
    for (int i = 0; i < 64; i++) block[i] = g[i];
    print_block_8("Test 6: ComputeScaledDCT(horizontal ramp) — bitstream layout", block);
  }

  // Test 7: ComputeScaledDCT on actual Y values from our cjxl-d=1
  // gradient fixture (Y values from OpsinXYB forward on linear-RGB
  // ramp R=100..212, GB=128).
  {
    double Y[8] = {0.4256, 0.4366, 0.4502, 0.4645, 0.4808, 0.4977, 0.5164, 0.5366};
    double block[64];
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        block[y * 8 + x] = Y[x];  // constant in y, varies in x
      }
    }
    std::vector<double> g(64);
    DCT1D<8>(block, g.data(), 8);
    TransposeBlock<8>(g.data(), block);
    DCT1D<8>(block, g.data(), 8);
    for (int i = 0; i < 64; i++) block[i] = g[i];
    print_block_8("Test 7: ComputeScaledDCT(actual gradient Y values)", block);
    // Print just position 8 specifically.
    printf("  block[8] (= TRANSPOSED [1,0] = bitstream first vertical-frequency-of-transposed) = %.6f\n", block[8]);
    printf("  block[1] (= TRANSPOSED [0,1] = bitstream first horizontal-frequency-of-transposed) = %.6f\n", block[1]);
  }

  // Test 8: full pipeline: linear-RGB → OpsinXYB Y → ComputeScaledDCT
  // → encoder quantization. Use libjxl's exact OpsinXYB constants
  // and exact sRGB OETF.
  {
    // libjxl OpsinXYB constants from cms/opsin_params.h.
    constexpr double kM02 = 0.078;
    constexpr double kM00 = 0.30;
    constexpr double kM01 = 1.0 - kM02 - kM00;  // 0.622
    constexpr double kM12 = 0.078;
    constexpr double kM10 = 0.23;
    constexpr double kM11 = 1.0 - kM12 - kM10;  // 0.692
    constexpr double kBias = 0.0037930732552754493;
    const double cbrtBias = std::cbrt(kBias);

    auto srgb_to_linear = [](double s) {
      if (s <= 0.04045) return s / 12.92;
      return std::pow((s + 0.055) / 1.055, 2.4);
    };

    // Pixels: R = 100..212 (linear sRGB conversion), G = B = 128.
    double Y[8];
    double linear_G = srgb_to_linear(128.0 / 255.0);
    double linear_B = linear_G;
    for (int x = 0; x < 8; x++) {
      double R = 100.0 + 16.0 * x;
      double linear_R = srgb_to_linear(R / 255.0);
      double L = kM00 * linear_R + kM01 * linear_G + kM02 * linear_B + kBias;
      double M = kM10 * linear_R + kM11 * linear_G + kM12 * linear_B + kBias;
      double cbrtL = std::cbrt(L);
      double cbrtM = std::cbrt(M);
      double lr = cbrtL - cbrtBias;
      double mr = cbrtM - cbrtBias;
      Y[x] = 0.5 * (lr + mr);
    }
    printf("Test 8: per-pixel Y values (libjxl-exact OpsinXYB):\n  ");
    for (int x = 0; x < 8; x++) printf("%.5f ", Y[x]);
    printf("\n");

    // Replicate Y in y dim (constant in y).
    double block[64];
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        block[y * 8 + x] = Y[x];
      }
    }

    // ComputeScaledDCT
    std::vector<double> g(64);
    DCT1D<8>(block, g.data(), 8);
    TransposeBlock<8>(g.data(), block);
    DCT1D<8>(block, g.data(), 8);
    for (int i = 0; i < 64; i++) block[i] = g[i];

    printf("Test 8: ComputeScaledDCT result (block[0..15]):\n  ");
    for (int i = 0; i < 16; i++) printf("%.5f ", block[i]);
    printf("\n");

    // Encoder quantization. Y channel: weight = 560 (no ×64),
    // Scale = 5111/65536 = 0.0779953, qf = 10, qm_multiplier = 1.0.
    // weight at flat 8 (= TRANSPOSED [1,0]) for DCT8x8 Y channel.
    double weight_y_at_8 = 560.0;  // Library default seed for Y at first AC.
    double scale = 5111.0 / 65536.0;
    double qf = 10.0;
    double qm_multiplier = 1.0;

    double q = weight_y_at_8 * scale * qf * qm_multiplier;
    double val = q * block[8];
    int quantized = (int)std::round(val);
    printf("Test 8: predicted quantized Y AC at flat 8 = round(%.5f * %.5f) = round(%.5f) = %d\n",
           q, block[8], val, quantized);
    printf("    (cjxl emits -7 for our trace; ratio %d/-7 = %.3f)\n",
           quantized, double(quantized) / -7.0);
  }

  return 0;
}
