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
                _localized(
                  context,
                  en: 'HomeBox locked',
                  ru: 'HomeBox заблокирован',
                ),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _localized(
                  context,
                  en: 'Use your enrolled biometric to access encrypted files.',
                  ru: 'Подтвердите личность биометрией, чтобы открыть зашифрованные файлы.',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: authenticating ? null : onUnlock,
                icon: const Icon(Icons.fingerprint),
                label: Text(
                  authenticating
                      ? _localized(context, en: 'Checking…', ru: 'Проверка…')
                      : _localized(context, en: 'Unlock', ru: 'Разблокировать'),
                ),
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
  const _VaultStateChip({required this.controller, this.onTap});

  final VaultSetupController controller;

  /// Opens the vault's settings.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final ready = controller.status == VaultSetupStatus.ready;
      return _headerStatusIndicator(
        icon: ready ? Icons.lock_open_outlined : Icons.lock_outline,
        label: ready
            ? _localized(
                context,
                en: 'Vault unlocked',
                ru: 'Хранилище разблокировано',
              )
            : _localized(
                context,
                en: 'Vault locked',
                ru: 'Хранилище заблокировано',
              ),
        tooltip: ready
            ? _localized(
                context,
                en: 'Vault unlocked on this device. Open Settings for devices and recovery.',
                ru: 'Хранилище разблокировано на этом устройстве. Устройства и восстановление — в настройках.',
              )
            : _localized(
                context,
                en: 'Create or restore this account\'s vault in Settings to unlock E2EE data.',
                ru: 'Создайте или восстановите хранилище аккаунта в настройках, чтобы открыть зашифрованные данные.',
              ),
        dense: true,
        onTap: onTap,
      );
    },
  );
}

/// A [Chip] mirroring [label] when [dense] is false (used in the roomy
/// desktop header), or a bare tooltipped icon when true (used in the
/// narrow/Android AppBar, where three side-by-side chips would overflow).
/// With [onTap] it becomes a button, so a status leads to where it can be
/// acted on — a tooltip alone is hard to reach on a touch screen.
Widget _headerStatusIndicator({
  required IconData icon,
  required String label,
  String? tooltip,
  Color? color,
  required bool dense,
  VoidCallback? onTap,
}) {
  final message = tooltip ?? label;
  if (dense) {
    if (onTap != null) {
      return IconButton(
        onPressed: onTap,
        tooltip: message,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 20, color: color),
      );
    }
    return Tooltip(
      message: message,
      child: Icon(icon, size: 20, color: color),
    );
  }
  if (onTap != null) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      tooltip: message,
      onPressed: onTap,
    );
  }
  return Tooltip(
    message: message,
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
    this.onTap,
  });

  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final bool dense;

  /// Opens the Sync page, where the status is explained in full.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    if (engine == null) {
      // Not "paused": nothing has been set up to sync yet. Matches the
      // Sync page's own label for this condition.
      return _headerStatusIndicator(
        icon: Icons.cloud_off_outlined,
        label: _syncNotSetUpLabel(context),
        tooltip: _syncNotSetUpHint(context),
        dense: dense,
        onTap: onTap,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([engine, ?syncFolderMaterializer]),
      builder: (context, _) {
        final (icon, label, color, tooltip) = _effectiveSyncStatusPresentation(
          context,
          engine: engine,
          materializer: syncFolderMaterializer,
        );
        return _headerStatusIndicator(
          icon: icon,
          label: label,
          tooltip: tooltip,
          color: color,
          dense: dense,
          onTap: onTap,
        );
      },
    );
  }
}

String _syncNotSetUpLabel(BuildContext context) => _localized(
  context,
  en: 'Sync not set up',
  ru: 'Синхронизация не настроена',
);

