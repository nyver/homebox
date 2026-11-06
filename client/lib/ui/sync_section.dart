part of '../main.dart';

/// The Sync page: one summary card with what the user usually needs (state,
/// last sync, waiting changes, "Sync now"), the local folder, and the
/// technical details and destructive Resync tucked away below.
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
    required this.onSyncNow,
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
  final Future<void> Function() onSyncNow;

  @override
  Widget build(BuildContext context) {
    final engine = syncEngine;
    final android = defaultTargetPlatform == TargetPlatform.android;
    return _PageFrame(
      title: _localized(context, en: 'Sync', ru: 'Синхронизация'),
      subtitle: _localized(
        context,
        en: 'Changes made on this device and on your other devices are exchanged automatically.',
        ru: 'Изменения на этом и других ваших устройствах передаются автоматически.',
      ),
      child: ListView(
        children: [
          if (engine == null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: Text(_syncNotSetUpLabel(context)),
                subtitle: Text(_syncNotSetUpHint(context)),
              ),
            )
          else
            _SyncSummaryCard(
              engine: engine,
              materializer: syncFolderMaterializer,
              onToggleSyncPause: onToggleSyncPause,
              onSyncNow: onSyncNow,
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
          _SyncFolderCard(
            syncFolder: syncFolder,
            onSelectSyncFolder: onSelectSyncFolder,
            onOpenSyncFolder: onOpenSyncFolder,
          ),
          if (syncFolder != null &&
              syncFolderMaterializer != null &&
              localFolderUploader != null)
            _SyncFolderActivityCard(
              materializer: syncFolderMaterializer!,
              uploader: localFolderUploader!,
              watcher: android ? null : syncFolderWatcher,
            ),
          if (syncFolder != null &&
              engine != null &&
              localFolderUploader != null &&
              !android)
            _ResyncCard(resyncing: resyncingVault, onResync: onResyncVault),
        ],
      ),
    );
  }
}

/// Overall state, when the last pass finished, how many local changes are
/// still waiting, plus Sync now and Pause/Resume.
final class _SyncSummaryCard extends StatefulWidget {
  const _SyncSummaryCard({
    required this.engine,
    required this.materializer,
    required this.onToggleSyncPause,
    required this.onSyncNow,
  });

  final SyncEngine engine;
  final SyncFolderMaterializer? materializer;
  final VoidCallback onToggleSyncPause;
  final Future<void> Function() onSyncNow;

  @override
  State<_SyncSummaryCard> createState() => _SyncSummaryCardState();
}

