(function () {
  'use strict';
  const NP = (window.NP = window.NP || {});

  function rng(seed) {
    let s = seed >>> 0;
    return function () {
      s = (s + 0x6d2b79f5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hash(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) h = Math.imul(h ^ str.charCodeAt(i), 16777619);
    return h >>> 0;
  }
  NP.rng = rng;
  NP.hash = hash;

  const FONT = "-apple-system, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif";

  function svg(inner) {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="600" height="600">${inner}</svg>`;
  }

  function artLowTide() {
    let water = '';
    for (let i = 0; i < 12; i++) {
      const w = 250 - i * 17 + (i % 2 ? 14 : 0);
      water += `<rect x="${300 - w / 2}" y="${366 + i * 19}" width="${w}" height="${7 - i * 0.3}" rx="3.5" fill="#F7B26A" opacity="${(0.85 - i * 0.065).toFixed(2)}"/>`;
    }
    let lines = '';
    for (let i = 0; i < 9; i++) {
      lines += `<rect x="0" y="${372 + i * 25}" width="600" height="1.2" fill="#7FE0D3" opacity="${(0.22 - i * 0.02).toFixed(2)}"/>`;
    }
    return svg(`<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#081430"/><stop offset=".5" stop-color="#123B63"/><stop offset="1" stop-color="#1D7A84"/></linearGradient>
<radialGradient id="sun" cx=".5" cy=".42" r=".6"><stop offset="0" stop-color="#FFE3B5"/><stop offset=".55" stop-color="#F7B26A"/><stop offset="1" stop-color="#E2774B"/></radialGradient>
<radialGradient id="glow" cx=".5" cy=".6" r=".5"><stop offset="0" stop-color="#F7B26A" stop-opacity=".55"/><stop offset="1" stop-color="#F7B26A" stop-opacity="0"/></radialGradient>
<linearGradient id="sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0E3250"/><stop offset="1" stop-color="#06162B"/></linearGradient>
<clipPath id="above"><rect width="600" height="356"/></clipPath>
</defs>
<rect width="600" height="600" fill="url(#sky)"/>
<rect width="600" height="600" fill="url(#glow)"/>
<circle cx="300" cy="356" r="132" fill="url(#sun)" clip-path="url(#above)"/>
<rect y="356" width="600" height="244" fill="url(#sea)"/>
${lines}${water}
<text x="44" y="78" font-family="${FONT}" font-weight="700" font-size="22" letter-spacing="7" fill="#E9F7F4" opacity=".92">LOW TIDE</text>
<text x="556" y="78" text-anchor="end" font-family="${FONT}" font-weight="300" font-size="22" letter-spacing="4" fill="#E9F7F4" opacity=".75">041</text>
<text x="44" y="560" font-family="${FONT}" font-weight="500" font-size="15" letter-spacing="5" fill="#BFE8E1" opacity=".6">LIVE AT PIER NINE</text>`);
  }

  function artPaperSatellites() {
    const r = rng(7);
    let stars = '';
    for (let i = 0; i < 46; i++) {
      stars += `<circle cx="${(r() * 600).toFixed(1)}" cy="${(r() * 600).toFixed(1)}" r="${(r() * 1.6 + 0.4).toFixed(2)}" fill="#FFF4EC" opacity="${(r() * 0.6 + 0.2).toFixed(2)}"/>`;
    }
    return svg(`<defs>
<radialGradient id="bg" cx=".32" cy=".28" r=".95"><stop offset="0" stop-color="#FFC2CF"/><stop offset=".28" stop-color="#E86BA8"/><stop offset=".62" stop-color="#6B2E9E"/><stop offset="1" stop-color="#1F0F3D"/></radialGradient>
<radialGradient id="pl" cx=".35" cy=".3" r=".8"><stop offset="0" stop-color="#FFE7D6"/><stop offset=".6" stop-color="#FF9FB6"/><stop offset="1" stop-color="#B04C9C"/></radialGradient>
</defs>
<rect width="600" height="600" fill="url(#bg)"/>
${stars}
<g transform="rotate(-18 300 330)" fill="none" stroke="#FFE6DA" stroke-width="2">
<ellipse cx="300" cy="330" rx="250" ry="78" opacity=".5"/>
<ellipse cx="300" cy="330" rx="175" ry="52" opacity=".35"/>
</g>
<circle cx="300" cy="330" r="74" fill="url(#pl)"/>
<circle cx="535" cy="262" r="11" fill="#FFF6F0"/>
<circle cx="118" cy="402" r="7" fill="#FFF6F0" opacity=".9"/>
<g transform="translate(402 128) rotate(-14)"><path d="M0 34 L92 0 L52 70 L42 44 Z" fill="#FFF8F4"/><path d="M42 44 L92 0 L52 70 Z" fill="#F4D4E4"/></g>`);
  }

  function artNorthbound() {
    return svg(`<defs>
<linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4ECD6"/><stop offset=".6" stop-color="#D3E0C0"/><stop offset="1" stop-color="#A9C59C"/></linearGradient>
</defs>
<rect width="600" height="600" fill="url(#sk)"/>
<circle cx="438" cy="150" r="48" fill="#FFF9EA"/>
<path d="M0 330 L90 250 L160 300 L250 200 L330 280 L410 220 L520 300 L600 250 L600 600 L0 600Z" fill="#A9C59C"/>
<path d="M0 390 L110 300 L200 370 L300 280 L390 360 L470 310 L600 380 L600 600 L0 600Z" fill="#6E9C7A"/>
<path d="M0 460 L140 370 L240 440 L350 360 L460 450 L600 400 L600 600 L0 600Z" fill="#33694F"/>
<path d="M0 530 L120 470 L260 530 L380 470 L520 540 L600 510 L600 600 L0 600Z" fill="#11291F"/>
<path d="M300 600 L292 540 L308 540 Z" fill="#F4ECD6" opacity=".5"/>`);
  }

  function artSodiumLights() {
    let lamps = '';
    let glows = '';
    for (let i = 0; i < 7; i++) {
      const k = Math.pow(0.72, i);
      const xl = 300 - 250 * k;
      const xr = 300 + 250 * k;
      const y = 300 - 210 * k + 40;
      const s = 70 * k + 8;
      glows += `<circle cx="${xl.toFixed(1)}" cy="${y.toFixed(1)}" r="${(s * 1.9).toFixed(1)}" fill="url(#lg)"/><circle cx="${xr.toFixed(1)}" cy="${y.toFixed(1)}" r="${(s * 1.9).toFixed(1)}" fill="url(#lg)"/>`;
      lamps += `<circle cx="${xl.toFixed(1)}" cy="${y.toFixed(1)}" r="${(s * 0.16).toFixed(1)}" fill="#FFF1C4"/><circle cx="${xr.toFixed(1)}" cy="${y.toFixed(1)}" r="${(s * 0.16).toFixed(1)}" fill="#FFF1C4"/>`;
    }
    let dashes = '';
    for (let i = 0; i < 8; i++) {
      const a = Math.pow(0.7, i);
      const b = Math.pow(0.7, i + 0.5);
      dashes += `<path d="M${300 - 7 * a} ${330 + 270 * a} L${300 + 7 * a} ${330 + 270 * a} L${300 + 7 * b} ${330 + 270 * b} L${300 - 7 * b} ${330 + 270 * b}Z" fill="#FDE68A" opacity=".85"/>`;
    }
    return svg(`<defs>
<linearGradient id="nt" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0E0819"/><stop offset=".55" stop-color="#3A1236"/><stop offset="1" stop-color="#140A14"/></linearGradient>
<radialGradient id="lg"><stop offset="0" stop-color="#FFB547" stop-opacity=".75"/><stop offset=".35" stop-color="#F08A24" stop-opacity=".28"/><stop offset="1" stop-color="#F08A24" stop-opacity="0"/></radialGradient>
<radialGradient id="hz" cx=".5" cy=".55" r=".5"><stop offset="0" stop-color="#FF7A45" stop-opacity=".45"/><stop offset="1" stop-color="#FF7A45" stop-opacity="0"/></radialGradient>
</defs>
<rect width="600" height="600" fill="url(#nt)"/>
<rect width="600" height="600" fill="url(#hz)"/>
<path d="M0 600 L270 330 L330 330 L600 600Z" fill="#0A0610"/>
${glows}${lamps}${dashes}`);
  }

  function artGeneric(seed, hue) {
    const r = rng(seed);
    const h2 = (hue + 30 + r() * 40) % 360;
    const v = seed % 4;
    let shapes = '';
    if (v === 0) {
      for (let i = 6; i > 0; i--) shapes += `<circle cx="300" cy="300" r="${i * 46}" fill="hsl(${(hue + i * 9) % 360} 62% ${22 + i * 7}%)" opacity=".9"/>`;
    } else if (v === 1) {
      for (let i = 0; i < 9; i++) shapes += `<rect x="${-200 + i * 110}" y="-100" width="44" height="900" fill="hsl(${h2} 70% 70%)" opacity="${0.08 + (i % 3) * 0.06}" transform="rotate(28 300 300)"/>`;
      shapes += `<circle cx="300" cy="300" r="120" fill="hsl(${h2} 80% 72%)" opacity=".85"/>`;
    } else if (v === 2) {
      for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) shapes += `<circle cx="${60 + x * 69}" cy="${60 + y * 69}" r="${(6 + 10 * Math.abs(Math.sin((x + y) * 0.6 + seed))).toFixed(1)}" fill="hsl(${h2} 75% 76%)" opacity=".7"/>`;
    } else {
      shapes += `<circle cx="300" cy="600" r="300" fill="hsl(${h2} 72% 64%)"/><circle cx="300" cy="600" r="210" fill="hsl(${hue} 60% 30%)" opacity=".55"/><rect x="0" y="470" width="600" height="2" fill="#fff" opacity=".4"/>`;
    }
    return svg(`<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue} 55% 18%)"/><stop offset="1" stop-color="hsl(${h2} 62% 46%)"/></linearGradient></defs><rect width="600" height="600" fill="url(#g)"/>${shapes}`);
  }

  function dataURL(s) {
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(s);
  }

  function blurURL(art, base) {
    const inner = art.replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');
    return dataURL(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="600" height="600"><defs><filter id="npblur" x="-40%" y="-40%" width="180%" height="180%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="54"/><feColorMatrix type="saturate" values="1.65"/></filter></defs><rect width="600" height="600" fill="${base}"/><g filter="url(#npblur)"><g transform="translate(300 300) scale(1.45) translate(-300 -300)">${inner}</g></g></svg>`
    );
  }

  function makeWave(seed, n, kind, segments, duration) {
    const r = rng(seed);
    const out = new Float32Array(n);
    const ph = [r() * 6.28, r() * 6.28, r() * 6.28];
    let sections;
    if (kind === 'mix') {
      sections = segments.map((s, i) => ({ a: s / duration, e: 0.55 + 0.4 * Math.abs(Math.sin(i * 1.7 + seed)) }));
    } else {
      const sc = [0, 0.08, 0.3, 0.46, 0.62, 0.78, 0.92];
      const en = [0.32, 0.62, 0.92, 0.55, 0.98, 0.7, 0.35];
      sections = sc.map((a, i) => ({ a, e: en[i] }));
    }
    let si = 0;
    for (let i = 0; i < n; i++) {
      const x = i / n;
      while (si < sections.length - 1 && x >= sections[si + 1].a) si++;
      const sec = sections[si];
      const nextA = si < sections.length - 1 ? sections[si + 1].a : 1;
      let e = sec.e;
      const edge = Math.min(x - sec.a, nextA - x) * (kind === 'mix' ? 220 : 60);
      if (edge < 1) e *= 0.55 + 0.45 * Math.max(0, edge);
      const wob = 0.12 * Math.sin(x * 90 + ph[0]) + 0.08 * Math.sin(x * 211 + ph[1]) + 0.05 * Math.sin(x * 517 + ph[2]);
      let v = e * (0.78 + wob) + (r() - 0.5) * 0.22;
      if (x < 0.02) v *= x / 0.02;
      if (x > 0.975) v *= (1 - x) / 0.025;
      out[i] = Math.max(0.06, Math.min(1, v));
    }
    for (let k = 0; k < 1; k++) for (let i = 1; i < n - 1; i++) out[i] = out[i] * 0.6 + (out[i - 1] + out[i + 1]) * 0.2;
    return out;
  }

  const people = {
    harbourlights: 196, 'nadia.k': 330, orbital_ida: 262, 'Tomás R': 24, kitelines: 160, sleeplessinleeds: 210,
    'Mika Oduya': 12, 'loop.theory': 280, grey_heron: 100, dj_wren: 48, 'Ruth A.': 350, 'Sol Mendes': 40,
    quietfm: 230, 'Ines Park': 300, 'b.ferro': 140, 'Owen L': 80, You: 0,
  };
  NP.personHue = (name) => (name in people ? people[name] : hash(name) % 360);

  const mixComments = [
    [45, 'harbourlights', 'that opening field recording of the pier'],
    [130, 'nadia.k', 'been waiting all week for this one'],
    [238, 'orbital_ida', 'the way Saltwater creeps in under the intro'],
    [300, 'Tomás R', 'volume up, windows down'],
    [412, 'kitelines', 'this bassline is doing something to me'],
    [505, 'sleeplessinleeds', 'first drop and I’m already gone'],
    [560, 'Mika Oduya', 'Lanterns edit!! been hunting this for months'],
    [655, 'loop.theory', 'that filter sweep is so clean'],
    [742, 'harbourlights', 'was front left at Pier Nine, this moment was unreal'],
    [818, 'grey_heron', 'Undertow into this is a lesson in patience'],
    [905, 'nadia.k', 'the strings at 15:05'],
    [962, 'dj_wren', 'Maren never misses on the long build'],
    [1012, 'Ruth A.', 'ID at 17:48 anyone?'],
    [1041, 'kitelines', 'sounds like unreleased Ardent Fields to me'],
    [1068, 'Ines Park', 'this is my whole Sunday sorted'],
    [1102, 'orbital_ida', 'the breakdown here… goosebumps'],
    [1190, 'b.ferro', 'turned it up and the neighbours didn’t complain'],
    [1268, 'loop.theory', 'Glass Tide on repeat after this'],
    [1330, 'Tomás R', 'that vocal chop at 22:10'],
    [1418, 'quietfm', 'perfect blend, can’t hear the seam'],
    [1525, 'grey_heron', 'Cassia Moor dub!! I need this on vinyl'],
    [1640, 'sleeplessinleeds', '28 minutes in and not one wasted bar'],
    [1755, 'Mika Oduya', 'that low end on a proper system'],
    [1882, 'nadia.k', 'halfway and it only gets better'],
    [1990, 'harbourlights', 'Halfway House at the halfway point. cute.'],
    [2140, 'dj_wren', 'tempo nudge here is so subtle'],
    [2230, 'Ruth A.', 'another ID at 37:02, anyone?'],
    [2290, 'quietfm', 'that pad is like the sea at 5am'],
    [2410, 'Sol Mendes', 'the room went silent for this part'],
    [2505, 'kitelines', 'Sodium Lights club mix. the peak.'],
    [2580, 'orbital_ida', '42:05 is THE moment'],
    [2690, 'Owen L', 'hands in the air at my desk'],
    [2850, 'grey_heron', 'Long Exposure is such an underrated tune'],
    [3010, 'Tomás R', 'she brought it all the way down'],
    [3215, 'nadia.k', 'Paper Satellites rework!! didn’t see that coming'],
    [3390, 'harbourlights', 'what a closer. thank you Maren'],
    [3520, 'Sol Mendes', 'straight back to the start'],
  ];

  const setlist = [
    [0, 'Maren Holt', 'Tide Tables (Intro)'],
    [232, 'Teodora', 'Saltwater'],
    [510, 'Pale Harbour', 'Lanterns (Maren Holt Edit)'],
    [785, 'Kōji Aren', 'Undertow'],
    [1068, null, null, { artist: 'Ardent Fields', title: 'Breakwater', note: 'Unreleased' }],
    [1330, 'Nilu & Brask', 'Glass Tide'],
    [1655, 'Cassia Moor', 'Northbound (Dub)'],
    [1940, 'Sennet', 'Halfway House'],
    [2222, null, null, { artist: 'Moss Atlas', title: 'Sea Glass', note: 'Forthcoming on Pier Nine Records' }],
    [2500, 'Okari', 'Sodium Lights (Club Mix)'],
    [2835, 'Fen Ashby', 'Long Exposure'],
    [3210, 'Juno Vale', 'Paper Satellites (Maren Holt Rework)'],
  ].map(([t, artist, title, match]) => ({ t, artist, title, unknown: !artist, match }));

  const tracks = [
    {
      id: 'lowtide', kind: 'mix', title: 'Low Tide 041 — Live at Pier Nine', short: 'Low Tide 041', artist: 'Maren Holt',
      duration: 3600, art: artLowTide(), bpm: 122, key: '8A · A minor', genre: 'Deep House',
      plays: '48.2K', likes: '3,118', reposts: '412', posted: '12 October 2026',
      tags: ['deep house', 'live set', 'pier nine', 'sunrise'],
      description: 'Recorded live on the closing night at Pier Nine, a little after sunrise. Two hours condensed to one. Thanks to everyone who stayed until the tide came back in.',
      palette: { base: '#0A1C36', c1: '#1D7A84', c2: '#F7B26A', c3: '#123B63', tintDark: '#9FE3D8', tintLight: '#0E6A72', glass: '#1D5E78' },
      comments: mixComments, setlist,
      cues: [[0, 'Intro', 'blue'], [270, 'First drop', 'teal'], [1150, 'Breakdown', 'violet'], [2525, 'Peak', 'amber'], [3460, 'Outro', 'rose']],
    },
    {
      id: 'paper', kind: 'song', title: 'Paper Satellites', artist: 'Juno Vale', duration: 222, art: artPaperSatellites(),
      bpm: 104, key: '11B · A major', genre: 'Dream Pop', plays: '212K', likes: '9,840', reposts: '1,203', posted: '3 March 2026',
      tags: ['dream pop', 'synth', 'indie'],
      description: 'Written on the night train to Lisbon. Every sound on this was made with a broken Juno-60 and a toy glockenspiel.',
      palette: { base: '#2A1446', c1: '#E86BA8', c2: '#FFC2CF', c3: '#6B2E9E', tintDark: '#FFC4DC', tintLight: '#A02F74', glass: '#7E3A8E' },
      comments: [
        [14, 'Ines Park', 'that first synth note'], [38, 'b.ferro', 'chorus hits so hard'], [61, 'nadia.k', 'the glockenspiel!!'],
        [92, 'Owen L', 'this was playing when I met my partner'], [118, 'orbital_ida', 'bridge is pure sunlight'],
        [151, 'kitelines', 'the harmony here'], [176, 'quietfm', 'best song of the year, no contest'], [204, 'Sol Mendes', 'that ending fade'],
      ],
      cues: [[0, 'Intro', 'blue'], [38, 'Chorus', 'rose'], [118, 'Bridge', 'violet']],
    },
    {
      id: 'north', kind: 'song', title: 'Northbound', artist: 'Cassia Moor', duration: 258, art: artNorthbound(),
      bpm: 92, key: '3A · B♭ minor', genre: 'Folktronica', plays: '76.4K', likes: '4,402', reposts: '388', posted: '21 July 2026',
      tags: ['folktronica', 'ambient', 'field recordings'],
      description: 'Field recordings from the north coast of Skye, stitched into something you can walk to.',
      palette: { base: '#14301F', c1: '#6E9C7A', c2: '#F4ECD6', c3: '#33694F', tintDark: '#D7E8B8', tintLight: '#2F6B4F', glass: '#3E6E52' },
      comments: [
        [20, 'grey_heron', 'you can hear the wind in the mics'], [55, 'dj_wren', 'this kick is so soft'], [88, 'harbourlights', 'walking song forever'],
        [130, 'Ruth A.', 'the guitar loop'], [171, 'Mika Oduya', 'perfect for the train home'], [214, 'loop.theory', 'that tape stop'],
        [240, 'Tomás R', 'over too soon'],
      ],
      cues: [[0, 'Intro', 'blue'], [88, 'Drop', 'teal'], [214, 'Tape stop', 'amber']],
    },
    {
      id: 'sodium', kind: 'song', title: 'Sodium Lights', artist: 'Okari', duration: 185, art: artSodiumLights(),
      bpm: 128, key: '5A · C minor', genre: 'Electronica', plays: '131K', likes: '7,215', reposts: '940', posted: '30 September 2026',
      tags: ['electronica', 'night drive', 'synthwave'],
      description: 'For the drive home along the ring road at 3am, when every light turns amber.',
      palette: { base: '#1A0B1C', c1: '#F08A24', c2: '#FFB547', c3: '#5B1A3A', tintDark: '#FFD08A', tintLight: '#A24A10', glass: '#6A2A3A' },
      comments: [
        [12, 'sleeplessinleeds', 'drive music'], [44, 'kitelines', 'that arp'], [77, 'Sol Mendes', 'the drop!!'],
        [103, 'Owen L', 'windows down'], [140, 'Ines Park', 'synth solo goes so hard'], [168, 'quietfm', 'one more time'],
      ],
      cues: [[0, 'Intro', 'blue'], [77, 'Drop', 'rose']],
    },
  ];

  const fillers = [
    ['Harbour Static', 'Fen Ashby', 214, 196], ['Slow Bloom', 'Ilse Varga', 263, 330], ['Weather Systems', 'Nilu & Brask', 301, 220],
    ['Lanterns', 'Pale Harbour', 246, 40], ['Undertow', 'Kōji Aren', 288, 175], ['Halfway House', 'Sennet', 232, 265],
  ];
  const pool = ['love this', 'on repeat', 'that drop', 'perfect for the evening', 'so warm', 'need the stems', 'goosebumps'];
  fillers.forEach(([title, artist, duration, hue], i) => {
    const r = rng(100 + i);
    tracks.push({
      id: 'f' + i, kind: 'song', title, artist, duration, art: artGeneric(11 + i * 7, hue), bpm: 96 + Math.round(r() * 30),
      key: ['4A · F minor', '9B · G major', '1A · A♭ minor', '6B · B♭ major'][i % 4], genre: ['Ambient', 'Deep House', 'Downtempo', 'Electronica'][i % 4],
      plays: (10 + Math.round(r() * 80)) + 'K', likes: String(400 + Math.round(r() * 3000)), reposts: String(30 + Math.round(r() * 300)),
      posted: ['May', 'June', 'August', 'January'][i % 4] + ' 2026', tags: ['electronic'], description: 'From the forthcoming EP.',
      palette: {
        base: `hsl(${hue} 50% 14%)`, c1: `hsl(${(hue + 40) % 360} 62% 46%)`, c2: `hsl(${(hue + 60) % 360} 75% 72%)`, c3: `hsl(${hue} 55% 26%)`,
        tintDark: `hsl(${(hue + 50) % 360} 80% 82%)`, tintLight: `hsl(${hue} 60% 32%)`, glass: `hsl(${hue} 45% 34%)`,
      },
      comments: [0, 1, 2].map((k) => [Math.round(duration * (0.15 + k * 0.3)), Object.keys(people)[(i * 3 + k) % 15], pool[(i + k) % pool.length]]),
      cues: [[0, 'Intro', 'blue'], [Math.round(duration * 0.3), 'Drop', 'teal']],
    });
  });

  tracks.forEach((t, i) => {
    t.artURL = dataURL(t.art);
    t.blurURL = blurURL(t.art, t.palette.base);
    t.comments = t.comments.map(([time, user, text], k) => ({ id: t.id + '-c' + k, t: time, user, text }));
    t.cues = t.cues.map(([time, label, color]) => ({ t: time, label, color }));
    t.wave = makeWave(hash(t.id), 900, t.kind, t.setlist ? t.setlist.map((s) => s.t) : [], t.duration);
    t.playlist = 'Late Night Mixes';
    t.url = 'sounding.app/' + t.artist.toLowerCase().replace(/[^a-z]+/g, '-') + '/' + t.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '');
  });

  const byId = {};
  tracks.forEach((t) => (byId[t.id] = t));

  NP.data = {
    tracks,
    byId,
    heroes: ['lowtide', 'paper', 'north', 'sodium'],
    queue: ['lowtide', 'paper', 'north', 'sodium', 'f0', 'f1', 'f2', 'f3', 'f4', 'f5'],
    playNext: ['paper', 'north'],
    devices: [
      { id: 'iphone', name: 'iPhone', kind: 'iphone' },
      { id: 'tv', name: 'Living Room', sub: 'Apple TV', kind: 'tv' },
      { id: 'mac', name: 'MacBook Pro', kind: 'mac' },
    ],
    people,
    me: { name: 'You', initial: 'A' },
    dataURL,
  };
})();