String _syncNotSetUpHint(BuildContext context) => _localized(
  context,
  en: 'Sync starts once this device is connected to a server and its vault is unlocked.',
  ru: 'Синхронизация начнётся, когда устройство подключится к серверу и хранилище будет разблокировано.',
);

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
          context,
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
            _localized(context, en: 'Downloading', ru: 'Скачивание'),
            materializer?.activeFileName ?? '',
            downloadProgress,
            Icons.arrow_downward,
          )
        : uploadProgress != null
        ? (
            _localized(context, en: 'Uploading', ru: 'Отправка'),
            uploader?.activeFileName ?? '',
            uploadProgress,
            Icons.arrow_upward,
          )
        : (
            _localized(context, en: 'Syncing', ru: 'Синхронизация'),
            '',
            0.0,
            Icons.sync,
          );
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
    required this.recoveryController,
    required this.onVaultProvisioned,
    required this.filesController,
    required this.familyVaultController,
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
    required this.themeController,
    required this.onPullToRefresh,
    required this.onRefresh,
    required this.onOpenSettings,
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
  final RecoveryController recoveryController;
  final Future<void> Function() onVaultProvisioned;
  final FilesController? filesController;
  final FamilyVaultController? familyVaultController;
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
  final AppThemeController themeController;
  final Future<void> Function()? onPullToRefresh;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenSettings;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(
      controller: filesController,
      familyVault: familyVaultController,
      onCapturePhoto: onCapturePhoto,
      androidFileSaver: androidFileSaver,
      androidFileSharer: androidFileSharer,
      syncFolder: syncFolder,
      androidSyncFolder: androidSyncFolder,
      onPullToRefresh: onPullToRefresh,
      onRefresh: onRefresh,
      onOpenSettings: onOpenSettings,
      onDownloadCompleted: onDownloadCompleted,
    ),
    AppSection.family => _FamilySection(
      controller: familyVaultController,
      androidFileSaver: androidFileSaver,
      onOpenSettings: onOpenSettings,
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
      onSyncNow: onRefresh,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      deviceProvisioningController: deviceProvisioningController,
      serverConnectionController: serverConnectionController,
      vaultSetupController: vaultSetupController,
      recoveryController: recoveryController,
      onVaultProvisioned: onVaultProvisioned,
      localeController: localeController,
      themeController: themeController,
    ),
  };
}

/// The server-side icon/label used as the baseline by
/// [_effectiveSyncStatusPresentation].
(IconData icon, String label) _syncStatusPresentation(
  BuildContext context,
  SyncStatus status,
) => switch (status) {
  SyncStatus.idle => (
    Icons.check_circle_outline,
    _localized(context, en: 'Up to date', ru: 'Синхронизировано'),
  ),
  SyncStatus.syncing => (
    Icons.sync,
    _localized(context, en: 'Syncing…', ru: 'Синхронизация…'),
  ),
  SyncStatus.paused => (
    Icons.pause_circle_outline,
    _localized(context, en: 'Sync paused', ru: 'Синхронизация на паузе'),
  ),
  SyncStatus.offline => (
    Icons.cloud_off_outlined,
    _localized(context, en: 'Offline', ru: 'Нет связи'),
  ),
  SyncStatus.error => (
    Icons.error_outline,
    _localized(context, en: 'Sync error', ru: 'Ошибка синхронизации'),
  ),
};

/// Resolves the status the user sees for the whole synchronization flow. A
/// completed server pull is not "up to date" while its changed files are
/// still being written into the selected local sync folder.
(IconData icon, String label, Color? color, String? tooltip)
_effectiveSyncStatusPresentation(
  BuildContext context, {
  required SyncEngine engine,
  SyncFolderMaterializer? materializer,
}) {
  final base = _syncStatusPresentation(context, engine.status);
  final error = Theme.of(context).colorScheme.error;
  return switch ((engine.status, materializer?.status)) {
    (SyncStatus.error, _) => (
      Icons.error_outline,
      base.$2,
      error,
      engine.errorMessage,
    ),
    (_, SyncFolderStatus.error) => (
      Icons.error_outline,
      _localized(
        context,
        en: 'Folder sync error',
        ru: 'Ошибка синхронизации папки',
      ),
      error,
      materializer?.errorMessage,
    ),
    (_, SyncFolderStatus.materializing) => (
      Icons.download_outlined,
      _localized(context, en: 'Writing files…', ru: 'Запись файлов…'),
      null,
      null,
    ),
    _ => (
      base.$1,
      base.$2,
      engine.status == SyncStatus.idle ? _successColor(context) : null,
      null,
    ),
  };
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
    this.subtitleWidget,
  });
  final String title;
  final String subtitle;

  /// Replaces the plain [subtitle] line, e.g. with clickable breadcrumbs.
  final Widget? subtitleWidget;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    // Phones cannot spare 32 logical pixels on every side.
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.all(compact ? 16 : 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 4),
          subtitleWidget ??
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          SizedBox(height: compact ? 16 : 24),
          Expanded(child: child),
        ],
      ),
    );
  }
}
