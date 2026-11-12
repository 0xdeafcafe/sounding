export const DEPTH_VERT = `#version 300 es
layout(location=0) in vec3 aPos;
uniform mat4 uVP, uModel;
void main(){ gl_Position = uVP * uModel * vec4(aPos, 1.0); }`;

export const DEPTH_FRAG = `#version 300 es
precision mediump float;
void main(){}`;

export const VERT = `#version 300 es
layout(location=0) in vec3 aPos;
layout(location=1) in vec3 aNor;
layout(location=2) in vec2 aUv;
uniform mat4 uVP, uModel;
out vec3 vW; out vec3 vN; out vec3 vL; out vec3 vLN; out vec2 vUv;
void main(){
  vec4 w = uModel * vec4(aPos, 1.0);
  vW = w.xyz; vL = aPos; vLN = aNor; vN = mat3(uModel) * aNor; vUv = aUv;
  gl_Position = uVP * w;
}`;

export const FRAG = `#version 300 es
precision highp float;
precision highp sampler2DShadow;
in vec3 vW; in vec3 vN; in vec3 vL; in vec3 vLN; in vec2 vUv;
uniform mat4 uModel, uShadowVP;
uniform vec3 uCam;
uniform int uKind;
uniform vec3 uBaseA, uBaseB, uEmitA, uEmitB;
uniform float uMetal, uRough;
uniform vec4 uP, uQ;
uniform sampler2D uTex;
uniform sampler2DShadow uShadow;
uniform vec2 uRes;
uniform float uFade, uTime, uShadowR, uBias, uBeat, uBeats, uLive;
uniform vec3 uSpot;
uniform vec4 uOccA[24];
uniform vec4 uOccB[24];
uniform float uOccH[24];
uniform int uOccN;
uniform vec4 uLamp[4];
uniform vec3 uLampC[4];
uniform vec4 uLit, uDark;
uniform float uFront;
out vec4 o;

const vec3 LK = vec3(-0.4196, 0.7993, 0.4296);
const vec3 LO = vec3(-0.7797, 0.2999, -0.5498);
const vec3 LT = vec3(0.7975, 0.3389, -0.4984);
const vec3 CREAM = vec3(0.86, 0.80, 0.70);
const vec3 GLOW = vec3(3.0, 0.78, 0.13);
const vec3 DEAD = vec3(0.05, 0.046, 0.042);

float h11(float x){ return fract(sin(x * 127.1) * 43758.5453); }
float h21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vnoise(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f); return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y); }
float ign(vec2 p){ return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }

float nightMix(){
  vec2 s = gl_FragCoord.xy / uRes;
  float x = s.x + (s.y - 0.5) * 0.18;
  float e = mix(1.4, -0.4, uFade);
  return smoothstep(e - 0.3, e + 0.3, x);
}

float lightMix(){
  if (uLit.z > 1e8) return 1.0;
  if (uLit.z < 0.5) return 0.0;
  float d = length((gl_FragCoord.xy - uLit.xy) / uLit.zw);
  float w = clamp((3.6 - d) / 1.4, 0.0, 1.0);
  float p = exp((0.25 - sqrt(d * d + 0.0625)) / 0.446) * w * w * (3.0 - 2.0 * w);
  return pow(p, 2.2);
}

float strip(float az, float el, float a0, float wa, float e0, float we, float s){
  float da = abs(atan(sin(az - a0), cos(az - a0)));
  return (1.0 - smoothstep(wa - s * 0.4, wa + s, da)) * (1.0 - smoothstep(we - s * 0.4, we + s, abs(el - e0)));
}

vec3 envD(vec3 d, float r){
  float az = atan(d.x, d.z);
  float el = asin(clamp(d.y, -1.0, 1.0));
  float s = 0.04 + r * 0.8;
  vec3 c = vec3(0.055, 0.048, 0.042) * (0.4 + 0.6 * smoothstep(-0.3, 0.6, d.y));
  c += vec3(3.6, 3.4, 3.1) * strip(az, el, -0.7, 0.34, 0.62, 0.5, s);
  c += vec3(1.0, 1.12, 1.3) * strip(az, el, 1.05, 0.09, 0.6, 0.55, s);
  c += vec3(2.2, 1.9, 1.6) * strip(az, el, 2.6, 0.22, 0.45, 0.3, s);
  c += vec3(1.6, 1.45, 1.3) * strip(az, el, -2.35, 0.12, 0.5, 0.36, s);
  c += vec3(1.1, 1.05, 1.0) * smoothstep(0.8 - s * 0.3, 0.97, d.y);
  c += GLOW * uDark.z * 0.2 * smoothstep(-0.15, -0.8, d.y);
  return c;
}

float boxm(vec2 p, vec2 h, float s){ vec2 q = abs(p) - h; return 1.0 - smoothstep(-s, s, max(q.x, q.y)); }
float lobe(vec3 d, vec3 c, float w){ return exp(-(1.0 - dot(d, c)) / (w * w)); }

vec3 envA(vec3 d, float r){
  float up = d.y;
  vec3 hz = vec3(0.30, 0.27, 0.24);
  vec3 c = up < 0.0 ? mix(vec3(0.80, 0.75, 0.67), hz, smoothstep(-0.55, 0.0, up)) : mix(hz, vec3(0.70, 0.68, 0.65), smoothstep(0.0, 0.5, up));
  if (up > 0.03) {
    vec2 p = d.xz / up;
    float s = 0.10 + r * 1.5;
    c += vec3(2.9, 2.8, 2.65) * boxm(p - vec2(-0.5, -0.25), vec2(0.95, 0.5), s);
    c += vec3(1.6, 1.5, 1.38) * boxm(p - vec2(1.3, 0.55), vec2(0.16, 1.2), s);
  }
  return c;
}

vec3 envB(vec3 d, float r){
  float up = d.y;
  vec3 c = vec3(0.012, 0.010, 0.009) + vec3(0.03, 0.022, 0.016) * smoothstep(-0.2, 0.8, up);
  if (up > 0.03) {
    vec2 p = d.xz / up;
    float s = 0.08 + r * 1.4;
    c += vec3(3.4, 2.5, 1.55) * boxm(p - vec2(-0.1, -0.05), vec2(0.42, 0.42), s);
  }
  float w = 0.16 + r * 0.5;
  float k = mix(1.0, 0.3, r);
  c += (vec3(4.2, 1.35, 0.22) * lobe(d, LO, w) + vec3(0.25, 2.0, 1.7) * lobe(d, LT, w)) * k;
  return c;
}

vec2 envBRDF(float r, float NoV){
  vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022), c1 = vec4(1.0, 0.0425, 1.04, -0.04);
  vec4 rr = r * c0 + c1;
  float a004 = min(rr.x * rr.x, exp2(-9.28 * NoV)) * rr.x + rr.y;
  return vec2(-1.04, 1.04) * a004 + rr.zw;
}

float ggx(vec3 N, vec3 V, vec3 L, float rough){
  vec3 H = normalize(V + L);
  float a = rough * rough, a2 = a * a;
  float NoH = max(dot(N, H), 0.0);
  float d = NoH * NoH * (a2 - 1.0) + 1.0;
  float D = a2 / (3.14159 * d * d);
  float NoV = max(dot(N, V), 0.001), NoL = max(dot(N, L), 0.001);
  float k = (rough + 1.0); k = k * k / 8.0;
  return min(D * 0.25 / ((NoV * (1.0 - k) + k) * (NoL * (1.0 - k) + k)), 8.0);
}

float occl(vec3 wp){
  float a = 0.0;
  for (int i = 0; i < 24; i++) {
    if (i >= uOccN) break;
    vec4 A = uOccA[i], B = uOccB[i];
    float h = uOccH[i];
    if (wp.y >= h + 0.001) continue;
    vec2 q = wp.xz - A.xy;
    if (length(q) > length(A.zw) + h * 5.0 + 0.025) continue;
    q = vec2(B.x * q.x - B.y * q.y, B.y * q.x + B.x * q.y);
    vec2 dd = abs(q) - A.zw + B.z;
    float d = max(length(max(dd, 0.0)) + min(max(dd.x, dd.y), 0.0) - B.z, 0.0);
    float hy = clamp(1.0 - wp.y / (h + 0.001), 0.0, 1.0);
    a += B.w * hy * (0.62 * exp(-d / (h * 0.16 + 0.0006)) + 0.4 * exp(-d / (h * 0.8 + 0.002)));
  }
  return 1.0 - min(a, 0.86);
}

float shadow(vec3 wp, vec3 N){
  vec4 sp = uShadowVP * vec4(wp + N * uBias, 1.0);
  vec3 p = sp.xyz * 0.5 + 0.5;
  if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
  float a = ign(gl_FragCoord.xy) * 6.2832;
  float s = 0.0;
  for (int i = 0; i < 8; i++) {
    float r = sqrt((float(i) + 0.5) / 8.0);
    float t = float(i) * 2.39996 + a;
    s += texture(uShadow, vec3(p.xy + vec2(cos(t), sin(t)) * r * uShadowR, p.z - 0.0006));
  }
  return s / 8.0;
}

vec3 lampLight(vec3 wp, vec3 N){
  vec3 c = vec3(0.0);
  for (int i = 0; i < 4; i++) {
    vec3 d = uLamp[i].xyz - wp;
    float rad = uLamp[i].w;
    float att = 1.0 / (1.0 + dot(d, d) / (rad * rad));
    c += uLampC[i] * att * att * max(dot(N, normalize(d)) * 0.7 + 0.3, 0.0);
  }
  return c;
}

vec3 lampSpec(vec3 wp, vec3 N, vec3 V, float rough){
  vec3 d = uLamp[0].xyz - wp;
  float rad = uLamp[0].w * 1.6;
  float att = 1.0 / (1.0 + dot(d, d) / (rad * rad));
  vec3 L = normalize(d);
  return uLampC[0] * att * att * max(dot(N, L), 0.0) * ggx(N, V, L, max(rough, 0.2));
}

float pool(){
  float p = 1.0 - smoothstep(0.28, 1.45, length(vW.xz - uSpot.xz));
  return p * p * 0.97 + 0.03;
}

float specK(float rough, float metal){ return mix(1.0, mix(1.0, 0.12, smoothstep(0.3, 0.92, rough)), 1.0 - metal) * (uKind == 1 ? 0.0 : 1.0); }

vec3 litA(vec3 N, vec3 V, vec3 base, float metal, float rough, float ao, float sh){
  vec3 F0 = mix(vec3(0.04), base, metal);
  vec3 dc = base * (1.0 - metal);
  float NoV = clamp(dot(N, V), 0.001, 1.0);
  vec3 R = reflect(-V, N);
  vec3 amb = mix(vec3(0.26, 0.225, 0.19), vec3(0.445, 0.462, 0.485), N.y * 0.5 + 0.5);
  float NoL = max(dot(N, LK), 0.0);
  vec3 key = vec3(0.74, 0.685, 0.61);
  vec3 c = dc * (amb * ao + key * NoL * sh * mix(1.0, ao, 0.5));
  vec2 ab = envBRDF(rough, NoV);
  c += envA(R, rough) * (F0 * ab.x + ab.y) * mix(1.0, ao, 0.7) * mix(0.75, 1.0, sh) * specK(rough, metal);
  c += key * 2.4 * NoL * sh * ggx(N, V, LK, rough) * F0 * 1.6 * (uKind == 1 ? 0.0 : 1.0);
  return c;
}

vec3 litB(vec3 N, vec3 V, vec3 base, float metal, float rough, float ao, float sh){
  vec3 F0 = mix(vec3(0.04), base, metal);
  vec3 dc = base * (1.0 - metal);
  float NoV = clamp(dot(N, V), 0.001, 1.0);
  vec3 R = reflect(-V, N);
  float pl = pool();
  float wide = 0.2 + 0.8 * pl;
  vec3 key = vec3(1.0, 1.0, 1.16) * 1.08 * pl * (0.985 + 0.03 * uBeat * uLive);
  vec3 amb = vec3(0.026, 0.028, 0.038) * wide;
  float NoL = max(dot(N, LK), 0.0);
  float no = max(dot(N, LO), 0.0), nt = max(dot(N, LT), 0.0);
  vec3 c = dc * (amb * ao + key * NoL * sh * mix(1.0, ao, 0.5) + (vec3(0.85, 0.27, 0.05) * no + vec3(0.05, 0.42, 0.36) * nt) * ao * wide);
  vec2 ab = envBRDF(rough, NoV);
  c += envB(R, rough) * (F0 * ab.x + ab.y) * mix(1.0, ao, 0.7) * wide * specK(rough, metal);
  vec3 sc = F0 * 1.6 * (uKind == 1 ? 0.0 : 1.0);
  c += key * 2.4 * NoL * sh * ggx(N, V, LK, rough) * sc;
  c += (vec3(4.2, 1.35, 0.22) * no * ggx(N, V, LO, rough) + vec3(0.25, 2.0, 1.7) * nt * ggx(N, V, LT, rough)) * 0.5 * wide * sc;
  return c;
}

vec3 litD(vec3 N, vec3 V, vec3 base, float metal, float rough, float ao, float sh){
  vec3 F0 = mix(vec3(0.04), base, metal);
  vec3 dc = base * (1.0 - metal);
  float NoV = clamp(dot(N, V), 0.001, 1.0);
  vec3 R = reflect(-V, N);
  vec2 dq = vW.xz - uDark.xy;
  float d2 = dot(dq, dq);
  float sp = exp(-d2 / 0.012);
  float tent = 0.012 + 0.988 * exp(-d2 / 0.011);
  vec3 key = vec3(0.66, 0.6, 0.53) * sp;
  float NoL = max(dot(N, LK), 0.0);
  vec3 c = dc * (vec3(0.011, 0.010, 0.009) * ao * tent + key * NoL * sh * mix(1.0, ao, 0.5));
  vec2 ab = envBRDF(rough, NoV);
  c += envD(R, rough) * tent * (F0 * ab.x + ab.y) * mix(1.0, ao, 0.7) * mix(0.55, 1.0, sh) * specK(rough, metal);
  c += key * 2.4 * NoL * sh * ggx(N, V, LK, rough) * F0 * 1.6 * (uKind == 1 ? 0.0 : 1.0);
  c += lampSpec(vW, N, V, rough) * F0 * 2.2;
  return c;
}

vec3 tone(vec3 c){
  c = max(c, 0.0);
  vec3 hi = 0.9 + 0.1 * (1.0 - exp(-(c - 0.9) / 0.1));
  c = mix(c, hi, step(0.9, c));
  return pow(c, vec3(1.0 / 2.2));
}

void main(){
  vec3 N = normalize(vN);
  vec3 V = normalize(uCam - vW);
  float m = nightMix();
  float k = lightMix();
  float mm = mix(1.0, m, k);
  vec3 base = mix(uBaseA, uBaseB, mm);
  vec3 emit = mix(uEmitA, uEmitB, mm);
  float metal = uMetal, rough = uRough;
  float ao = 1.0;
  if (uKind == 10) {
    vec3 screen = texture(uTex, vUv, -0.8).rgb;
    float fresnel = 0.001 + 0.006 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
    vec3 reflection = mix(envA(reflect(-V, N), 0.14), envB(reflect(-V, N), 0.14), m);
    vec3 linear = screen * mix(0.04, 1.0, k) + reflection * fresnel * k;
    vec3 srgb = mix(linear * 12.92, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), linear));
    o = vec4(srgb, 1.0);
    return;
  }
  float sh = shadow(vW, N);
  vec3 col;

  if (uKind == 2) {
    vec2 lp = vL.xz;
    float r = length(lp);
    vec3 rad = normalize(mat3(uModel) * vec3(lp.x, 0.0, lp.y));
    vec3 T = normalize(cross(N, rad));
    float fw = fwidth(r);
    float groove = smoothstep(0.0562, 0.0590, r) * (1.0 - smoothstep(0.1452, 0.1462, r));
    float gap = 1.0 - smoothstep(0.0005, 0.0010, abs(r - 0.1175));
    gap = max(gap, 1.0 - smoothstep(0.0005, 0.0010, abs(r - 0.0945)));
    gap = max(gap, 1.0 - smoothstep(0.0004, 0.0009, abs(r - 0.0760)));
    float g = groove * (1.0 - gap);
    float f1 = 1.0 - smoothstep(0.25, 0.7, fw * 1400.0), f2 = 1.0 - smoothstep(0.25, 0.7, fw * 5200.0);
    float band = mix(1.0, 0.78 + 0.44 * h11(floor(r * 1400.0)), f1) * mix(1.0, 0.85 + 0.3 * h11(floor(r * 5200.0) + 7.0), f2);
    float dens = 0.9 + 0.1 * sin(r * 240.0 + sin(r * 97.0) * 3.0) * sin(r * 61.0);
    float NoV = clamp(dot(N, V), 0.001, 1.0);
    float fr = 0.045 + 0.955 * pow(1.0 - NoV, 5.0);
    vec3 Rm = reflect(-V, N);
    vec3 accA = vec3(0.0), accB = vec3(0.0);
    float ws = 0.0;
    for (int i = 0; i < 9; i++) {
      float f = (float(i) + 0.5) / 9.0 * 2.0 - 1.0;
      float ph = f * 1.2;
      vec3 n = normalize(N * cos(ph) + rad * sin(ph));
      float nv = dot(n, V);
      vec3 R = reflect(-V, n);
      float aph = abs(ph) - 0.62;
      float w0 = exp(-aph * aph / 0.11) + 0.22 * exp(-ph * ph / 0.05);
      float w = w0 * smoothstep(0.0, 0.15, nv) * smoothstep(0.04, 0.5, R.y);
      float fres = 0.045 + 0.955 * pow(1.0 - clamp(nv, 0.0, 1.0), 5.0);
      if (m < 0.999 && k > 0.0) accA += envA(R, 0.16) * w * fres;
      if (mm > 0.001) accB += envB(R, 0.16) * w * fres;
      ws += w0;
    }
    accA /= ws; accB /= ws;
    vec3 H = normalize(LK + V);
    float tdh = dot(T, H);
    float streak = pow(max(1.0 - tdh * tdh, 0.0), 260.0) * max(dot(N, LK), 0.0) * sh;
    float th = atan(lp.y, lp.x);
    float scuff = pow(vnoise(vec2(th * 30.0, r * 55.0)), 7.0) * g;
    float pl = pool();
    float shs = mix(0.5, 1.0, sh);
    vec3 dA = vec3(0.011) * (vec3(0.47) + vec3(0.66) * max(dot(N, LK), 0.0) * sh);
    vec3 cA = dA + (accA * band * dens * 4.2 * g + envA(Rm, 0.04) * fr * (1.0 - g)) * shs + vec3(0.9) * streak * g + vec3(0.05) * scuff;
    vec3 dB = vec3(0.011) * vec3(1.3, 0.98, 0.68) * pl * max(dot(N, LK), 0.0) * sh;
    vec3 cB = dB + (accB * band * dens * 4.2 * g + envB(Rm, 0.04) * fr * (1.0 - g)) * shs * (0.2 + 0.8 * pl) + vec3(1.3, 0.98, 0.68) * pl * streak * g * 0.8 + vec3(0.02, 0.016, 0.012) * scuff * pl;
    col = mix(cB * 0.05, mix(cA, cB, m), k);
    col += lampLight(vW, N) * 0.02 * mix(0.3, 1.0, mm);
    o = vec4(tone(col) + (ign(gl_FragCoord.xy) - 0.5) / 255.0, clamp((max(col.r, max(col.g, col.b)) - 1.0) * 0.35, 0.0, 0.5));
    return;
  }

  if (uKind == 1) {
    ao = occl(vW);
    float fwg = fwidth(vW.x) + fwidth(vW.z);
    float n = vnoise(vW.xz * 1100.0) * 0.6 + vnoise(vW.xz * 3300.0) * 0.4;
    n = mix(n, 0.5, smoothstep(0.25, 1.0, fwg * 1100.0));
    base *= mix(0.988 + 0.024 * n, 0.55 + 0.9 * n, mm);
    base *= mix(1.0, 0.93, smoothstep(1.2, 4.5, length(vW.xz - uSpot.xz)) * (1.0 - mm));
    rough = 0.96;
  } else if (uKind == 7) {
    ao = occl(vW);
    float fwg = fwidth(vW.x) + fwidth(vW.z);
    float n = vnoise(vW.xz * 700.0) * 0.5 + vnoise(vW.xz * 2400.0) * 0.5;
    float fib = vnoise(vec2(vW.x * 260.0 + vW.z * 90.0, vW.z * 3100.0 - vW.x * 400.0));
    n = mix(n * 0.7 + fib * 0.3, 0.5, smoothstep(0.25, 1.0, fwg * 700.0));
    base *= 0.8 + 0.4 * n;
    base *= mix(0.86, 1.0, smoothstep(0.0, 0.85, vUv.y));
    rough = 0.98;
  } else if (uKind == 3) {
    if (vLN.y > 0.5) {
      float dh = distance(vW.xz, uQ.xy);
      if (uQ.z > 0.0 && dh < uQ.z) discard;
      vec4 t = texture(uTex, vUv);
      base = mix(base, t.rgb, t.a);
      emit += t.rgb * t.a * uP.y * m * k;
      rough = mix(rough, uP.z, step(0.001, uP.z) * t.a);
      if (uQ.z > 0.0) {
        float g = vnoise(vW.xz * 5200.0);
        rough += (g - 0.5) * 0.1 * (1.0 - smoothstep(0.2, 1.0, (fwidth(vW.x) + fwidth(vW.z)) * 5200.0));
        float halo = exp(-max(0.0, dh - uQ.z) / (uQ.z * 2.4));
        emit += GLOW * uDark.z * halo * (0.085 + 0.04 * g) * mix(1.0, 0.3, k * (1.0 - m));
      }
    }
    ao = occl(vW);
  } else if (uKind == 4) {
    if (abs(vLN.y) < 0.5) {
      float th = atan(vL.z, vL.x) / 6.28318 + 0.5;
      float yy = clamp((vL.y - 0.0015) / 0.0115, 0.0, 0.999) * 4.0;
      float row = floor(yy);
      float cnt = 176.0 + row * 4.0;
      float aa = 1.0 - smoothstep(0.3, 0.8, fwidth(th * cnt));
      float ry = fract(yy) - 0.5;
      float ph = row < 0.5 ? uP.x : row < 1.5 ? uP.y : row < 2.5 ? uP.z : uP.w;
      float still = (1.0 - smoothstep(0.26, 0.36, length(vec2(fract(th * cnt) - 0.5, ry)))) * aa;
      float frozen = (1.0 - smoothstep(0.26, 0.36, length(vec2(fract(th * cnt + ph) - 0.5, ry)))) * aa;
      float band = (1.0 - smoothstep(0.24, 0.38, abs(ry))) * 0.45 * aa;
      float lampd = length(vW.xz - uQ.zw);
      float lit = exp(-lampd * lampd / 0.0026);
      float dotm = mix(still, mix(band, frozen, lit), uQ.x);
      base = mix(base * 0.42, base * 1.25, dotm);
      rough = mix(0.5, 0.22, dotm);
      emit += vec3(1.7, 0.22, 0.05) * mix(still, frozen, uQ.x) * lit * mix(0.3, 1.0, mm) * uDark.w;
    }
  } else if (uKind == 6) {
    float th = atan(vL.z, vL.x);
    if (abs(vLN.y) < 0.6 && vL.y > uP.z) {
      vec3 T = normalize(cross(vec3(0.0, 1.0, 0.0), N));
      float fwt = fwidth(th * uP.x);
      N = normalize(N + T * sin(th * uP.x) * 0.55 * (1.0 - smoothstep(0.6, 2.2, fwt)));
    }
    float line = (1.0 - smoothstep(uP.w * 0.6, uP.w, abs(vL.x))) * step(vL.z, -uP.y);
    base = mix(base, CREAM, line);
    metal *= 1.0 - line;
    emit += CREAM * 0.35 * line * m * k;
  } else if (uKind == 8) {
    float fine = 1.0 - smoothstep(0.4, 1.6, fwidth(vL.y * 26000.0));
    float line = h11(floor(vL.y * 26000.0));
    rough += (line - 0.5) * 0.09 * fine * step(0.001, uP.x);
    ao = mix(1.0, occl(vW), 0.5);
  } else if (uKind == 0) {
    ao = occl(vW);
    if (metal > 0.6) {
      float grain = vnoise(vec2(vL.x * 18000.0, vL.z * 220.0));
      float detail = 1.0 - smoothstep(0.2, 1.2, fwidth(vL.x * 18000.0));
      rough = clamp(rough + (grain - 0.5) * 0.055 * detail, 0.06, 1.0);
    }
  } else if (uKind == 9) {
    ao = occl(vW);
    float awake = 1.0 - smoothstep(uFront - 0.16, uFront, vUv.y);
    float edge = awake * (1.0 - smoothstep(uFront - 0.4, uFront - 0.16, vUv.y)) * step(uFront, 1e5);
    base = mix(DEAD, base, awake);
    float x = fract(uBeats * 0.5 - vUv.y / 1.1);
    float head = exp(-x * 5.0) + exp(-(1.0 - x) * 22.0);
    emit = (mix(uBaseA * 0.42, uBaseB * 1.5, m) * head * uLive + mix(uBaseA, uBaseB, mm) * edge * 1.4) * awake;
  }

  int taps = uKind == 8 && uP.x > 0.0 ? 5 : 1;
  vec3 axis = normalize(mat3(uModel) * vec3(0.0, 1.0, 0.0));
  col = vec3(0.0);
  for (int i = 0; i < taps; i++) {
    float f = taps == 1 ? 0.0 : float(i) * 0.5 - 1.0;
    float wt = taps == 1 ? 1.0 : (i == 2 ? 0.32 : (i == 1 || i == 3 ? 0.24 : 0.1));
    vec3 Ni = normalize(N + axis * f * uP.x);
    vec3 cA = vec3(0.0), cB = vec3(0.0), cD = vec3(0.0);
    if (k > 0.0) {
      if (m < 0.999) cA = litA(Ni, V, base, metal, rough, ao, sh);
      if (m > 0.001) cB = litB(Ni, V, base, metal, rough, ao, sh);
    }
    if (k < 0.999) cD = litD(Ni, V, base, metal, rough, ao, sh);
    col += mix(cD, mix(cA, cB, m), k) * wt;
  }
  vec3 lamp = lampLight(vW, N) * mix(1.0, mix(0.22, 1.0, m), k);
  col += lamp * (base * (1.0 - metal) + mix(vec3(0.04), base, metal) * 0.5);
  if (uKind == 5) {
    float deep = uP.y > 0.0 ? mix(0.5, 1.5, clamp(-vL.y / uP.y, 0.0, 1.0)) : 1.0;
    col = col * 0.3 + emit * uP.x * deep * mix(0.5, 1.0, mm);
  } else col += emit;
  if (uKind == 9) col = max(col, vec3(0.004, 0.0036, 0.0032) * (1.0 - k));
  o = vec4(tone(col) + (ign(gl_FragCoord.xy) - 0.5) / 255.0, clamp((max(col.r, max(col.g, col.b)) - 1.0) * 0.35, 0.0, 0.5));
}`;

