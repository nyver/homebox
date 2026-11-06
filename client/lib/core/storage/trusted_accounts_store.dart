import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Account identities of family members the user verified by comparing
/// fingerprints out of band (ADR-023). A pinned identity lets this device
/// trust that member's certified devices, and their signed share envelopes,
/// without asking again; a different identity later is treated as a
/// possible server attack, never silently accepted.
final class TrustedAccountsStore {
  TrustedAccountsStore(this._db);

  final Database _db;

  Uint8List? identityOf(String accountId) {
    final rows = _db.select(
      'SELECT identity_public_key FROM trusted_accounts WHERE account_id = ?',
      [accountId],
    );
    if (rows.isEmpty) return null;
    return rows.first['identity_public_key'] as Uint8List;
  }

  void pin(String accountId, List<int> identityPublicKey) {
    _db.execute(
      '''
      INSERT INTO trusted_accounts (account_id, identity_public_key, verified_at) VALUES (?, ?, ?)
      ON CONFLICT(account_id) DO UPDATE SET
        identity_public_key = excluded.identity_public_key,
        verified_at = excluded.verified_at
      ''',
      [
        accountId,
        Uint8List.fromList(identityPublicKey),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  void forget(String accountId) {
    _db.execute('DELETE FROM trusted_accounts WHERE account_id = ?', [
      accountId,
    ]);
  }
}
