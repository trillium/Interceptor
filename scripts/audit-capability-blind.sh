#!/usr/bin/env bash
# Capability-blind audit gate.
#
# Fails (exit 1) if the tracked tree carries any relocated hardened-target
# managed-copy specifics, if the shipped skills describe a relocated capability,
# or if the core network-fetches an extension. Run by CI and locally:
#
#   bash scripts/audit-capability-blind.sh
#
# Covers the full rung-4 token set across the bridge + agent + cli/ surface.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { printf 'audit: %s\n' "$*"; }

# 1) Relocated rung-4 (hardened-target managed-copy) specifics must be absent
#    from the tracked core (bridge + agent + cli + shared).
PATTERN='resignAndLaunch|--catch-launch|--capability-continuity|REPLAYED|capabilityContinuity|catchLaunch|preservePlugins|dumpEntitlements|restorePlugins|stripContainerQuarantine|nativeSigningIdentity|INTERCEPTOR_ENTITLEMENT_CONTINUITY|INTERCEPTOR_CATCH_LAUNCH_EXC|INTERCEPTOR_ENTITLEMENTS_PLIST|managed copy re-sign'
if rg -n "$PATTERN" interceptor-bridge/Sources interceptor-agent/Sources cli shared -S 2>/dev/null; then
  note "FAIL: relocated hardened-target managed-copy specifics found in the tracked core (see above)"
  fail=1
else
  note "ok: tracked core carries no relocated managed-copy specifics"
fi

# 2) Shipped skills carry only a neutral extension pointer — no capability
#    specifics.
if rg -n "re-sign|entitlement continuity|capability continuity|managed copy|managed-copy" .agents/skills -S 2>/dev/null; then
  note "FAIL: shipped skills describe relocated capability specifics (see above)"
  fail=1
else
  note "ok: shipped skills carry only a neutral extension pointer"
fi

# 3) The core never network-fetches an extension — discovery is filesystem-only.
if rg -n 'fetch\(|https?://|curl|download' cli daemon shared --glob '!**/*.test.ts' -S 2>/dev/null | rg -i 'extension' 2>/dev/null; then
  note "FAIL: extension-related network fetch found in the core (see above)"
  fail=1
else
  note "ok: no network fetch of extensions in the core"
fi

# 4) The iOS surface must embed NO Apple signing material.
#    Signing is delegated at RUNTIME to whatever identity is supplied then: on
#    operator machines, the operator's externally-configured Xcode/team; under
#    self-service, the END USER's own Apple-ID cert/profile created at
#    `interceptor ios setup` (daemon/ios/signer.ts drives `/usr/bin/codesign -s
#    <id> --entitlements`, never an xcodebuild build-setting). Either way the
#    shipped core bakes in nothing. Forbid baked-in identities / profiles / teams.
#    Note: `-allowProvisioningUpdates` is a delegation FLAG (no material) and is
#    allowed; a hardcoded `DEVELOPMENT_TEAM=<value>` / `CODE_SIGN_IDENTITY=` is not.
IOS_SIGN_PATTERN='iosSigningIdentity|wdaSigningIdentity|PROVISIONING_PROFILE=|CODE_SIGN_IDENTITY=|DEVELOPMENT_TEAM=[A-Za-z0-9]'
if rg -n "$IOS_SIGN_PATTERN" cli shared daemon interceptor-bridge/Sources --glob '!**/*.test.ts' -S 2>/dev/null; then
  note "FAIL: embedded iOS signing material found in the core (see above) — delegate signing to the operator's toolchain"
  fail=1
else
  note "ok: iOS surface embeds no signing material (delegated to operator toolchain)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "CAPABILITY-BLIND AUDIT FAILED"
  exit 1
fi
echo "CAPABILITY-BLIND AUDIT PASSED"
