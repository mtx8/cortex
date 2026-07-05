# CortexX Design System

Derived from the Silo Unison Studio aesthetic (the Principal's reference app):
clean, dark, restrained, hairline-bordered panels on a near-black canvas with
a single warm accent. No glassmorphism, no neon, no gradients-for-decoration,
no emoji anywhere in the UI.

## Tokens

| Token       | Value                          | Use |
|-------------|--------------------------------|-----|
| `ink`       | `#0A0A0C`                      | Window canvas. Never pure black. |
| `panel`     | `#131318`                      | Cards, sidebars, sheets, inputs. |
| `panelHi`   | `#1A1A21`                      | Hover / selected panel state. |
| `line`      | `#26262E`                      | 1 px hairline borders, dividers. |
| `bone`      | `#F5EFE4`                      | Primary text. Never `#FFFFFF`. |
| `dim`       | `#8B8B96`                      | Secondary text, labels, metadata. |
| `ember`     | `#E08A2A`                      | THE accent: selection, focus, primary buttons, AI presence. |
| `emberHi`   | `#EDA23F`                      | Accent hover. |
| `emberDown` | `#B56F1E`                      | Accent pressed / focused border. |
| `emberTint` | `ember @ 10% alpha`            | Accent hover wash, selected row background. |
| `up`        | `#3FB68B`                      | P&L positive, buy side, up candles ONLY. |
| `down`      | `#D8233A`                      | P&L negative, sell side, down candles, errors ONLY. |
| `warn`      | `#D8A123`                      | Risk warnings, degraded feed. |

Semantic rule: green/red mean money and direction, nothing else. Ember means
attention, selection, and AI. Everything else is ink/panel/bone/dim.

## Type

- System font (SF Pro): body 13 pt regular, 1.4–1.5 line height.
- Section labels: 11 pt, semibold, UPPERCASE, letter-spacing ~0.25 em, `dim`.
- Numbers (prices, P&L, quantities): monospaced digits (`.monospacedDigit()`).
- Titles: 15–17 pt semibold, `bone`. One `ember` word allowed in a title.

## Shape & layout

- Corner radius 8 everywhere (6 for small chips). 1 px `line` borders on panels.
- Padding rhythm: 12/16/24. Dense but breathing — a trading terminal, not a toy.
- Buttons: ember fill, near-black text (`#141005`), 13 pt semibold uppercase,
  letter-spacing 0.06 em. Secondary buttons: panel fill, `line` border, bone text.
- Progress/status: 4 px bars, 2 px radius, ember on `line` track.
- Hover states: background shifts to `panelHi` or `emberTint`; 0.2 s ease
  `cubic-bezier(0.22, 1, 0.36, 1)`. No springs, no bounces.

## Charting

- Canvas `ink`, gridlines `line` at 40% alpha, axis labels `dim` 10 pt mono.
- Candles: `up`/`down` bodies, 1 px wicks same color; volume bars 25% alpha.
- Overlays: EMA lines in muted single hues (ember reserved for AI annotations),
  Bollinger band fill at 6% alpha.
- Crosshair: 1 px `dim` dashed; readout chip in `panel` with `line` border.
- AI annotations (signals, agent notes): ember markers + ember callout chips.

## Voice

Labels are terse and lowercase-calm ("positions", "risk", "agent feed").
Numbers carry the drama; the chrome stays quiet.
