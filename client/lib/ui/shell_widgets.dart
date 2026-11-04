part of '../main.dart';

/// An overlay rather than a [SnackBar] queue, so separate completed
/// downloads remain visible together and each can be dismissed on its own.
final class _DownloadNotificationStack extends StatelessWidget {
  const _DownloadNotificationStack({required this.controller});

  final DownloadNotificationController controller;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final notifications = controller.notifications;
        if (notifications.isEmpty) return const SizedBox.shrink();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: notifications
                      .map(
                        (notification) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _DownloadCompletionCard(
                            notification: notification,
                            onDismiss: () =>
                                controller.dismiss(notification.id),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

final class _DownloadCompletionCard extends StatelessWidget {
  const _DownloadCompletionCard({
    required this.notification,
    required this.onDismiss,
  });

  final DownloadCompletionNotification notification;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final completedLabel = _localized(
      context,
      en: 'Download complete',
      ru: 'Загрузка завершена',
    );
    final savedToLabel = _localized(context, en: 'Saved to', ru: 'Сохранено в');
    final dismissLabel = _localized(
      context,
      en: 'Dismiss download notification',
      ru: 'Закрыть уведомление о загрузке',
    );
    return Semantics(
      container: true,
      label:
          '$completedLabel: ${notification.fileName}. '
          '$savedToLabel ${notification.location}.',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              const Icon(Icons.download_done_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(completedLabel, style: textTheme.titleSmall),
                    Text(
                      notification.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
                    Text(
                      '$savedToLabel ${notification.location}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
                tooltip: dismissLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _BiometricGateLoadingScreen extends StatelessWidget {
  const _BiometricGateLoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

final class _BiometricLockScreen extends StatelessWidget {
  const _BiometricLockScreen({
    required this.authenticating,
    required this.onUnlock,
  });

  final bool authenticating;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fingerprint, size: 72),
              const SizedBox(height: 20),
              Text(
                'HomeBox locked',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Use your enrolled biometric to access encrypted files.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: authenticating ? null : onUnlock,
                icon: const Icon(Icons.fingerprint),
                label: Text(authenticating ? 'Checking…' : 'Unlock'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Icon-only (no "locked"/"unlocked" text pill): the open/closed lock shape
/// already conveys the state, and the header has several of these status
/// indicators competing for space. The fuller explanation of what "locked"
/// means here still lives in Settings, next to vault setup itself.
class _VaultStateChip extends StatelessWidget {
  const _VaultStateChip({required this.controller});

  final VaultSetupController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final ready = controller.status == VaultSetupStatus.ready;
      return _headerStatusIndicator(
        icon: ready ? Icons.lock_open_outlined : Icons.lock_outline,
        label: ready ? 'Vault unlocked' : 'Vault locked',
        tooltip: ready
            ? 'This vault was created on this device. A trusted device or Recovery Secret is required on any other device.'
            : 'Create or restore this account\'s vault in Settings to unlock E2EE data.',
        dense: true,
      );
    },
  );
}

/// A [Chip] mirroring [label] when [dense] is false (used in the roomy
/// desktop header), or a bare tooltipped icon when true (used in the
/// narrow/Android AppBar, where three side-by-side chips would overflow).
Widget _headerStatusIndicator({
  required IconData icon,
  required String label,
  String? tooltip,
  Color? color,
  required bool dense,
}) {
  if (dense) {
    return Tooltip(
      message: tooltip ?? label,
      child: Icon(icon, size: 20, color: color),
    );
  }
  return Tooltip(
    message: tooltip ?? label,
    child: Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
    ),
  );
}

/// Duplicates the Sync page's status (spec: offline/up to date/syncing/…)
/// in the header, so it is visible from any section without switching tabs.
class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({
    required this.syncEngine,
    required this.syncFolderMaterializer,
    this.dense = false,
  });

  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    if (engine == null) {
      // Matches the label the Sync page itself shows for this same
      // condition (no engine yet — vault locked/not provisioned).
      return _headerStatusIndicator(
        icon: Icons.pause_circle_outline,
        label: 'Sync paused',
        dense: dense,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([engine, ?syncFolderMaterializer]),
      builder: (context, _) {
        final (icon, label, color, tooltip) = _effectiveSyncStatusPresentation(
          engine: engine,
          materializer: syncFolderMaterializer,
        );
        return _headerStatusIndicator(
          icon: icon,
          label: label,
          tooltip: tooltip,
          color: color,
          dense: dense,
        );
      },
    );
  }
}

/// The header counterpart of the Files page's upload/download percentage —
/// visible from any section, not just while Files is open. Renders nothing
/// while no transfer is in progress.
class _TransferProgressIndicator extends StatelessWidget {
  const _TransferProgressIndicator({
    required this.filesController,
    this.dense = false,
  });

  final FilesController? filesController;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final controller = filesController;
    if (controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.busy) return const SizedBox.shrink();
        final percent = _transferProgressPercent(controller);
        final queued = controller.queuedTransfers;
        final progressLabel = _transferProgressLabel(
          controller.transferDirection,
          percent,
        );
        final label = queued == 0
            ? progressLabel
            : '$progressLabel · ${_localized(context, en: '$queued queued', ru: 'в очереди: $queued')}';
        // An arrow (direction) plus the percent itself, rather than a bare
        // spinner: a spinner alone doesn't say whether HomeBox is sending
        // or receiving, or how far along it is, at a glance in the header.
        final directionIcon = switch (controller.transferDirection) {
          FileTransferDirection.upload => Icons.arrow_upward,
          FileTransferDirection.download => Icons.arrow_downward,
          null => Icons.sync,
        };
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(directionIcon, size: dense ? 18 : 16),
            const SizedBox(width: 2),
            Text('$percent%'),
          ],
        );
        if (dense) return Tooltip(message: label, child: content);
        return Tooltip(
          message: label,
          child: Chip(
            avatar: Icon(directionIcon, size: 18),
            label: Text('$percent%'),
          ),
        );
      },
    );
  }
}

/// Compact local-folder transfer progress for the global header. Its parent
/// listens to both sources and creates this widget only while a file is
/// actually moving, so the idle header stays compact.
class _SyncFolderTransferProgressIndicator extends StatelessWidget {
  const _SyncFolderTransferProgressIndicator({
    required this.materializer,
    required this.uploader,
    this.dense = false,
  });

  final SyncFolderMaterializer? materializer;
  final LocalFolderUploader? uploader;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final downloadProgress = materializer?.transferProgress;
    final uploadProgress = uploader?.transferProgress;
    final (direction, fileName, progress, icon) = downloadProgress != null
        ? (
            'Downloading',
            materializer?.activeFileName ?? 'file',
            downloadProgress,
            Icons.arrow_downward,
          )
        : uploadProgress != null
        ? (
            'Uploading',
            uploader?.activeFileName ?? 'file',
            uploadProgress,
            Icons.arrow_upward,
          )
        : ('Syncing', 'file', 0.0, Icons.sync);
    final percent = (progress * 100).round().clamp(0, 100);
    final tooltip = '$direction $fileName — $percent%';
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: dense ? 18 : 20,
          child: CircularProgressIndicator(strokeWidth: 2, value: progress),
        ),
        const SizedBox(width: 4),
        Icon(icon, size: dense ? 16 : 18),
        const SizedBox(width: 2),
        Text('$percent%'),
      ],
    );
    if (dense) return Tooltip(message: tooltip, child: content);
    return Tooltip(
      message: tooltip,
      child: Chip(avatar: Icon(icon, size: 18), label: Text('$percent%')),
    );
  }
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({
    required this.section,
    required this.syncFolder,
    required this.selectingFolder,
    required this.onSelectSyncFolder,
    required this.onOpenSyncFolder,
    required this.deviceSetupController,
    required this.deviceProvisioningController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
    required this.filesController,
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
    required this.onToggleSyncPause,
    required this.onResyncVault,
    required this.resyncingVault,
    required this.onCapturePhoto,
    required this.androidFileSaver,
    required this.androidFileSharer,
    required this.androidSyncFolder,
    required this.localeController,
    required this.onPullToRefresh,
    required this.onDownloadCompleted,
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;
  final Future<void> Function()? onOpenSyncFolder;
  final DeviceSetupController deviceSetupController;
  final DeviceProvisioningController deviceProvisioningController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;
  final FilesController? filesController;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;
  final VoidCallback onToggleSyncPause;
  final Future<void> Function() onResyncVault;
  final bool resyncingVault;
  final Future<void> Function()? onCapturePhoto;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final AndroidSyncFolder? androidSyncFolder;
  final AppLocaleController localeController;
  final Future<void> Function()? onPullToRefresh;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(
      controller: filesController,
      onCapturePhoto: onCapturePhoto,
      androidFileSaver: androidFileSaver,
      androidFileSharer: androidFileSharer,
      syncFolder: syncFolder,
      androidSyncFolder: androidSyncFolder,
      onPullToRefresh: onPullToRefresh,
      onDownloadCompleted: onDownloadCompleted,
    ),
    AppSection.sync => _SyncSection(
      syncFolder: syncFolder,
      onSelectSyncFolder: onSelectSyncFolder,
      onOpenSyncFolder: onOpenSyncFolder,
      syncEngine: syncEngine,
      syncFolderMaterializer: syncFolderMaterializer,
      localFolderUploader: localFolderUploader,
      syncFolderWatcher: syncFolderWatcher,
      onToggleSyncPause: onToggleSyncPause,
      onResyncVault: onResyncVault,
      resyncingVault: resyncingVault,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      deviceProvisioningController: deviceProvisioningController,
      serverConnectionController: serverConnectionController,
      vaultSetupController: vaultSetupController,
      onVaultProvisioned: onVaultProvisioned,
      localeController: localeController,
    ),
  };
}

