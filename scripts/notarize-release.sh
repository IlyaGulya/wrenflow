#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "Usage: $0 <signed-dmg>" >&2
    exit 64
fi

for variable in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!variable:-}" ]]; then
        echo "Notarization requires $variable" >&2
        exit 65
    fi
done

RESULT_PATH="${DMG_PATH}.notary-result.json"
if ! xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait \
    --timeout 900 \
    --output-format json >"$RESULT_PATH"; then
    echo "Apple notary submission failed:" >&2
    cat "$RESULT_PATH" >&2
    exit 66
fi

STATUS="$(plutil -extract status raw -o - "$RESULT_PATH" 2>/dev/null || true)"
SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT_PATH" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Apple notary submission ${SUBMISSION_ID:-unknown} was not accepted (status: ${STATUS:-unknown})" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" >&2 || true
    fi
    exit 67
fi

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
echo "Accepted and stapled notarization submission $SUBMISSION_ID"
