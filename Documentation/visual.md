# PART 4 — VISUAL TEMPLATE (Design System "Prism")

## 4.1 Direction

Dark-first, glassmorphism accents, engineered calm. The overlay borrows from broadcast subtitles; the app interior feels like a precision instrument, not a toy. Light theme derived (rare but must exist for accessibility).

## 4.2 Color tokens

| Token | Dark | Light | Usage |
|---|---|---|---|
| `bg.canvas` | #0B0C10 | #F7F8FA | Screens |
| `surface.glass` | #16181F @ 82% | #FFFFFF @ 88% | Cards, sheets |
| `surface.glassStroke` | #FFFFFF @ 10% | #000000 @ 6% | Hairlines |
| `accent.primary` | #7C6BFF | #5B48F5 | CTAs, active nav |
| `accent.teal` | #38E1D4 | #0FA396 | Secondary accent, chips |
| `text.primary` | #F2F4F8 | #101216 | Body |
| `text.secondary` | #A6ADBB | #55607A | Meta |
| `semantic.warn` | #FFB65C | #B25E00 | Degraded-mode chips |
| `semantic.danger` | #FF5C77 | #C21833 | Stop actions |
| `overlay.scrim` | #000000 @ 55% | — | Behind modal sheets |

Accent pair (#7C6BFF→#38E1D4) reserved for gradients: primary CTA border, onboarding hero, model-progress rings. Nothing else gradients — restraint sells the glass.

## 4.3 Typography

- Family: **Manrope** (latin) with **Noto Sans JP/KR** fallback — non-negotiable for your ja/ko content screens; Turkish = latin ext.
- Scale: Display 32/40 · H1 24/32 · H2 20/28 · Body 15/22 · Meta 12/16 Medium caps · Code/mono: JetBrains Mono (timestamps only).

## 4.4 Shape & motion

Radius: xs 8 · sm 14 · md 20 · xl 28 · pill 999. Spacing 4-pt grid. Motion: 150 ms ease-out (chips/controls), 260 ms emphasized (sheets), overlay collapse after 3 s idle = 300 ms fade+scale .98.

## 4.5 Signature components

- **GlassCard** — surface.glass fill, stroke hairline, top-edge 1px sheen highlight, corner md.
- **PrimaryAction** — filled accent, subtle outer glow `0 0 24 primary@25%`, label semibold.
- **LangChip / ModeChip** — pill outline; active = teal tint.
- **ProgressRing** — model download & RTF gauge reuse (RTF ring: green<0.4 amber<0.8 red).
- **SpecSheet row** (settings) — icon, title, meta-right value, chevron.
- **SegmentRow** (editor/list) — leading timestamp mono chip, stacked text with hierarchy via weight not color-only (a11y).

## 4.6 Wireframes

**Dashboard**
```
┌──────────────────────────────┐
│ LiveLens          ⚙ 🔍       │  ← appbar, ghost buttons
│  ▢ Ready for Japanese media? │
│  ● ● Permission & model OK   │  ← preflight strip: green checks /
│                               │    amber links to wizard
│      ╭──────────────────╮    │
│      │  ▶ START TRANSLATION │   │  ← hero CTA (gradient border)
│      ╰──────────────────╯    │
│  Source: JA  Mode: Translate │  ← quick chips (persistent defaults)
│  Model: Base · Fast  ▪▪▪▫▫ 96fps-test │
│ ─ Recent sessions ──────────  │
│ ▸ NHK Evening News · Apr 12   │
│ ▸ Reels marathon · Apr 12     │
│ [ + Manual session ]          │
└──────────────────────────────┘
```

**Onboarding wizard (swipe pages):** hero illustration → “Why local?” privacy manifesto card → step list (Overlay / Notifications / Battery exemption / Projection explained as “appears like casting — normal, one-time-ish”)

**Model manager**
```
MODEL MANAGER            Storage used 0.6 GB
● Whispertiny — FAST      158 MB · installed [ACTIVE]
   ja·ko·tr·es … → en   RTF on this device 0.21
● Whisper base — BALANCED 182 MB [ Download ▸ 64%  ◖◖◖◻◻ ]
● Whisper small — QUALITY  480 MB · needs ~1.2 GB RAM ⚠ View device check
```

**Session detail (viewer/editor)** — session header (title, lang pair, duration, export icon menu) → sticky search bar → virtualized segmented list:
```
│ 00:31.2 ─────── JA → EN ───────────── ⋮ │
│ そろそろ出発したほうがいいと思います。        │
│ I think we should leave soon.             │
│───────────────────────────────────────────│
```
Tap segment → bottom sheet: Edit / Copy source / Copy translation / Merge ↑ / Split / Delete / Jump replay marker (future).

**Export sheet:** tabs TXT MD SRT VTT JSON · filename preview · include-timestamps toggle · Share | Save-to-Files.

**Settings groups:** Appearance / Overlay behaviour (idle timeout slider 0–10 s) / Languages & defaults / Models / Battery & thermal (governor prefs) / Privacy statement card / About-Licenses.

**Overlay widget (the crown jewel)**
```
MINIMAL (idle >3s)            EXPANDED (active)
┌───────────────────────┐     ┌────────────────────────────────────┐
│ I think we should go  │     │ ...we should go tomorrow.      ▪ Drag handle
│ tomorrow.             │     └──[⏸][JA▾][TR↦EN][⚙][✕]─────────────┘
└───────────────────────┘      controls fade-in only when touched
   translucent glass fill, 1px stroke, 20px radius, max-width 78%
```
States chips overlay-top-left: `⏸ Paused` · `🌡 Cooling down` · `🔋 Low battery mode`.