final class _SyncSummaryCardState extends State<_SyncSummaryCard> {
  // Re-renders "Last synced 2 minutes ago" while the page stays open.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return AnimatedBuilder(
      animation: Listenable.merge([engine, ?widget.materializer]),
      builder: (context, _) {
        final (icon, label, color, detail) = _effectiveSyncStatusPresentation(
          context,
          engine: engine,
          materializer: widget.materializer,
        );
        final lastSyncedAt = engine.lastSyncedAt;
        final pending = engine.pendingChangeCount;
        final facts = [
          ?detail,
          if (engine.isPaused)
            _localized(
              context,
              en: 'No new sync pass starts until you resume.',
              ru: 'Новая синхронизация не начнётся, пока вы не продолжите.',
            ),
          lastSyncedAt == null
              ? _localized(
                  context,
                  en: 'Not synced since HomeBox started.',
                  ru: 'С момента запуска HomeBox ещё не синхронизировано.',
                )
              : _localized(
                  context,
                  en: 'Last synced ${_formatRelativeTime(context, lastSyncedAt, DateTime.now())}.',
                  ru: 'Последняя синхронизация: ${_formatRelativeTime(context, lastSyncedAt, DateTime.now())}.',
                ),
          if (pending > 0)
            _localized(
              context,
              en: '${_countOf(context, pending, enOne: 'change', enMany: 'changes', ruOne: 'изменение', ruFew: 'изменения', ruMany: 'изменений')} waiting to upload.',
              ru: 'Ожидают отправки: ${_countOf(context, pending, enOne: 'change', enMany: 'changes', ruOne: 'изменение', ruFew: 'изменения', ruMany: 'изменений')}.',
            ),
        ];
        final syncing = engine.status == SyncStatus.syncing;
        return Card(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: Icon(icon, color: color),
                  title: Text(label),
                  subtitle: Text(facts.join('\n')),
                  isThreeLine: facts.length > 1,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: widget.onToggleSyncPause,
                        icon: Icon(
                          engine.isPaused
                              ? Icons.play_arrow_outlined
                              : Icons.pause_outlined,
                        ),
                        label: Text(
                          engine.isPaused
                              ? _localized(
                                  context,
                                  en: 'Resume',
                                  ru: 'Продолжить',
                                )
                              : _localized(context, en: 'Pause', ru: 'Пауза'),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('sync-now'),
                        onPressed: syncing || engine.isPaused
                            ? null
                            : () => unawaited(widget.onSyncNow()),
                        icon: syncing
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: Text(
                          _localized(
                            context,
                            en: 'Sync now',
                            ru: 'Синхронизировать',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _SyncFolderCard extends StatelessWidget {
  const _SyncFolderCard({
    required this.syncFolder,
    required this.onSelectSyncFolder,
    required this.onOpenSyncFolder,
  });

  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;
  final Future<void> Function()? onOpenSyncFolder;

  @override
  Widget build(BuildContext context) {
    final folder = syncFolder;
    final android = defaultTargetPlatform == TargetPlatform.android;
    final subtitle = switch ((folder, android)) {
      (null, true) => _localized(
        context,
        en: 'Choose a folder to mirror server files on this device.',
        ru: 'Выберите папку, в которую будут скачиваться файлы с сервера.',
      ),
      (null, false) => _localized(
        context,
        en: 'Not selected — files stay reachable only through the Files page.',
        ru: 'Не выбрана — файлы доступны только на странице «Файлы».',
      ),
      (_, true) => _localized(
        context,
        en: 'Server changes download here automatically. Tap a mirrored file in Files to open it.',
        ru: 'Изменения с сервера скачиваются сюда автоматически. Нажмите на файл в «Файлах», чтобы открыть его.',
      ),
      (final path?, false) => _localized(
        context,
        en: '$path\nFiles you add or edit here are uploaded automatically.',
        ru: '$path\nДобавленные и изменённые здесь файлы загружаются автоматически.',
      ),
    };
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: Text(
          _localized(
            context,
            en: 'Local sync folder',
            ru: 'Локальная папка синхронизации',
          ),
        ),
        subtitle: Text(subtitle),
        isThreeLine: folder != null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (folder != null && onOpenSyncFolder != null)
              OutlinedButton.icon(
                onPressed: onOpenSyncFolder,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(_localized(context, en: 'Open', ru: 'Открыть')),
              ),
            TextButton(
              onPressed: onSelectSyncFolder,
              child: Text(
                folder == null
                    ? _localized(context, en: 'Choose', ru: 'Выбрать')
                    : _localized(context, en: 'Change', ru: 'Изменить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the local folder is doing right now in one line, with the
/// downloader's, uploader's and watcher's individual states under Details.
final class _SyncFolderActivityCard extends StatelessWidget {
  const _SyncFolderActivityCard({
    required this.materializer,
    required this.uploader,
    required this.watcher,
  });

  final SyncFolderMaterializer materializer;
  final LocalFolderUploader uploader;

  /// Null on Android, which polls instead of watching the folder.
  final SyncFolderWatcher? watcher;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([materializer, uploader, ?watcher]),
    builder: (context, _) {
      final error = Theme.of(context).colorScheme.error;
      final downloadProgress = materializer.transferProgress;
      final uploadProgress = uploader.transferProgress;
      final watcherFailed = watcher?.status == SyncFolderWatcherStatus.error;
      final (
        IconData icon,
        Color? color,
        String title,
        Widget? subtitle,
      ) = switch (true) {
        _ when materializer.status == SyncFolderStatus.error => (
          Icons.error_outline,
          error,
          _localized(
            context,
            en: 'Could not update the folder',
            ru: 'Не удалось обновить папку',
          ),
          _optionalText(materializer.errorMessage),
        ),
        _ when uploader.status == LocalUploadStatus.error => (
          Icons.error_outline,
          error,
          _localized(
            context,
            en: 'Could not upload local changes',
            ru: 'Не удалось загрузить локальные изменения',
          ),
          _optionalText(uploader.errorMessage),
        ),
        _ when watcherFailed => (
          Icons.error_outline,
          error,
          _localized(
            context,
            en: 'Folder changes are not being noticed',
            ru: 'Изменения в папке не отслеживаются',
          ),
          _optionalText(watcher?.errorMessage),
        ),
        _ when uploader.status == LocalUploadStatus.resyncing => (
          Icons.cloud_upload_outlined,
          null,
          _localized(
            context,
            en: 'Rebuilding Vault from local folder…',
            ru: 'Пересоздание хранилища из локальной папки…',
          ),
          Text(
            _localized(
              context,
              en: 'Moving the old Vault to Trash and uploading a fresh encrypted tree…',
              ru: 'Старое хранилище перемещается в корзину, папка загружается заново…',
            ),
          ),
        ),
        _ when downloadProgress != null => (
          Icons.download_outlined,
          null,
          _localized(
            context,
            en: 'Writing files to the folder…',
            ru: 'Запись файлов в папку…',
          ),
          _syncFolderTransferProgress(
            context,
            upload: false,
            fileName: materializer.activeFileName ?? '',
            progress: downloadProgress,
          ),
        ),
        _ when uploadProgress != null => (
          Icons.upload_outlined,
          null,
          _localized(
            context,
            en: 'Uploading local changes…',
            ru: 'Загрузка локальных изменений…',
          ),
          _syncFolderTransferProgress(
            context,
            upload: true,
            fileName: uploader.activeFileName ?? '',
            progress: uploadProgress,
          ),
        ),
        _
            when materializer.status == SyncFolderStatus.materializing ||
                uploader.status == LocalUploadStatus.scanning =>
          (
            Icons.sync,
            null,
            _localized(
              context,
              en: 'Checking the folder…',
              ru: 'Проверка папки…',
            ),
            const LinearProgressIndicator(),
          ),
        _ => (
          Icons.check_circle_outline,
          _successColor(context),
          _localized(
            context,
            en: 'Folder mirrors the vault',
            ru: 'Папка совпадает с хранилищем',
          ),
          null,
        ),
      };
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: Icon(icon, color: color),
          title: Text(title),
          subtitle: subtitle,
          shape: const Border(),
          collapsedShape: const Border(),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          trailing: Text(_localized(context, en: 'Details', ru: 'Подробнее')),
          children: [
            _detailLine(
              context,
              _localized(
                context,
                en: 'Download to folder',
                ru: 'Скачивание в папку',
              ),
              switch (materializer.status) {
                SyncFolderStatus.idle => _localized(
                  context,
                  en: 'idle',
                  ru: 'ожидание',
                ),
                SyncFolderStatus.materializing => _localized(
                  context,
                  en: 'working',
                  ru: 'выполняется',
                ),
                SyncFolderStatus.error => _localized(
                  context,
                  en: 'error',
                  ru: 'ошибка',
                ),
              },
            ),
            _detailLine(
              context,
              _localized(
                context,
                en: 'Upload from folder',
                ru: 'Отправка из папки',
              ),
              switch (uploader.status) {
                LocalUploadStatus.idle => _localized(
                  context,
                  en: 'no changes pending',
                  ru: 'нет изменений',
                ),
                LocalUploadStatus.scanning => _localized(
                  context,
                  en: 'scanning',
                  ru: 'проверка',
                ),
                LocalUploadStatus.resyncing => _localized(
                  context,
                  en: 'rebuilding vault',
                  ru: 'пересоздание хранилища',
                ),
                LocalUploadStatus.error => _localized(
                  context,
                  en: 'error',
                  ru: 'ошибка',
                ),
              },
            ),
            if (watcher != null)
              _detailLine(
                context,
                _localized(
                  context,
                  en: 'Change watcher',
                  ru: 'Отслеживание изменений',
                ),
                switch (watcher!.status) {
                  SyncFolderWatcherStatus.stopped => _localized(
                    context,
                    en: 'stopped',
                    ru: 'остановлено',
                  ),
                  SyncFolderWatcherStatus.watching => _localized(
                    context,
                    en: 'watching (changes are batched for a few seconds)',
                    ru: 'активно (изменения собираются несколько секунд)',
                  ),
                  SyncFolderWatcherStatus.error => _localized(
                    context,
                    en: 'needs attention',
                    ru: 'требует внимания',
                  ),
                },
              ),
          ],
        ),
      );
    },
  );
}

Widget? _optionalText(String? text) => text == null ? null : Text(text);

Widget _detailLine(BuildContext context, String label, String value) => Padding(
  padding: const EdgeInsets.only(top: 4),
  child: Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: value),
      ],
    ),
    style: Theme.of(context).textTheme.bodySmall,
  ),
);

/// Resync is destructive (the server Vault goes to Trash), so it lives in a
/// collapsed, error-colored "Danger zone" rather than next to everyday
/// controls.
final class _ResyncCard extends StatelessWidget {
  const _ResyncCard({required this.resyncing, required this.onResync});

  final bool resyncing;
  final Future<void> Function() onResync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.warning_amber_outlined, color: scheme.error),
        title: Text(_localized(context, en: 'Danger zone', ru: 'Опасная зона')),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: resyncing,
        children: [
          ListTile(
            leading: const Icon(Icons.restart_alt_outlined),
            title: const Text('Resync from local folder'),
            subtitle: const Text(
              'Move the current server Vault to Trash, then upload this folder again from scratch.',
            ),
            trailing: FilledButton.icon(
              key: const ValueKey('resync-vault'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: resyncing ? null : onResync,
              icon: resyncing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt_outlined),
              label: Text(resyncing ? 'Resyncing…' : 'Resync'),
            ),
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
                  _formatRelativeTime(context, conflict.detectedAt, now),
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
Widget _syncFolderTransferProgress(
  BuildContext context, {
  required bool upload,
  required String fileName,
  required double progress,
}) {
  final percent = (progress * 100).round().clamp(0, 100);
  final verb = upload
      ? _localized(context, en: 'Uploading', ru: 'Отправка')
      : _localized(context, en: 'Downloading', ru: 'Скачивание');
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
