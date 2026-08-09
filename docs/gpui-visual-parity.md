# GPUI visual parity evidence

The production GPUI shell is compared against the Flutter source at
`7bdb8c5^`. The evidence set is intentionally small and reproducible: General,
Models, empty History and About, each at the Flutter 720×520 Settings window
size. `visual-parity.swift` ignores the shared 31-pixel macOS title bar and
compares every remaining RGB pixel.

The persisted, sanitized captures live under `build/visual-parity/`:

- `flutter-{general,models,history,about}.png` — reference application;
- `gpui-{general,models,history,about}.png` — exact signed GPUI bundle;
- `{screen}-overlay.png`, `{screen}-diff-4x.png` and
  `{screen}-metrics.json` — review and machine evidence.

History was captured from an empty current-format database (zero rows); no
transcription or personal data is present. The GPUI candidate was launched by
LaunchServices from `build/gpui/Wrenflow.app`, not by executing its Mach-O.

## Measured baseline

| Screen | Changed pixels | Mean absolute error | v1 ceiling |
| --- | ---: | ---: | ---: |
| General | 8.8571% | 0.02528 | 9.0% / 0.026 |
| Models | 15.4948% | 0.03856 | 15.7% / 0.040 |
| History | 5.1483% | 0.01006 | 5.3% / 0.011 |
| About | 11.9189% | 0.03082 | 12.1% / 0.032 |

The ceilings in `support/visual-parity/thresholds-v1.json` leave less than
0.25 percentage points of changed-pixel headroom and less than 0.0015 MAE.
They are regression limits, not a claim that the renderers produce identical
rasters.

The remaining reviewed differences are bounded and intentional:

- CoreText/GPUI and Flutter use different glyph and SVG rasterization;
- the GPUI primary action uses the native high-contrast control treatment;
- the local `System / Light / Dark` selector is an approved production footer;
- About exposes current-line update/support actions without restoring the old
  URL or legacy-migration behavior.

Models retains the Flutter hierarchy and geometry: the picker frame has the
same inset, model title/body/badge/action baselines align, the runtime badge is
title-trailing, and the selected/default badges preserve source order. About
keeps diagnostics/recovery detail collapsed from its default Flutter-shaped
brand and update hierarchy.

## Appearance, scale and accessibility

Light reference captures use only Wrenflow's persisted app-local selector.
The selector was restored to `system` after capture. The host remained on
automatic appearance (`AppleInterfaceStyleSwitchesAutomatically = 1`; the
effective style at evidence time was Dark). No macOS appearance or
accessibility System Setting was changed.

System high contrast, reduced transparency, reduced motion and differentiate
without color are exercised through the native injected-preference self-test.
Production text scale enters the render path at 100%, 125%, 150% and 200%; the
adaptive-layout tests use that same path. The signed accessibility bridge
publishes window, navigation, heading, modal dialog and adjustable slider
semantics, including recurring announcement occurrences.

## Reproduce

```sh
mise run build
mise run run
mise exec -- swift native/wrenflow-gpui/scripts/visual-parity.swift \
  build/visual-parity/flutter-general.png \
  build/visual-parity/gpui-general.png \
  build/visual-parity/general --crop-top 31
mise run visual-parity-verify
```

Repeat the comparison command for Models, History and About. Route changes and
theme changes are performed through the typed accessibility/UI boundary; a
second render-boundary refresh ensures that the accessibility tree and the
presented GPUI frame advance together.
