import 'package:flutter/foundation.dart';

import '../../core/e2ee/opaque_id.dart';
import '../../core/storage/sync_conflicts_store.dart';

/// The observable list of sync conflicts this device resolved (spec §21:
/// "показать конфликт"). Every component that resolves a conflict records it
/// here; the Sync page lists the open ones until the user dismisses them.
///
/// Kept separate from [SyncEngine]'s own notifications on purpose: the app
/// starts a sync-folder pass whenever the engine notifies while idle, so a
/// conflict recorded during such a pass must not schedule another one.
final class SyncConflictLog extends ChangeNotifier {
  SyncConflictLog(this._store);

  final SyncConflictsStore _store;
  bool _disposed = false;

  List<SyncConflict> get open => _store.listOpen();
  int get openCount => _store.countOpen();

  /// Records a resolved conflict and returns it.
  SyncConflict record({
    required SyncConflictKind kind,
    String? nodeId,
    String? fileName,
    String? conflictCopyPath,
    DateTime? detectedAt,
  }) {
    final conflict = SyncConflict(
      id: generateUuidV4(),
      kind: kind,
      detectedAt: (detectedAt ?? DateTime.now()).toUtc(),
      nodeId: nodeId,
      fileName: fileName,
      conflictCopyPath: conflictCopyPath,
    );
    _store.record(conflict);
    _notify();
    return conflict;
  }

  /// The conflict whose preserved copy at [relativePath] has not been
  /// uploaded yet, so the uploader can attach its encrypted details.
  SyncConflict? copyAwaitingUpload(String relativePath) =>
      _store.copyAwaitingUpload(relativePath);

  void markCopyUploaded(String conflictId, String copyNodeId) =>
      _store.markCopyUploaded(conflictId, copyNodeId);

  void dismiss(String conflictId) {
    _store.dismiss(conflictId);
    _notify();
  }

  void dismissAll() {
    _store.dismissAll();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
