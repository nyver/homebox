import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/core/platform/windows_tray.dart';

void main() {
  test('each new reason for attention is reported once', () {
    final tracker = AttentionTracker();
    expect(
      tracker.update(
        openConflicts: 0,
        unseenFailedTransfers: 0,
        syncError: false,
      ),
      isEmpty,
    );

    expect(
      tracker.update(
        openConflicts: 2,
        unseenFailedTransfers: 1,
        syncError: true,
      ),
      {
        AttentionKind.syncConflict,
        AttentionKind.failedTransfer,
        AttentionKind.syncError,
      },
    );

    // Nothing new: the same state, or fewer items after the user looked.
    expect(
      tracker.update(
        openConflicts: 2,
        unseenFailedTransfers: 1,
        syncError: true,
      ),
      isEmpty,
    );
    expect(
      tracker.update(
        openConflicts: 1,
        unseenFailedTransfers: 0,
        syncError: false,
      ),
      isEmpty,
    );

    // A later conflict or a new error episode is reported again.
    expect(
      tracker.update(
        openConflicts: 2,
        unseenFailedTransfers: 0,
        syncError: true,
      ),
      {AttentionKind.syncConflict, AttentionKind.syncError},
    );
  });
}