export const POST_VERT = `#version 300 es
out vec2 vUv;
void main(){
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  vUv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

export const BRIGHT_FRAG = `#version 300 es
precision highp float;
uniform sampler2D uColor;
uniform vec2 uTexel;
uniform vec2 uScale;
in vec2 vUv;
out vec4 o;
void main(){
  vec2 uv = vUv * uScale;
  vec3 c = vec3(0.0);
  for (int i = 0; i < 4; i++) {
    vec2 d = vec2(float(i & 1), float(i >> 1)) * 2.0 - 1.0;
    vec4 s = texture(uColor, uv + d * uTexel);
    c += s.rgb * s.a * 2.0 * (1.0 - step(0.75, s.a));
  }
  o = vec4(c * 0.25, 1.0);
}`;

export const BLUR_FRAG = `#version 300 es
precision highp float;
uniform sampler2D uColor;
uniform vec2 uDir;
uniform vec2 uScale;
in vec2 vUv;
out vec4 o;
void main(){
  vec2 uv = vUv * uScale;
  vec3 c = texture(uColor, uv).rgb * 0.227;
  c += (texture(uColor, uv + uDir * 1.385).rgb + texture(uColor, uv - uDir * 1.385).rgb) * 0.316;
  c += (texture(uColor, uv + uDir * 3.231).rgb + texture(uColor, uv - uDir * 3.231).rgb) * 0.0703;
  o = vec4(c, 1.0);
}`;

export const DOF_FRAG = `#version 300 es
precision highp float;
uniform sampler2D uColor, uDepth;
uniform vec2 uRes;
uniform vec4 uDof;
uniform vec3 uFx;
uniform vec2 uScale;
in vec2 vUv;
out vec4 o;
float lin(float d){ return 2.0 * uDof.z * uDof.w / (uDof.w + uDof.z - (d * 2.0 - 1.0) * (uDof.w - uDof.z)); }
float coc(float z){ return min(uFx.z, uDof.y * abs(z - uDof.x) / z); }
float ign(vec2 p){ return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
void main(){
  vec2 uv = vUv * uScale;
  vec3 c = texture(uColor, uv).rgb;
  if (uDof.y > 0.0) {
    float cz = lin(texture(uDepth, uv).r);
    float cc = coc(cz);
    if (cc > 0.4) {
      float rot = ign(gl_FragCoord.xy) * 6.2831853;
      float lod = clamp(log2(cc * 0.5), 0.0, 4.0);
      vec3 acc = textureLod(uColor, uv, lod).rgb;
      float wsum = 1.0;
      for (int i = 0; i < 20; i++) {
        float r = sqrt((float(i) + 0.5) / 20.0) * cc;
        float a = float(i) * 2.3999632 + rot;
        vec2 suv = uv + vec2(cos(a), sin(a)) * r / uRes;
        float sz = lin(texture(uDepth, suv).r);
        float w = sz >= cz - 0.002 * cz ? 1.0 : smoothstep(r - 1.5, r + 0.5, coc(sz));
        acc += textureLod(uColor, suv, lod).rgb * w;
        wsum += w;
      }
      c = mix(c, acc / wsum, smoothstep(0.4, 1.2, cc));
    }
  }
  o = vec4(c, 1.0);
}`;

export const FINAL_FRAG = `#version 300 es
precision highp float;
uniform sampler2D uColor, uDepth, uBloom, uBlur;
uniform vec2 uRes;
uniform vec4 uDof;
uniform vec3 uFx;
uniform vec2 uScale;
in vec2 vUv;
out vec4 o;
float lin(float d){ return 2.0 * uDof.z * uDof.w / (uDof.w + uDof.z - (d * 2.0 - 1.0) * (uDof.w - uDof.z)); }
float coc(float z){ return min(uFx.z, uDof.y * abs(z - uDof.x) / z); }
float ign(vec2 p){ return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
void main(){
  vec2 uv = vUv * uScale;
  vec4 source = texture(uColor, uv);
  vec3 c = source.rgb;
  float scene = 1.0 - smoothstep(0.65, 0.95, source.a);
  if (uDof.y > 0.0) {
    float cc = coc(lin(texture(uDepth, uv).r));
    c = mix(c, texture(uBlur, uv).rgb, smoothstep(0.4, 1.2, cc) * scene);
  }
  c += texture(uBloom, uv).rgb * uFx.x * scene;
  vec2 q = vUv - 0.5;
  c *= 1.0 - uFx.y * scene * dot(q, q) * 1.6;
  o = vec4(c + (ign(gl_FragCoord.xy + 31.0) - 0.5) / 255.0, 1.0);
}`;
