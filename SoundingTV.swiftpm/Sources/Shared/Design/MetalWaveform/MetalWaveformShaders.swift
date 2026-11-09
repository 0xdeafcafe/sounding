#if canImport(Metal) && !os(watchOS)
import Foundation

enum MetalWaveformShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BandParams {
        uint window;
        uint windowsPerThread;
        uint warmup;
        uint prefix;
        uint sampleCount;
        uint windowCount;
        float lowCoefficient;
        float midCoefficient;
    };

    kernel void waveformBands(
        device const float *x [[buffer(0)]],
        device float *amplitude [[buffer(1)]],
        device float *low [[buffer(2)]],
        device float *mid [[buffer(3)]],
        device float *high [[buffer(4)]],
        constant BandParams &p [[buffer(5)]],
        uint tid [[thread_position_in_grid]])
    {
        uint firstWindow = tid * p.windowsPerThread;
        if (firstWindow >= p.windowCount) { return; }
        uint start = p.prefix + firstWindow * p.window;
        uint warmStart = start > p.warmup ? start - p.warmup : 0;
        float lp1 = 0.0f, lp2 = 0.0f;
        for (uint i = warmStart; i < start; i++) {
            float s = x[i];
            lp1 += p.lowCoefficient * (s - lp1);
            lp2 += p.midCoefficient * (s - lp2);
        }
        uint lastWindow = min(firstWindow + p.windowsPerThread, p.windowCount);
        for (uint w = firstWindow; w < lastWindow; w++) {
            uint a = p.prefix + w * p.window;
            uint b = min(a + p.window, p.sampleCount);
            float pk = 0.0f, lo = 0.0f, mi = 0.0f, hi = 0.0f;
            for (uint i = a; i < b; i++) {
                float s = x[i];
                lp1 += p.lowCoefficient * (s - lp1);
                lp2 += p.midCoefficient * (s - lp2);
                float h = s - lp2;
                float m = lp2 - lp1;
                pk = max(pk, fabs(s));
                lo += lp1 * lp1;
                mi += m * m;
                hi += h * h;
            }
            float n = float(max(b - a, 1u));
            amplitude[w] = pk;
            low[w] = sqrt(lo / n);
            mid[w] = sqrt(mi / n);
            high[w] = sqrt(hi / n);
        }
    }

    struct Bin { uint lohi; uint bands; };

    kernel void waveformReduce(
        device const Bin *source [[buffer(0)]],
        device Bin *destination [[buffer(1)]],
        constant uint &sourceCount [[buffer(2)]],
        uint tid [[thread_position_in_grid]])
    {
        uint a = tid * 2;
        if (a >= sourceCount) { return; }
        Bin x = source[a];
        if (a + 1 >= sourceCount) { destination[tid] = x; return; }
        Bin y = source[a + 1];
        float4 sx = unpack_snorm4x8_to_float(x.lohi);
        float4 sy = unpack_snorm4x8_to_float(y.lohi);
        float4 ux = unpack_unorm4x8_to_float(x.bands);
        float4 uy = unpack_unorm4x8_to_float(y.bands);
        Bin r;
        r.lohi = pack_float_to_snorm4x8(float4(min(sx.x, sy.x), max(sx.y, sy.y), 0, 0));
        r.bands = pack_float_to_unorm4x8(max(ux, uy));
        destination[tid] = r;
    }

    struct FrameUniforms {
        float4 unplayedTint;
        float4 playedTint;
        float4 lowColor;
        float4 midColor;
        float4 highColor;
        float4 sampleColor;
        float4 playheadColor;
        float4 beatColor;
        float4 barColor;
        float4 phraseColor;
        float2 viewport;
        float pixelScale;
        uint mode;
        uint levelOffset;
        uint levelCount;
        int originBin;
        float originFraction;
        float binsPerColumn;
        uint useSamples;
        uint sampleCount;
        int originSample;
        float originSampleFraction;
        float samplesPerColumn;
        float columnPhase;
        float playheadX;
        float playheadWidth;
        float verticalScale;
        float gridFirstX;
        float gridPixelsPerBeat;
        int gridFirstIndex;
        uint gridStride;
        uint beatsPerBar;
        uint barsPerPhrase;
        float startHi;
        float startLo;
        float pixelsPerSecond;
        float centerY;
        uint baseBinCount;
        float sampleGain;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    static float2 quadCorner(uint vid) {
        const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        return corners[vid];
    }

    static float4 toClip(float2 px, constant FrameUniforms &u) {
        return float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0, 1);
    }

    static float pcmValue(device const short *pcm, int i, uint count, float gain) {
        if (i < 0 || i >= int(count)) { return 0.0; }
        return float(pcm[i]) / 32767.0 * gain;
    }

    vertex VertexOut waveformVertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        device const Bin *bins [[buffer(0)]],
        device const short *pcm [[buffer(1)]],
        constant FrameUniforms &u [[buffer(2)]])
    {
        uint layers = u.mode == 3 ? 3 : 1;
        uint column = iid / layers;
        uint layer = iid % layers;

        float relStart = u.originFraction + float(column) * u.binsPerColumn;
        float relEnd = relStart + u.binsPerColumn;
        float lo = 0, hi = 0;
        float4 bands = float4(0);
        int levelCount = int(u.levelCount);

        if (u.binsPerColumn >= 1.0) {
            int a = clamp(u.originBin + int(floor(relStart)), 0, levelCount);
            int b = clamp(u.originBin + int(ceil(relEnd)), 0, levelCount);
            lo = 1; hi = -1;
            for (int i = a; i < b && i < a + 4; i++) {
                Bin bin = bins[u.levelOffset + uint(i)];
                float4 s = unpack_snorm4x8_to_float(bin.lohi);
                lo = min(lo, s.x);
                hi = max(hi, s.y);
                bands = max(bands, unpack_unorm4x8_to_float(bin.bands));
            }
            if (hi < lo) { lo = 0; hi = 0; }
        } else {
            float g = relStart + u.binsPerColumn * 0.5 - 0.5;
            float fl = floor(g);
            int i0 = u.originBin + int(fl);
            float f = g - fl;
            if (i0 + 1 >= 0 && i0 < levelCount) {
                uint j0 = uint(clamp(i0, 0, levelCount - 1));
                uint j1 = uint(clamp(i0 + 1, 0, levelCount - 1));
                float4 s0 = unpack_snorm4x8_to_float(bins[u.levelOffset + j0].lohi);
                float4 s1 = unpack_snorm4x8_to_float(bins[u.levelOffset + j1].lohi);
                lo = mix(s0.x, s1.x, f);
                hi = mix(s0.y, s1.y, f);
                bands = mix(unpack_unorm4x8_to_float(bins[u.levelOffset + j0].bands), unpack_unorm4x8_to_float(bins[u.levelOffset + j1].bands), f);
            }
        }

        if (u.useSamples != 0 && u.sampleCount > 1) {
            float r0 = u.originSampleFraction + float(column) * u.samplesPerColumn;
            float r1 = r0 + u.samplesPerColumn;
            if (u.samplesPerColumn <= 1.0) {
                float f0 = floor(r0), f1 = floor(r1);
                int i0 = u.originSample + int(f0), i1 = u.originSample + int(f1);
                float v0 = mix(pcmValue(pcm, i0, u.sampleCount, u.sampleGain), pcmValue(pcm, i0 + 1, u.sampleCount, u.sampleGain), r0 - f0);
                float v1 = mix(pcmValue(pcm, i1, u.sampleCount, u.sampleGain), pcmValue(pcm, i1 + 1, u.sampleCount, u.sampleGain), r1 - f1);
                lo = min(v0, v1);
                hi = max(v0, v1);
            } else {
                int a = clamp(u.originSample + int(floor(r0)), 0, int(u.sampleCount));
                int b = clamp(u.originSample + int(ceil(r1)), 0, int(u.sampleCount));
                lo = 1; hi = -1;
                for (int i = a; i < b; i++) {
                    float v = float(pcm[i]) / 32767.0 * u.sampleGain;
                    lo = min(lo, v);
                    hi = max(hi, v);
                }
                if (hi < lo) { lo = 0; hi = 0; }
            }
        }

        float4 color;
        float top;
        float bottom;
        float peak = max(-lo, hi);
        float3 bandRGB = bands.yzw;
        if (u.mode == 3) {
            float v = layer == 0 ? bands.y : (layer == 1 ? bands.z : bands.w);
            v = max(v, 0.0f) * peak / max(max(bands.y, max(bands.z, bands.w)), 1e-4);
            top = v;
            bottom = -v;
            color = layer == 0 ? u.lowColor : (layer == 1 ? u.midColor : u.highColor);
        } else if (u.mode == 2) {
            float m = max(bandRGB.x, max(bandRGB.y, bandRGB.z));
            float3 c = m > 1e-4 ? bandRGB / m : float3(0.5);
            color = float4(c.x * u.lowColor.rgb + c.y * u.midColor.rgb + c.z * u.highColor.rgb, 1);
            color.rgb = min(color.rgb, float3(1));
            top = hi;
            bottom = lo;
        } else if (u.mode == 1) {
            float sum = bandRGB.x + bandRGB.y + bandRGB.z;
            float brightness = sum > 1e-4 ? bandRGB.z / sum : 0.0;
            color = mix(u.lowColor, u.highColor, clamp(brightness * 2.2, 0.0, 1.0));
            top = hi;
            bottom = lo;
        } else {
            color = u.sampleColor;
            top = hi;
            bottom = lo;
        }

        float columnX = float(column) - u.columnPhase;
        bool played = columnX + 0.5 < u.playheadX;
        color *= played ? u.playedTint : u.unplayedTint;

        float halfHeight = u.viewport.y * 0.5 * u.verticalScale;
        float y0 = u.centerY - top * halfHeight;
        float y1 = u.centerY - bottom * halfHeight;
        float minThickness = u.pixelScale * (u.samplesPerColumn <= 1.0 && u.useSamples != 0 ? 1.5 : 1.0);
        if (y1 - y0 < minThickness) {
            float c = (y0 + y1) * 0.5;
            y0 = c - minThickness * 0.5;
            y1 = c + minThickness * 0.5;
        }
        float2 corner = quadCorner(vid);
        float2 px = float2(columnX + corner.x, mix(y0, y1, corner.y));
        VertexOut out;
        out.position = toClip(px, u);
        out.color = color;
        return out;
    }

    struct OverlayItem {
        float4 color;
        float startHi;
        float startLo;
        float endHi;
        float endLo;
        float top;
        float bottom;
        float minWidth;
        uint kind;
    };

    vertex VertexOut overlayVertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        device const OverlayItem *items [[buffer(0)]],
        constant FrameUniforms &u [[buffer(2)]])
    {
        OverlayItem item = items[iid];
        float s = ((item.startHi - u.startHi) + (item.startLo - u.startLo)) * u.pixelsPerSecond;
        float e = ((item.endHi - u.startHi) + (item.endLo - u.startLo)) * u.pixelsPerSecond;
        float w = max(e - s, item.minWidth);
        float x0 = item.kind == 0 ? s - w * 0.5 : s;
        float2 corner = quadCorner(vid);
        float2 px = float2(x0 + corner.x * w, mix(item.top, item.bottom, corner.y) * u.viewport.y);
        VertexOut out;
        out.position = toClip(px, u);
        out.color = item.color;
        return out;
    }

    vertex VertexOut gridVertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant FrameUniforms &u [[buffer(2)]])
    {
        int index = u.gridFirstIndex + int(iid * u.gridStride);
        float x = u.gridFirstX + float(iid * u.gridStride) * u.gridPixelsPerBeat;
        int perPhrase = int(u.beatsPerBar * u.barsPerPhrase);
        float4 color = u.beatColor;
        float width = u.pixelScale;
        if (perPhrase > 0 && index % perPhrase == 0) { color = u.phraseColor; width = u.pixelScale * 2.0; }
        else if (u.beatsPerBar > 0 && index % int(u.beatsPerBar) == 0) { color = u.barColor; }
        float2 corner = quadCorner(vid);
        float2 px = float2(x - width * 0.5 + corner.x * width, corner.y * u.viewport.y);
        VertexOut out;
        out.position = toClip(px, u);
        out.color = color;
        return out;
    }

    vertex VertexOut playheadVertex(
        uint vid [[vertex_id]],
        constant FrameUniforms &u [[buffer(2)]])
    {
        float2 corner = quadCorner(vid);
        float w = u.playheadWidth;
        float2 px = float2(u.playheadX - w * 0.5 + corner.x * w, corner.y * u.viewport.y);
        VertexOut out;
        out.position = toClip(px, u);
        out.color = u.playheadColor;
        return out;
    }

    fragment float4 waveformFragment(VertexOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }
    """
}
#endif
