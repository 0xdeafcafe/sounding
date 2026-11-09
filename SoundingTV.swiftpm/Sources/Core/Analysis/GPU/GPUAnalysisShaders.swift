#if canImport(Metal) && !os(watchOS)
import Foundation

enum GPUAnalysisShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct OnsetParams {
        uint hop;
        uint firstHop;
        uint hopCount;
        uint hopsPerGroup;
        uint prefix;
        uint bandLower[4];
        uint bandUpper[4];
    };

    struct ChromaParams {
        uint hop;
        uint firstHop;
        uint slowCount;
        uint firstSlow;
        uint stride;
        uint prefix;
        uint bandLower[4];
        uint bandUpper[4];
    };

    static inline float accurateLog1p(float x) {
        float u = 1.0f + x;
        if (u == 1.0f) { return x; }
        return log(u) * x / (u - 1.0f);
    }

    static inline float2 cmul(float2 a, float2 b) {
        return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
    }

    static inline uint reverseBits(uint value, uint bits) {
        return reverse_bits(value) >> (32 - bits);
    }

    static void loadPacked(
        device const float *samples, int end, uint size, uint bits,
        device const float *window, threadgroup float2 *z, uint tid, uint threads
    ) {
        uint halfSize = size / 2;
        int start = end - int(size);
        for (uint n = tid; n < halfSize; n += threads) {
            int a = start + int(2 * n);
            float x0 = a >= 0 ? samples[a] * window[2 * n] : 0.0f;
            float x1 = a + 1 >= 0 ? samples[a + 1] * window[2 * n + 1] : 0.0f;
            z[reverseBits(n, bits)] = float2(x0, x1);
        }
    }

    static void complexFFT(threadgroup float2 *z, device const float2 *twiddle, uint m, uint bits, uint tid, uint threads) {
        for (uint s = 1; s <= bits; s++) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint halfSpan = 1u << (s - 1);
            uint step = m >> s;
            for (uint b = tid; b < m / 2; b += threads) {
                uint group = b / halfSpan;
                uint pos = b - group * halfSpan;
                uint i = group * 2 * halfSpan + pos;
                uint j = i + halfSpan;
                float2 w = twiddle[2 * pos * step];
                float2 t = cmul(w, z[j]);
                float2 u = z[i];
                z[i] = u + t;
                z[j] = u - t;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    static inline float realMagnitude(threadgroup float2 *z, device const float2 *twiddle, uint k, uint m) {
        float2 a = z[k];
        if (k == 0) { return 2.0f * fabs(a.x + a.y); }
        float2 b = z[m - k];
        float2 c = float2(b.x, -b.y);
        float2 even = a + c;
        float2 diff = a - c;
        float2 odd = float2(diff.y, -diff.x);
        float2 x = even + cmul(twiddle[k], odd);
        return length(x);
    }

    kernel void onsetBands(
        device const float *samples [[buffer(0)]],
        device const float *window [[buffer(1)]],
        device const float2 *twiddle [[buffer(2)]],
        constant OnsetParams &p [[buffer(3)]],
        device float *bands [[buffer(4)]],
        uint group [[threadgroup_position_in_grid]],
        uint tid [[thread_position_in_threadgroup]],
        uint threads [[threads_per_threadgroup]],
        uint lane [[thread_index_in_simdgroup]],
        uint simd [[simdgroup_index_in_threadgroup]]
    ) {
        const uint size = 1024;
        const uint m = 512;
        const uint bits = 9;
        threadgroup float2 z[512];
        threadgroup float history[3][512];
        threadgroup float partial[32][4];
        uint first = group * p.hopsPerGroup;
        if (first >= p.hopCount) { return; }
        uint last = min(p.hopCount, first + p.hopsPerGroup);
        int globalFirst = int(p.firstHop) + int(first);
        int warm = max(0, globalFirst - 2);
        for (int k = warm; k < int(p.firstHop) + int(last); k++) {
            int end = (k + 1) * int(p.hop) - int(p.firstHop) * int(p.hop) + int(p.prefix);
            loadPacked(samples, end, size, bits, window, z, tid, threads);
            complexFFT(z, twiddle, m, bits, tid, threads);
            uint slot = uint(k % 3);
            uint previous = uint((k + 1) % 3);
            bool hasPrevious = k >= 2;
            float sums[4] = {0, 0, 0, 0};
            for (uint bin = tid; bin < m; bin += threads) {
                float magnitude = realMagnitude(z, twiddle, bin, m);
                float logMagnitude = accurateLog1p(magnitude * (1000.0f / 1024.0f));
                float before = hasPrevious ? history[previous][bin] : 0.0f;
                float d = max(0.0f, logMagnitude - before);
                for (uint b = 0; b < 4; b++) {
                    if (bin >= p.bandLower[b] && bin < p.bandUpper[b]) { sums[b] += d; }
                }
                history[slot][bin] = logMagnitude;
            }
            if (k >= globalFirst) {
                for (uint b = 0; b < 4; b++) {
                    float s = simd_sum(sums[b]);
                    if (lane == 0) { partial[simd][b] = s; }
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (tid < 4) {
                    float total = 0;
                    uint groups = (threads + 31) / 32;
                    for (uint g = 0; g < groups; g++) { total += partial[g][tid]; }
                    uint index = uint(k - int(p.firstHop));
                    bands[index * 4 + tid] = total / float(p.bandUpper[tid] - p.bandLower[tid]);
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }

    kernel void chromaBands(
        device const float *samples [[buffer(0)]],
        device const float *window [[buffer(1)]],
        device const float2 *twiddle [[buffer(2)]],
        constant ChromaParams &p [[buffer(3)]],
        device const int *classes [[buffer(4)]],
        device float *chroma [[buffer(5)]],
        device float *energy [[buffer(6)]],
        uint group [[threadgroup_position_in_grid]],
        uint tid [[thread_position_in_threadgroup]],
        uint threads [[threads_per_threadgroup]],
        uint lane [[thread_index_in_simdgroup]],
        uint simd [[simdgroup_index_in_threadgroup]]
    ) {
        const uint size = 4096;
        const uint m = 2048;
        const uint bits = 11;
        threadgroup float2 z[2048];
        threadgroup float partial[32][17];
        threadgroup float totals[17];
        if (group >= p.slowCount) { return; }
        int slow = int(p.firstSlow) + int(group);
        int hopIndex = (slow + 1) * int(p.stride);
        int end = hopIndex * int(p.hop) - int(p.firstHop) * int(p.hop) + int(p.prefix);
        loadPacked(samples, end, size, bits, window, z, tid, threads);
        complexFFT(z, twiddle, m, bits, tid, threads);
        float sums[17];
        for (uint i = 0; i < 17; i++) { sums[i] = 0; }
        for (uint bin = tid; bin < m; bin += threads) {
            float magnitude = realMagnitude(z, twiddle, bin, m);
            int cls = classes[bin];
            if (bin >= 1 && cls >= 0) {
                sums[cls] += magnitude;
                sums[12] += magnitude;
            }
            for (uint b = 0; b < 4; b++) {
                if (bin >= p.bandLower[b] && bin < p.bandUpper[b]) { sums[13 + b] += magnitude; }
            }
        }
        for (uint i = 0; i < 17; i++) {
            float s = simd_sum(sums[i]);
            if (lane == 0) { partial[simd][i] = s; }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < 17) {
            float total = 0;
            uint groups = (threads + 31) / 32;
            for (uint g = 0; g < groups; g++) { total += partial[g][tid]; }
            totals[tid] = total;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid < 12) {
            float all = totals[12];
            float inv = all > 1e-9f ? 1.0f / all : 0.0f;
            chroma[uint(group) * 12 + tid] = totals[tid] * inv;
        } else if (tid >= 16 && tid < 20) {
            uint b = tid - 16;
            float mean = totals[13 + b] / float(p.bandUpper[b] - p.bandLower[b]);
            energy[uint(group) * 4 + b] = accurateLog1p(mean * 1000.0f / 4096.0f);
        }
    }
    """
}
#endif
