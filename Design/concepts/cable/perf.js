window.CABLE_PERF = {
  v1: 'Measured (headless Chrome, 1440×900, 4 s from Replay): 238 frames, p50 16.7 ms, p99 16.8 ms. Longest task 9 ms (the Replay rebuild: 7 ms script).',
  v2: 'Measured (1440×900 and 390×844, 4 s): p99 16.8 ms at both sizes, no frame over 16.8 ms on mobile. Replay rebuild 3 ms of script.',
  v3: 'Measured (1440×900, 4 s): 241 frames, p99 16.8 ms, max 16.8 ms, no long animation frames.',
  v4: 'Measured (1440×900, a 6 s scripted scroll through the whole page): 356 frames, p99 16.8 ms, max 16.8 ms, no long animation frames.',
  v5: 'Measured (1440×900 and 390×844, 4 s demo): p99 16.8 ms. Rope step + canvas draw ≈ 0.1 ms per frame; longest task 2.4 ms.',
  v6: 'Measured (1440×900, 4 s): 240 frames, p99 16.8 ms, one 33 ms frame as the 3D stack is first composited.',
};
