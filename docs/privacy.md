# Privacy and local data policy

Wrenflow performs transcription locally. It has no analytics, advertising,
remote transcription or remote crash-reporting service. Audio, transcripts,
custom vocabulary and microphone identifiers are not uploaded by the app.

## Data stored on the Mac

Wrenflow stores current-format application data below the macOS user data
directories selected by the `dirs` crate:

- preferences and onboarding/model selection;
- `history.sqlite`, containing up to 50 recent transcripts, custom vocabulary
  snapshots, timestamps, recording filenames and local performance metadata;
- `recordings/`, containing OGG/Opus audio created during dictation;
- `models/`, containing optional, checksum-verified ONNX model assets.

History rows are capped at 50. Recording files and downloaded models currently
remain until the user explicitly deletes/reset them or uninstalls them with the
data-removal option; there is no time-based retention promise. “Clear history”
removes transcript rows but must not be represented as secure erasure of audio
until the associated recording deletion gate is implemented. Files deleted by
the app may remain in filesystem snapshots or backups controlled by macOS or
the user.

The custom vocabulary is stored locally in preferences and copied into local
history metadata for the relevant transcription. Clipboard contents belong to
the target application; Wrenflow uses the clipboard only for the paste flow and
does not transmit it.

## Network requests

An update check sends the normal IP/TLS/HTTP metadata and a generic Wrenflow
user agent to GitHub. A model download sends the same class of request metadata
to Hugging Face/CDN hosts. Requests contain no transcript, audio, vocabulary or
device identifier. Every model URL contains a checked-in immutable revision and
the received bytes are rejected unless their size and SHA-256 match.

Update checks are user-initiated and contain no persistent identifier. The
stable/beta feed is restricted to the Wrenflow GitHub repository. Wrenflow
accepts only the exact DMG asset whose GitHub-provided SHA-256, Developer ID,
notarization ticket, bundle/support identity and embedded supply-chain pins all
verify. Feed-provided URLs are not exposed as generic browser actions. See
[ADR 001](adr-001-gpui-updater.md).

## Diagnostics and permissions

Microphone permission is used only while recording. Accessibility permission is
used to paste the completed transcript. Global hotkey monitoring is listen-only.
No credential is stored by the application.

Release diagnostics must not contain transcript/audio content, vocabulary,
credentials, device identity or full user paths. Local logs and crash reports
use a closed schema, private filesystem permissions and bounded retention as
documented in [GPUI production diagnostics](gpui-diagnostics.md); users should
review any diagnostic bundle before sharing it. Diagnostic collection and
export are local-only and do not enable telemetry or remote crash upload.
The deterministic support bundle reads only the structured diagnostics export,
is capped at 3 MiB and includes no history, recording, model or settings file.
It is written only after the explicit Export action, as a private timestamped
file in Downloads; Wrenflow never uploads it.

For security reports, see [SECURITY.md](../SECURITY.md). For a complete reset,
see [GPUI production lifecycle](gpui-production-lifecycle.md).
