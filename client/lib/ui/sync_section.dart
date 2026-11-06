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
          if (engine != null)
            AnimatedBuilder(
              animation: engine.conflicts,
              builder: (context, _) {
                final open = engine.conflicts.open;
                if (open.isEmpty) return const SizedBox.shrink();
                return _SyncConflictsCard(
                  conflicts: open,
                  log: engine.conflicts,
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
          // Android uploads edits to its mirrored files too (see
          // LocalFolderUploader.scanAndroidEdits), so the status is shown there.
          if (syncFolder != null && localFolderUploader != null)
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

/// Lists the sync conflicts this device resolved (spec §21) until the user
/// dismisses them. Content is never lost: either both versions exist side by
/// side, or the server's state was kept for a rename/move/delete.
class _SyncConflictsCard extends StatelessWidget {
  const _SyncConflictsCard({required this.conflicts, required this.log});

  /// How many conflicts are listed individually; the rest are summarized.
  static const int _maxListed = 20;

  final List<SyncConflict> conflicts;
  final SyncConflictLog log;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final listed = conflicts.take(_maxListed).toList(growable: false);
    final hidden = conflicts.length - listed.length;
    return Card(
      key: const ValueKey('sync-conflicts'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              Icons.call_split,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            title: Text(
              _localized(
                context,
                en: 'Sync conflicts (${conflicts.length})',
                ru: 'Конфликты синхронизации (${conflicts.length})',
              ),
            ),
            subtitle: Text(
              _localized(
                context,
                en: 'Nothing was lost. Review the conflict copies, then dismiss.',
                ru: 'Ничего не потеряно. Проверьте конфликтные копии и скройте уведомления.',
              ),
            ),
            trailing: TextButton(
              key: const ValueKey('dismiss-all-conflicts'),
              onPressed: log.dismissAll,
              child: Text(
                _localized(context, en: 'Dismiss all', ru: 'Скрыть все'),
              ),
            ),
          ),
          for (final conflict in listed)
            ListTile(
              dense: true,
              leading: Icon(
                conflict.kind.keepsConflictCopy
                    ? Icons.file_copy_outlined
                    : Icons.cloud_done_outlined,
              ),
              title: Text(
                conflict.fileName ??
                    _localized(context, en: 'An item', ru: 'Элемент'),
              ),
              subtitle: Text(
                [
                  _syncConflictDescription(context, conflict.kind),
                  if (conflict.conflictCopyPath != null)
                    '${_localized(context, en: 'Copy', ru: 'Копия')}: ${conflict.conflictCopyPath}',
                  _formatRelativeTime(conflict.detectedAt, now),
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: _localized(context, en: 'Dismiss', ru: 'Скрыть'),
                icon: const Icon(Icons.close),
                onPressed: () => log.dismiss(conflict.id),
              ),
            ),
          if (hidden > 0)
            ListTile(
              dense: true,
              title: Text(
                _localized(
                  context,
                  en: '$hidden more not shown',
                  ru: 'Ещё $hidden не показано',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _syncConflictDescription(BuildContext context, SyncConflictKind kind) =>
    switch (kind) {
      SyncConflictKind.bothModified => _localized(
        context,
        en: 'Changed here and on another device. Your local edit was kept as a conflict copy.',
        ru: 'Изменён здесь и на другом устройстве. Локальная правка сохранена как конфликтная копия.',
      ),
      SyncConflictKind.bothCreated => _localized(
        context,
        en: 'Another file with the same name already existed. Your local file was kept as a conflict copy.',
        ru: 'Файл с таким именем уже существовал. Локальный файл сохранён как конфликтная копия.',
      ),
      SyncConflictKind.modifiedLocallyDeletedRemotely => _localized(
        context,
        en: 'Deleted on another device after you edited it here. Your edit was kept as a conflict copy; the original is in Trash.',
        ru: 'Удалён на другом устройстве после локальной правки. Правка сохранена как конфликтная копия, оригинал — в корзине.',
      ),
      SyncConflictKind.renameRejected => _localized(
        context,
        en: 'Your rename was not applied: the item was renamed or deleted on another device.',
        ru: 'Переименование не применено: элемент переименован или удалён на другом устройстве.',
      ),
      SyncConflictKind.moveRejected => _localized(
        context,
        en: 'Your move was not applied: the item was moved or deleted on another device.',
        ru: 'Перемещение не применено: элемент перемещён или удалён на другом устройстве.',
      ),
      SyncConflictKind.deleteRejected => _localized(
        context,
        en: 'Not moved to Trash: it changed on another device first.',
        ru: 'Не перемещён в корзину: элемент сначала изменили на другом устройстве.',
      ),
    };

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

/// The Sync navigation icon, badged with the number of open sync conflicts
/// so they are noticed from any page.
class _SyncNavigationIcon extends StatelessWidget {
  const _SyncNavigationIcon({required this.conflicts, required this.icon});

  final SyncConflictLog? conflicts;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final log = conflicts;
    if (log == null) return Icon(icon);
    return AnimatedBuilder(
      animation: log,
      builder: (context, _) {
        final count = log.openCount;
        return Badge(
          isLabelVisible: count > 0,
          label: Text(count > 99 ? '99+' : '$count'),
          child: Icon(icon),
        );
      },
    );
  }
}
