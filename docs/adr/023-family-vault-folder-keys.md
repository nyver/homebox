# ADR-023: Family Vault Folder Keys, Shared Writes, and Key Rotation

Status: accepted

## Context

Spec §28 asks for folders shared between family accounts with `READ` and `READ_WRITE` permissions, with a key rotation after a member is removed. Until now every node's metadata and every File DEK were encrypted with the owner's personal Vault Key. Handing that key to a family member would expose the owner's whole vault, so a shared folder needs a key of its own.

## Decision

### Key scopes

Every node's metadata and every File DEK belong to exactly one **key scope**:

- the owner's account ID, meaning the owner's personal Vault Key; or
- the ID of a **shared folder**, meaning that folder's random 256-bit Folder Key.

The scope is part of the AEAD context of every envelope (ADR-011, ADR-015), so ciphertext can never be decrypted in another scope. The server records the declared scope as a routing hint only: `nodes.metadata_key_scope_id` (NULL means the owner's Vault) and the existing `file_versions.key_scope_id`. A node's metadata and all of its versions always share one scope.

Shared folders never nest: the server refuses a first folder key for a folder inside, or containing, another shared folder, and refuses a move that would nest two of them. Every node therefore has a single nearest shared folder.

### Folder keys

- Each version of a Folder Key is generated on the owner's client and stored on the server wrapped by the owner's Vault Key (`folder_keys`, purpose `folderKey`, AEAD context: folder, owner, version), so every trusted owner device can open it and the server cannot.
- New content placed below a shared folder is encrypted with the newest version of that folder's key. A rename or a new version of an existing node stays in the node's current scope.
- When a folder is first shared, and whenever content is later moved or uploaded into it with the personal Vault Key, the owner's client **rekeys** it: it re-encrypts the node's metadata and rewraps every File DEK under the folder key (`POST /api/v1/nodes/rekey`). Ciphertext blobs never change. The reconciliation runs after every sync pass, skips nodes with queued local changes, and retries a batch that lost a revision race on the next pass.
- A Folder Key is kept after its folder is purged from Trash for as long as any surviving node or file version is still encrypted with it.

### Delivering keys to members

- The owner adds a member by the member's account ID. The client accepts only devices whose X25519 key is certified by the member's Ed25519 Account Identity (ADR-021), and the user must first compare that identity's fingerprint with the member out of band. The verified identity is pinned on the owner's device; a different identity later is refused.
- Every key version is encrypted for every certified member device with the existing per-device envelope (`FamilyShareKeyCipher`: ephemeral X25519 + HKDF + XChaCha20-Poly1305, bound to folder, owner, member, device, and version).
- Each envelope is signed by the owner's Account Identity over the folder, both accounts, the device, the version, and the envelope's SHA-256. The member compares the owner's fingerprint once, pins it, and opens only envelopes with a valid signature from that pinned identity, so the server cannot plant a folder key of its own.
- Devices the member approves later receive envelopes automatically the next time an owner device that pinned the member refreshes its shares.

### Permissions

- `READ`: browse and download below the shared folder.
- `READ_WRITE`: also create, rename, move (within the shared folder), replace, and delete below it. The shared folder itself stays under the owner's control. Content a member adds is stored under the owner's account, appears in the owner's sync feed and Trash, and must be encrypted with the shared folder's key; the server rejects the member's personal scope or the owner's Vault scope.

### Removing a member

Revoking a share ends the member's server access immediately. The owner's client then creates the next Folder Key version and delivers it to the remaining members' certified devices. Content added from then on uses the new version. Content the removed member could read before cannot be taken back (spec §28.3, Risk 1C).

## Consequences

- The server stores more opaque routing data (key scope per node, folder-key envelopes, envelope signatures) but still never holds a key that decrypts content.
- Sharing an existing folder costs one metadata re-encryption and one DEK rewrap per node and version on the owner's device, plus one version-list request per file.
- Members browse shared folders online; shared content is not mirrored into a member's local sync folder.
- Older clients cannot read content encrypted with a folder key; every device of an account that shares folders needs this version.
- A local Resync moves all of the owner's roots, including shared folders, to Trash and uploads a fresh tree, which ends those shares.
