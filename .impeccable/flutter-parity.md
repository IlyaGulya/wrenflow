# Flutter to GPUI parity baseline

## Provenance

- Source tree: `7bdb8c5^` (`git show 7bdb8c5^:<path>`).
- Source theme: `lib/theme/wrenflow_theme.dart`.
- Source screens: `lib/screens/settings_screen.dart`,
  `lib/screens/setup_wizard_screen.dart`, `lib/screens/history_screen.dart`.
- Source components: `lib/widgets/green_toggle.dart`,
  `lib/widgets/settings_card.dart`, `lib/widgets/local_model_picker.dart` and
  `lib/widgets/hotkey_capture.dart`.
- GPUI implementation under review: `native/wrenflow-gpui/src/ui/` and
  `native/wrenflow-gpui/src/screens/`.

## Scan result

The initial GPUI theme is not a faithful visual port. Its light background,
surface, foreground and accent roles differ from Flutter; its sidebar is 220 px
instead of 150 px; cards place 20 px titles inside 16 px padded surfaces instead
of 13 px captions outside 12 px padded surfaces; and controls use a 2 px border
and 32 to 36 px minimum height where the Flutter source generally uses 1 px
borders and compact 12 px labels. These are design-system deltas, so parity work
must begin in shared tokens/components rather than one-off screen offsets.

## Measurement matrix

| Surface | Canonical state | Baseline viewport |
| --- | --- | --- |
| Onboarding | Microphone unknown/denied | 340 x 380 |
| Onboarding | Hotkey | 340 x 380 |
| Onboarding | Model available/selected | 340 x 380 |
| Onboarding | Vocabulary | 340 x 380 |
| Onboarding | Complete/idle | 340 x 380 |
| Settings | General, complete snapshot | 720 x 520 |
| Settings | Models, selected model | 720 x 520 |
| Settings | History with rows and empty | 720 x 520 |
| Settings | About | 720 x 520 |

## Diff policy

Capture matched states at 1x logical scale. Store raw reference and candidate
images separately, then produce 50% alpha overlays and absolute-difference
images. Measurements use window-content coordinates and exclude macOS title-bar
traffic lights. Primary geometry must be within 2 px, component sizes within
1 px and text baselines within 2 px. Accessibility focus rings, system glyph
rasterization and font antialiasing are annotated exclusions.

If a historical Flutter binary cannot be launched safely, source-derived
render-plan fixtures are the authoritative baseline. A blocked historical launch
does not permit guessed values.
