# Xinxin IP Contract (v2 Master)

Version: xinxin-persona-v2.1
Scope: xinxin-run sprite generation and post-merge quality checks.

## 1) Identity Lock
- Keep identity exact from `references/canonical-base.png` and `decoded/base.png`.
- Face silhouette, long wavy hair shape, eyes, smile, pink scarf-top with side bow, layered skirt, necklace, shoes, and body proportions must remain unchanged in all states.
- Accessory side/scale and outline weight (thick dark sprite-like outline) must remain stable.
- No redesign, no style drift, no new props, no morph into another character.

## 2) Style Contract
- Chibi mascot sprite style, chunky silhouettes, stepped/pixel-friendly edges, limited palette.
- Flat chroma key background: `#00FFFF` only.
- No gradients, no heavy filters, no polished rendering, no glow/shadows/blur.
- No text, labels, logos, UI, or scene elements.

## 3) Animation State Contract
- `idle`: 6 frames, calm and still, subtle breathing/blink.
- `running`: 6 frames, compact active working gesture, no locomotion travel style.
- `running-right`: 8 frames, right-facing motion rhythm.
- `running-left`: 8 frames, left-facing mirror rhythm.
- `waving`: 4 frames, clear friendly wave return loop.
- `jumping`: 5 frames, compact vertical hop with recovery.
- `failed`: 8 frames, recovery-feel disappointment, low energy.
- `waiting`: 6 frames, patient sway and blink.
- `review`: 6 frames, micro-checking, attentive expression.
- Every state is loop-safe with matching start/end pose continuity.

## 4) Composition & Layout
- Frames are a single-row sprite sheet using the corresponding row layout guides as spacing reference only.
- One complete full-body pose per slot; no overlap or clipping between slots.
- Keep subject fully in frame with safe padding.
- Preserve side placement and orientation; no abrupt flipping unless state specifically requires left/right running.

## 5) Anti-Drift / Prohibited
- Do not use detached effects (floating stars, smoke, notes, icons, trails).
- Do not use symbols, text, UI artifacts, frame numbers, guide lines, borders, and no additional props.
- No color near chroma key for the pet and no background elements.
- No major silhouette deformation, broken limbs, disconnected body components.

## 6) QA Acceptance Rules
- Visual identity is clearly consistent across all rows.
- Each output must be one clean row strip with exact frame count per state.
- Action is readable at low resolution; no major clipping or empty slots.
- Loop continuity without pops.
