/// What a family member's QR code carries: their account ID and account
/// fingerprint. Scanning it in person fills in the ID and, when the scanned
/// fingerprint matches the one the server returns for that account, proves
/// the comparison that would otherwise be read out loud.
final class FamilyInvite {
  const FamilyInvite({required this.accountId, required this.fingerprint});

  static const String _prefix = 'homebox://family?';

  final String accountId;
  final String fingerprint;

  String encode() => Uri(
    scheme: 'homebox',
    host: 'family',
    queryParameters: {'v': '1', 'account': accountId, 'fp': fingerprint},
  ).toString();

  /// The invite in [raw], or null when it is not a valid HomeBox family code
  /// (any other QR code, a newer version, or malformed values).
  static FamilyInvite? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(_prefix)) return null;
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    final params = uri.queryParameters;
    final accountId = params['account']?.toLowerCase();
    final fingerprint = params['fp'];
    if (params['v'] != '1' ||
        accountId == null ||
        fingerprint == null ||
        !_uuid.hasMatch(accountId) ||
        normalizeFingerprint(fingerprint).length != 64) {
      return null;
    }
    return FamilyInvite(accountId: accountId, fingerprint: fingerprint);
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// [fingerprint] reduced to lowercase hex digits, so differently grouped or
/// cased renderings of the same SHA-256 fingerprint compare equal.
String normalizeFingerprint(String fingerprint) =>
    fingerprint.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');

/// Whether two fingerprint renderings denote the same full SHA-256 value.
bool fingerprintsMatch(String a, String b) {
  final left = normalizeFingerprint(a);
  return left.length == 64 && left == normalizeFingerprint(b);
}
