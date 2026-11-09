# Anti-slop checklist for the Sounding website

Compiled 2026-11-06 from current write-ups on what makes a site read as AI-generated. Sources are at the bottom. No single item damns a page: it's the stack of defaults together. The page must fail almost none of these.

## Type
- [ ] No unchosen default fonts: Inter, Poppins or Geist used only because they were the default.
- [ ] No Instrument Serif headline paired with a mono caption, the 2026 "tasteful AI" default.
- [ ] No small uppercase eyebrow or mono caption above every heading ("01 / GET INTO IT", "AN INDEPENDENT APP").
- [ ] One deliberate type scale with real contrast: few sizes, a clear hierarchy, body text at least 16 px. Not 18+ ad-hoc sizes.
- [ ] No gradient text on "the one word that matters".
- [ ] No em-dash-heavy copy.

## Colour
- [ ] No purple, indigo or blue gradients, and no Tailwind blue or indigo defaults.
- [ ] No glowing blob, aurora or radial bloom behind the hero.
- [ ] One dominant colour, one accent (copper) and one neutral. No palette-cycling cards (red, blue, green, orange).
- [ ] No permanent dark mode by reflex. Follow the system, with a real light design.
- [ ] Contrast of at least 4.5:1 everywhere.

## Layout and components
- [ ] No pill or badge above the hero headline ("✨ New", "AI-powered", "Not on the App Store").
- [ ] Not a centred hero with two buttons plus a logo strip.
- [ ] No row of three identical icon-topped feature cards, and no bento grid.
- [ ] No "1 · 2 · 3" numbered steps, no stats row, and no A/B/C lettered lists.
- [ ] No card around every block of content, no nested cards, and no coloured left-border strip on cards. Group with whitespace, proximity and type instead.
- [ ] No glassmorphism or backdrop-blur nav by reflex, and not the same rounded-2xl and soft shadow on everything.
- [ ] Consistency: one corner radius, one shadow rule, one spacing scale.
- [ ] No vertical rotated labels, decorative captions ("A GOOD CONNECTION.", "Design preview") or fake chrome.

## Motion
- [ ] No fade-and-slide-up on every section. Motion must mean something: the cable, the device scenes.
- [ ] No scroll-jacking, and nothing that alters native scroll speed.
- [ ] No transitions over about 500 ms that feel like lag.
- [ ] No pointless hover effects, and no buttons that look clickable but go nowhere.

## Copy
- [ ] No adjective-stacked subtitles, "Elevate your…", "Trusted by…", or vague SaaS wording.
- [ ] No slogan on every section ("Stay for one more track.", "Same track. Different room.").
- [ ] No generic FAQ filler. Answer only real questions.
- [ ] Specific, product-true sentences in the owner's voice: British English, short.
- [ ] Real product evidence: real app screenshots and the owner's real music, not mock UI.

## Positive direction
Commit to one aesthetic and write its tokens in `DESIGN.md`: palette, type, radius, spacing and motion. For Sounding, that means:
- the copper aux-cable line art as the single signature element, threading the page;
- a paper and near-black ground, with copper as the only accent;
- a clear type scale;
- real devices and real music;
- lots of whitespace.

## Sources
- [Is your website AI slop? (DEV Community)](https://dev.to/laurilllll/is-your-website-ai-slop-how-to-tell-and-how-to-fix-it-1fn5)
- [AI Slop Fonts and Gradients (925studios)](https://www.925studios.co/blog/ai-slop-design-tells)
- [AI Slop Web Design guide (925studios)](https://www.925studios.co/blog/ai-slop-web-design-guide)
- [AI Slop Design fix guide (vibecodekit)](https://vibecodekit.dev/ai-slop-design)
- [AI slop website checklist (illos.dev)](https://illos.dev/guides/ai-slop-website-checklist)
- [AI Slop: the tells on a website (sailop)](https://sailop.com/blog/ai-slop-definitive-guide-2026)
- [20 Signs a Website Was Made by AI (SCALR)](https://scalr.sg/blog/20-signs-a-website-was-made-by-ai/)
- [Why every AI landing page looks generic (designdotmd)](https://freedesignmd.com/blog/why-ai-landing-page-looks-generic)
- [How to spot an AI-built website (falia)](https://falia.co/en/insights/web-design/spot-ai-built-website/)
- [AI Design Slop: 16 patterns (Developers Digest)](https://www.developersdigest.tech/blog/ai-design-slop-and-how-to-spot-it)
- [7 Signs a UI Has Been Vibe Coded (Fountain Institute)](https://www.thefountaininstitute.com/blog/signs-vibe-coded-ui)
- [How to avoid apps that look vibe coded (vibemole)](https://vibemole.com/resources/avoid-vibecoded-app-design)
- [Vibe coded website design: 8 mistakes (SiteCritic)](https://www.sitecritic.ai/blog/vibe-coded-website-design-8-mistakes-to-fix-now)
