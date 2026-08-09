# macOS TCC Debugging

macOS TCC checks entitlements on the **responsible process**, not just the
requesting process. When Wrenflow's Mach-O is launched directly from a terminal,
the terminal can become responsible and does not carry Wrenflow's microphone
identity. The permission dialog may therefore never appear.

**Always launch via `mise run run`** (uses `open`, app is its own responsible process).

## Debug commands

```bash
# Live TCC log
/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC"'

# Check TCC database entries
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service,client,auth_value from access where client like '%wrenflow%';"

# System-level TCC (accessibility lives here)
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service,client,auth_value from access where client like '%wrenflow%';"

# Reset microphone permission for testing
tccutil reset Microphone me.gulya.wrenflow
```

## Key facts

- TCC identity = bundle ID + code signing requirement (csreq). Changing cert/team = new identity = reprompt.
- Ad-hoc signing: identity changes every build → grants don't persist.
- `AVCaptureDevice.requestAccess(for: .audio)` only shows dialog once. After denial, must open System Settings.
- Accessibility: no entitlement grants it — user must toggle in System Settings. Sandboxed apps cannot use Accessibility APIs.
- PPPC can deny-only for microphone, not pre-allow.
