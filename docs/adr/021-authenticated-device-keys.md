# ADR-021: Account-authenticated device keys

Status: accepted

## Context

TLS pinning authenticates the HomeBox server, but it does not make the server
an authority for end-to-end encryption keys. Before this decision, a trusted
client downloaded a new device's X25519 public key from the server and wrapped
the Vault Key for it. A fully malicious server could substitute its own
X25519 key at that point. The recipient-specific envelope would remain
well-formed while granting the wrong key access.

## Decision

Every vault-unlocked client derives the same Ed25519 Account Identity seed
from the 32-byte Vault Key with HKDF-SHA256. The account UUID is the HKDF salt
and `HBX-ACCOUNT-ID-V1` is the domain-separation context. The derived seed and
private signing key never leave client memory and are destroyed after use.

The Account Identity signs this canonical device statement:

```text
magic                 5 bytes  "HBXDS"
signature_version     2 bytes  unsigned big-endian, value 1
account_id            16 bytes UUID binary form
device_id             16 bytes UUID binary form
device_key_version     4 bytes unsigned big-endian
device_public_key     32 bytes X25519
```

During first pairing, the approving user must compare the full SHA-256
fingerprint displayed locally by the new device with the fingerprint shown by
the trusted device. Only after explicit confirmation does the trusted device
sign that X25519 key and create the provisioning envelope. This independent
comparison is the trust step that prevents a malicious server from replacing
an unsigned first-seen key. The same canonical pairing record can be encoded
as a `homebox://pair-device` QR payload by clients that provide a scanner.

Provisioning protocol v2 keeps the v1 envelope size and crypto primitives, but
adds the SHA-256 certificate binding to its HKDF context. Removing or replacing
the relayed certificate therefore derives a different wrapping key and fails
AEAD authentication. After unwrapping, the recipient independently derives
the Account Identity from the received Vault Key and verifies that the public
key and signature certify its own locally stored X25519 key.

The server validates signatures as defense in depth, rejects a different
Account Identity after the first certificate exists for an account, and stores
the certificate beside the opaque provisioning envelope. These server checks
improve consistency but are not part of the end-to-end trust boundary.

## Compatibility

- Existing device rows and protocol-v1 provisioning envelopes are unchanged.
- Certificate columns are nullable and are added by migration 8.
- New clients can open legacy v1 envelopes so an in-progress pairing survives
  a server/client rolling upgrade.
- New approvals always create v2 envelopes and device certificates.
- Old clients ignore the additional JSON fields and continue to use existing
  v1 envelopes. A target must update before receiving a newly created v2
  approval.

Legacy unsigned devices are not retroactively called authenticated. Once any
already trusted client approves them again or approves a new device, all
vault-unlocked clients derive the same Account Identity without requiring a
new stored secret.

## Consequences

- A password and a malicious server are insufficient to substitute a device
  E2EE key when the user performs the fingerprint comparison.
- Skipping or blindly confirming the out-of-band comparison defeats first-pair
  authentication; the UI therefore disables approval until it is confirmed.
- Account Identity changes if the Vault Key is rotated. A future Vault Key
  rotation protocol must cross-sign the replacement identity before rotation.
- Compromise of an unlocked trusted client exposes both its Vault Key and the
  derived signing capability, which is already inside that client's trust
  boundary.