/// The server-side icon/label used as the baseline by
/// [_effectiveSyncStatusPresentation].
(IconData icon, String label) _syncStatusPresentation(SyncStatus status) =>
    switch (status) {
      SyncStatus.idle => (Icons.check_circle_outline, 'Up to date'),
      SyncStatus.syncing => (Icons.sync, 'Syncing…'),
      SyncStatus.paused => (Icons.pause_circle_outline, 'Sync paused'),
      SyncStatus.offline => (Icons.cloud_off_outlined, 'Offline'),
      SyncStatus.error => (Icons.error_outline, 'Sync error'),
    };

/// Resolves the status the user sees for the whole synchronization flow. A
/// completed server pull is not "up to date" while its changed files are
/// still being written into the selected local sync folder.
(IconData icon, String label, Color? color, String? tooltip)
_effectiveSyncStatusPresentation({
  required SyncEngine engine,
  SyncFolderMaterializer? materializer,
}) {
  final base = _syncStatusPresentation(engine.status);
  return switch ((engine.status, materializer?.status)) {
    (SyncStatus.error, _) => (
      Icons.error_outline,
      'Sync error',
      Colors.red,
      engine.errorMessage,
    ),
    (_, SyncFolderStatus.error) => (
      Icons.error_outline,
      'Folder sync error',
      Colors.red,
      materializer?.errorMessage,
    ),
    (_, SyncFolderStatus.materializing) => (
      Icons.download_outlined,
      'Writing files…',
      null,
      null,
    ),
    _ => (
      base.$1,
      base.$2,
      engine.status == SyncStatus.idle ? Colors.green : null,
      null,
    ),
  };
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 24),
        Expanded(child: child),
      ],
    ),
  );
}
