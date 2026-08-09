# Wrenflow product context

register: product

## Product purpose

Wrenflow is a local-first macOS menu bar dictation app. The core interaction is
deliberately small: hold the configured key, speak, release, then receive the
transcript at the current cursor. Transcription runs locally on the Mac.

## Users and context

- People who dictate into any macOS app and want the interaction to disappear
  into their existing workflow.
- Users who value on-device processing and a searchable local transcription
  history.
- The settings window is used briefly in ordinary desktop ambient light. The
  recording and transcription overlays are glanced at while another app remains
  the user's primary task.

## Product surfaces

- First-run onboarding and permission recovery.
- A single long-lived settings window with General, Models, History and About.
- Menu bar controls and native, non-activating recording/transcription/error
  overlays.

## Brand and tone

- Quiet, trustworthy and Mac-native.
- Concise and operational. Labels describe the action or current state without
  promotional copy.
- The wren icon and restrained green success/accent color are the identifying
  visual elements.

## Strategic principles

1. Dictation is the product. Configuration UI must remain secondary and fast to
   scan.
2. Preserve local-first trust. Runtime, model, permission and download states
   must be explicit.
3. Use familiar macOS interaction patterns, keyboard behavior and accessibility
   semantics.
4. The Flutter UI immediately before commit `7bdb8c5` is the visual source of
   truth for the light appearance. GPUI should match its geometry and component
   vocabulary before introducing any design change.
5. System dark appearance and accessibility adaptations extend the same visual
   roles. They are not a redesign.

## Anti-references

- Marketing-site styling inside the settings window.
- Decorative gradients, glass effects or attention-seeking motion.
- Dense dashboard chrome, nested cards or invented controls that feel unlike a
  macOS utility.
- Color-only status communication.

## Success criteria

- A returning Flutter user recognizes the same hierarchy, density, typography,
  spacing and control proportions in GPUI.
- Every product action remains reachable at the minimum supported window size,
  with keyboard and VoiceOver semantics intact.
- Appearance and accessibility changes apply live without changing the product's
  visual identity.
