# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Email
`ilya@gulya.me` with the subject `Wrenflow security`, affected version, impact,
reproduction steps and any proof of concept. Encrypt sensitive reports with a
key agreed over that channel before sending secrets or private recordings.

Receipt is normally acknowledged within 3 business days. A severity and
remediation plan is normally provided within 10 business days. Public
disclosure is coordinated after a signed fix is available. Please do not access
data that is not yours, disrupt services, or publish a report before the agreed
date.

Only the latest signed Wrenflow release is supported. Security fixes are not
backported to pre-GPUI or older GPUI releases.

## Release security boundary

Wrenflow is intentionally not App Sandbox confined: global hotkeys,
Accessibility-driven paste and the menu-bar shell require APIs unavailable to
the sandboxed design. Hardened Runtime, Developer ID signing, notarization,
Gatekeeper assessment and the narrow entitlements in
`native/wrenflow-gpui/macos/Wrenflow.entitlements` are mandatory compensating
controls.

Production network destinations are limited to:

- `api.github.com` and GitHub release asset hosts for update discovery;
- `huggingface.co` plus its content delivery redirects for exact-revision,
  SHA-256-verified model assets.

Downloaded code is never executed before its pinned checksum is verified.
Release CI is the only environment receiving Apple signing/notarization
credentials, and pull-request code cannot publish artifacts.
