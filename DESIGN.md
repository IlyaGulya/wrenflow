# Wrenflow design system

This document records the visual contract of the final Flutter UI before the
GPUI replacement. The canonical source tree is `7bdb8c5^`. Numeric values below
come from `lib/theme/wrenflow_theme.dart`, `lib/screens/*.dart` and
`lib/widgets/*.dart` in that tree unless explicitly marked as a GPUI adaptation.

## Visual strategy

Product register, restrained color strategy. The light appearance is the
pixel-parity baseline. System dark appearance maps the same semantic roles to
dark surfaces while keeping geometry, type scale and control proportions
unchanged.

## Light color roles

| Role | Flutter source value | Hex equivalent | Use |
| --- | --- | --- | --- |
| Window background | rgb(245, 245, 245) | `#F5F5F5` | Settings content |
| Surface | rgb(252, 252, 252) | `#FCFCFC` | Cards, onboarding window |
| Primary text | rgb(38, 38, 38) | `#262626` | Titles, body, primary dark buttons |
| Secondary text | rgb(115, 115, 115) | `#737373` | Flutter caption reference |
| Tertiary text | rgb(153, 153, 153) | `#999999` | Flutter metadata reference |
| Border | rgba(0, 0, 0, 0.08) | `#00000014` | Cards and inputs |
| Success/accent | rgb(51, 179, 102) | `#33B366` | Enabled toggle, granted/healthy state |
| Danger | rgb(217, 64, 51) | `#D94033` | Errors and destructive actions |

Primary-text opacity roles are 5%, 6%, 7%, 10%, 15%, 50%, 60% and 70%.
Slider track roles are primary text at 8% and 35%. Green completion indicators
use green at 50%.

## Typography

- Family: system sans for product text; Menlo for version strings, metrics,
  hotkey values and compact machine-readable metadata.
- Standard body: 12 px in controls and cards; 13 px navigation; 14 px only for
  general body defaults.
- Section/page title: 16 px, weight 500.
- Card title: 13 px secondary text, placed 4 px from the card's left edge and
  6 px above it.
- Captions: 10 to 12 px depending on density. Primary captions are 11 px.
- Model row title: 12 px, weight 500.

## Geometry and rhythm

- Settings window baseline: 720 x 520 px.
- Onboarding baseline: 340 x 380 px; minimum 300 x 340 px.
- Settings sidebar: 150 px wide with a 0.5 px divider.
- Main settings content padding: 24 px.
- Gap between settings cards: 16 px.
- Settings card: 12 px internal padding, 8 px radius, 1 px border.
- Generic elevated card: 12 px radius, 0.5 px border, shadow 0 8 24 at black 8%.
- Small, medium and large radii: 5, 8 and 12 px.
- Sidebar item: 12 px outer horizontal margin, 1 px vertical margin, 10 x 6 px
  inner padding, 5 px radius, 6 px icon-to-label gap, 11 px icon.
- Sidebar brand: 28 px traffic-light inset, 64 px icon at 60% opacity, 8 px gap,
  12 px name, 2 px gap, 10 px Menlo version, 12 px gap.
- Onboarding step horizontal padding: 24 px. Step icon is a 40 px circle with
  a 17 px glyph. Icon-to-title gap is 10 px; title-to-subtitle 4 px;
  subtitle-to-control 14 px.
- Onboarding footer: 16 x 10 px padding. Buttons use 14 x 5 px padding and a
  6 px radius. Step dots are 5 px, current dot 6 px, with 5 px gaps.

## Components

### Toggle

36 x 20 px capsule, 16 px light thumb, 2 px horizontal inset. Enabled track is
green; disabled track is primary text at 15%. Flutter moved the thumb over
150 ms with an ease-in-out curve. Reduce Motion removes the interpolation but
not the state change.

### Settings card

The section label lives outside the outlined surface. The surface contains the
control content directly. Do not put a second title inside the surface and do
not nest another generic card around it.

### Buttons

Ordinary settings/onboarding actions use neutral, low-contrast surfaces with a
1 px border and 6 to 8 px radius. Solid dark buttons are reserved for the main
download/update action. Green communicates success and toggle state, not every
primary action.

### Text fields

Background is the window background role, 7 px radius, 1 px border. Compact
multiline vocabulary fields use Menlo 11 px and 8 px padding; heights are 48 px
in onboarding and 64 px in settings.

### Model rows

8 px radius and 1 px border, 12 px padding (10 px in compact onboarding), 8 px
bottom gap. Selected rows use primary text at 5% with a 15% border. A 15 px
selected/check indicator precedes the body by 10 px. Badges are compact neutral
capsules; status and action remain within the selected row.

### History rows

8 px radius, 1 px border and 12 px padding. The first line contains timestamp
metadata and metric badges; transcript follows after 4 px. Expanded diagnostics
use a background panel with 8 px padding and a 6 px radius.

## Screen contracts

- General: independent cards for push-to-talk, microphone when available,
  launch at login when available, sound effects, minimum duration and custom
  vocabulary.
- Models: summary card, 16 px gap, then Choose model card with model rows.
- History: 24 px top/header padding in settings, compact Clear action at the
  trailing edge, 24 px horizontal row padding and 6 px row gaps.
- About: 20 px top breathing room, 64 px icon at 60% opacity, 12 px gap, 16 px
  product name, 10 px Menlo version, 12 px tagline, then update/runtime cards.
- Onboarding: one centered step at a time, footer navigation and six progress
  dots. Permission, hotkey, model, vocabulary and test states retain their
  dedicated control geometry.

## Adaptive and accessibility contract

- Minimum settings width preserves every action. Below the sidebar breakpoint,
  navigation becomes a compact horizontal region and content scrolls vertically.
- Text scaling must not clip or make actions unreachable at simulated 125%,
  150% and 200% scale. Layout grows or wraps rather than shrinking interactive
  targets.
- Focus rings and keyboard activation may add visible pixels beyond the Flutter
  baseline. They are required adaptations, not parity defects.
- Increase Contrast strengthens semantic borders/text; Differentiate Without
  Color adds explicit symbols or labels; Reduce Transparency uses opaque
  surfaces; Reduce Motion removes nonessential interpolation.
- Dark appearance preserves all geometry and semantic emphasis. It does not use
  pure black or pure white.

## Visual acceptance

- Baseline viewport and state screenshots should align within 2 px for primary
  geometry and within 1 px for component dimensions.
- Text baselines should align within 2 px. Font rasterization differences are
  excluded from pixel-count thresholds but not from size, weight or line-height
  review.
- The unsafe Flutter RGB values remain reference-only. The GPUI default uses
  `#707070` for both historical gray text roles and `#30A65F` for the green
  control role. These are the minimum measured shifts needed for 4.5:1 text and
  3:1 non-text contrast on the original surfaces.
- No control may be hidden, clipped or unreachable at the supported adaptive
  widths and text scales.
