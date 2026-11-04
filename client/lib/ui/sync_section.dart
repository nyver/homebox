part of '../main.dart';

class _SyncSection extends StatelessWidget {
  const _SyncSection({
    required this.syncFolder,
    required this.onSelectSyncFolder,
    required this.onOpenSyncFolder,
    required this.syncEngine,
    required this.syncFolderMaterializer,
    required this.localFolderUploader,
    required this.syncFolderWatcher,
    required this.onToggleSyncPause,
    required this.onResyncVault,
    required this.resyncingVault,
  });
  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;
  final Future<void> Function()? onOpenSyncFolder;
  final SyncEngine? syncEngine;
  final SyncFolderMaterializer? syncFolderMaterializer;
  final LocalFolderUploader? localFolderUploader;
  final SyncFolderWatcher syncFolderWatcher;
  final VoidCallback onToggleSyncPause;
  final Future<void> Function() onResyncVault;
  final bool resyncingVault;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    return _PageFrame(
      title: _localized(context, en: 'Sync', ru: 'Синхронизация'),
      subtitle: engine == null
          ? _localized(
              context,
              en: 'Sync is paused while the E2EE vault is locked.',
              ru: 'Синхронизация приостановлена, пока E2EE-хранилище заблокировано.',
            )
          : _localized(
              context,
              en: 'The local cache and outbox sync with the server automatically.',
              ru: 'Локальный кэш и очередь автоматически синхронизируются с сервером.',
            ),
      child: ListView(
        children: [
          if (engine == null)
            const Card(
              child: ListTile(
                leading: Icon(Icons.pause_circle_outline),
                title: Text('Sync paused'),
                subtitle: Text(
                  'Provision this device with a trusted device or Recovery Secret.',
                ),
                trailing: Chip(label: Text('Locked')),
              ),
            )
          else
            AnimatedBuilder(
              animation: Listenable.merge([engine, ?syncFolderMaterializer]),
              builder: (context, _) {
                final (
                  icon,
                  label,
                  color,
                  tooltip,
                ) = _effectiveSyncStatusPresentation(
                  engine: engine,
                  materializer: syncFolderMaterializer,
                );
                return Card(
                  child: ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(label),
                    subtitle: tooltip != null
                        ? Text(tooltip)
                        : engine.isPaused
                        ? const Text(
                            'No new sync pass starts until you resume.',
                          )
                        : null,
                    trailing: OutlinedButton.icon(
                      onPressed: onToggleSyncPause,
                      icon: Icon(
                        engine.isPaused
                            ? Icons.play_arrow_outlined
                            : Icons.pause_outlined,
                      ),
                      label: Text(engine.isPaused ? 'Resume' : 'Pause'),
                    ),
                  ),
                );
              },
            ),
          if (defaultTargetPlatform == TargetPlatform.android)
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Local sync folder'),
                subtitle: Text(
                  syncFolder == null
                      ? 'Choose a folder to mirror server files on this device.'
                      : 'Server changes download here automatically. Tap a mirrored file in Files to open it.',
                ),
                isThreeLine: syncFolder != null,
                trailing: TextButton(
                  onPressed: onSelectSyncFolder,
                  child: Text(syncFolder == null ? 'Choose' : 'Change'),
                ),
              ),
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Local sync folder'),
                subtitle: Text(
                  syncFolder == null
                      ? 'Not selected — files stay reachable only through the Files page.'
                      : '$syncFolder\nFilesystem changes are picked up automatically. New local folders and their files are uploaded; directory deletes remain conservative.',
                ),
                isThreeLine: syncFolder != null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (syncFolder != null && onOpenSyncFolder != null)
                      OutlinedButton.icon(
                        onPressed: onOpenSyncFolder,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('Open'),
                      ),
                    if (syncFolder != null && onOpenSyncFolder != null)
                      const SizedBox(width: 8),
                    TextButton(
                      onPressed: onSelectSyncFolder,
                      child: Text(syncFolder == null ? 'Choose' : 'Change'),
                    ),
                  ],
                ),
              ),
            ),
          if (syncFolder != null && syncFolderMaterializer != null)
            AnimatedBuilder(
              animation: syncFolderMaterializer!,
              builder: (context, _) {
                final materializer = syncFolderMaterializer!;
                final (icon, label) = switch (materializer.status) {
                  SyncFolderStatus.idle => (
                    Icons.check_circle_outline,
                    'Folder mirrors the vault',
                  ),
                  SyncFolderStatus.materializing => (
                    Icons.download_outlined,
                    'Writing files to the folder…',
                  ),
                  SyncFolderStatus.error => (
                    Icons.error_outline,
                    'Could not update the folder',
                  ),
                };
                final progress = materializer.transferProgress;
                final activeFileName = materializer.activeFileName;
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        materializer.status == SyncFolderStatus.error &&
                            materializer.errorMessage != null
                        ? Text(materializer.errorMessage!)
                        : materializer.status ==
                                  SyncFolderStatus.materializing &&
                              progress != null &&
                              activeFileName != null
                        ? _syncFolderTransferProgress(
                            verb: 'Downloading',
                            fileName: activeFileName,
                            progress: progress,
                          )
                        : materializer.status == SyncFolderStatus.materializing
                        ? const Text('Preparing the local folder…')
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null &&
              localFolderUploader != null &&
              defaultTargetPlatform != TargetPlatform.android)
            AnimatedBuilder(
              animation: localFolderUploader!,
              builder: (context, _) {
                final uploader = localFolderUploader!;
                final (icon, label) = switch (uploader.status) {
                  LocalUploadStatus.idle => (
                    Icons.check_circle_outline,
                    'No local changes pending',
                  ),
                  LocalUploadStatus.scanning => (
                    Icons.upload_outlined,
                    'Uploading local changes…',
                  ),
                  LocalUploadStatus.resyncing => (
                    Icons.cloud_upload_outlined,
                    'Rebuilding Vault from local folder…',
                  ),
                  LocalUploadStatus.error => (
                    Icons.error_outline,
                    'Could not upload local changes',
                  ),
                };
                final progress = uploader.transferProgress;
                final activeFileName = uploader.activeFileName;
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        uploader.status == LocalUploadStatus.error &&
                            uploader.errorMessage != null
                        ? Text(uploader.errorMessage!)
                        : uploader.status == LocalUploadStatus.scanning &&
                              progress != null &&
                              activeFileName != null
                        ? _syncFolderTransferProgress(
                            verb: 'Uploading',
                            fileName: activeFileName,
                            progress: progress,
                          )
                        : uploader.status == LocalUploadStatus.scanning
                        ? const Text('Scanning local changes…')
                        : uploader.status == LocalUploadStatus.resyncing
                        ? const Text(
                            'Moving the old Vault to Trash and uploading a fresh encrypted tree…',
                          )
                        : null,
                  ),
                );
              },
            ),
          if (syncFolder != null &&
              engine != null &&
              localFolderUploader != null &&
              defaultTargetPlatform != TargetPlatform.android)
            Card(
              child: ListTile(
                leading: const Icon(Icons.restart_alt_outlined),
                title: const Text('Resync from local folder'),
                subtitle: const Text(
                  'Move the current server Vault to Trash, then upload this folder again from scratch.',
                ),
                trailing: FilledButton.icon(
                  key: const ValueKey('resync-vault'),
                  onPressed: resyncingVault ? null : onResyncVault,
                  icon: resyncingVault
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt_outlined),
                  label: Text(resyncingVault ? 'Resyncing…' : 'Resync'),
                ),
              ),
            ),
          if (syncFolder != null &&
              defaultTargetPlatform != TargetPlatform.android)
            AnimatedBuilder(
              animation: syncFolderWatcher,
              builder: (context, _) {
                final (icon, label) = switch (syncFolderWatcher.status) {
                  SyncFolderWatcherStatus.stopped => (
                    Icons.pause_circle_outline,
                    'Folder watcher stopped',
                  ),
                  SyncFolderWatcherStatus.watching => (
                    Icons.visibility_outlined,
                    'Watching local changes',
                  ),
                  SyncFolderWatcherStatus.error => (
                    Icons.error_outline,
                    'Folder watcher needs attention',
                  ),
                };
                return Card(
                  child: ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    subtitle:
                        syncFolderWatcher.status ==
                                SyncFolderWatcherStatus.error &&
                            syncFolderWatcher.errorMessage != null
                        ? Text(syncFolderWatcher.errorMessage!)
                        : const Text(
                            'Changes are debounced before a safe sync pass.',
                          ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Shared inline progress display for both directions of local-folder sync.
/// File transfers report byte/chunk progress; scanning and folder creation
/// remain intentionally indeterminate until a concrete file starts moving.
Widget _syncFolderTransferProgress({
  required String verb,
  required String fileName,
  required double progress,
}) {
  final percent = (progress * 100).round().clamp(0, 100);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$verb $fileName — $percent%'),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: progress),
    ],
  );
}
