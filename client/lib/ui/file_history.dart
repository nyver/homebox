part of '../main.dart';

/// Lists this account's Trash and restores items from it. Items are read
/// from the local cache, so the list also works offline; a restore is
/// queued in the durable outbox like any other change.
final class _TrashPage extends StatefulWidget {
  const _TrashPage({required this.controller});

  final FilesController controller;

  @override
  State<_TrashPage> createState() => _TrashPageState();
}

final class _TrashPageState extends State<_TrashPage> {
  List<TrashEntry>? _entries;
  final Set<String> _restoring = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await widget.controller.trashEntries();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _restore(TrashEntry item) async {
    setState(() => _restoring.add(item.entry.node.id));
    final ok = await widget.controller.restoreFromTrash(item.entry);
    if (!mounted) return;
    setState(() => _restoring.remove(item.entry.node.id));
    final location = item.location.isEmpty
        ? _localized(context, en: 'Root', ru: 'Корень')
        : item.location;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? _localized(
                  context,
                  en: '"${item.entry.name}" was restored to $location.',
                  ru: '«${item.entry.name}» восстановлен в $location.',
                )
              : widget.controller.errorMessage ??
                    _localized(
                      context,
                      en: 'Could not restore this item.',
                      ru: 'Не удалось восстановить элемент.',
                    ),
        ),
      ),
    );
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final Widget body;
    if (entries == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (entries.isEmpty) {
      body = _FilesMessageState(
        icon: Icons.delete_outline,
        message: _localized(
          context,
          en: 'Trash is empty.',
          ru: 'Корзина пуста.',
        ),
      );
    } else {
      body = ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (context, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = entries[index];
          final entry = item.entry;
          final deletedAt = entry.node.deletedAt;
          final location = item.location.isEmpty
              ? _localized(context, en: 'Root', ru: 'Корень')
              : item.location;
          return ListTile(
            leading: entry.isDirectory
                ? const Icon(Icons.folder_outlined)
                : const Icon(Icons.insert_drive_file_outlined),
            title: Text(entry.name),
            subtitle: Text(
              [
                _localized(context, en: 'From $location', ru: 'Из $location'),
                if (deletedAt != null)
                  _localized(
                    context,
                    en: 'deleted ${_formatLocalDateTime(deletedAt)}',
                    ru: 'удалён ${_formatLocalDateTime(deletedAt)}',
                  ),
              ].join(' • '),
            ),
            trailing: _restoring.contains(entry.node.id)
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton.icon(
                    onPressed: () => _restore(item),
                    icon: const Icon(Icons.restore),
                    label: Text(
                      _localized(context, en: 'Restore', ru: 'Восстановить'),
                    ),
                  ),
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_localized(context, en: 'Trash', ru: 'Корзина')),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: _localized(context, en: 'Refresh', ru: 'Обновить'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              _localized(
                context,
                en: 'The server permanently deletes items after they have been in Trash for its retention period.',
                ru: 'Сервер окончательно удаляет элементы, пролежавшие в корзине дольше срока хранения.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// What the user chose for one entry in the version history dialog.
sealed class _VersionAction {
  const _VersionAction(this.version);
  final FileVersionEntry version;
}

final class _SaveVersion extends _VersionAction {
  const _SaveVersion(super.version);
}

final class _RestoreVersion extends _VersionAction {
  const _RestoreVersion(super.version);
}

/// Lists [entry]'s stored versions and lets the user save or restore one.
/// Resolves to the chosen action, or null when the dialog was dismissed.
final class _VersionHistoryDialog extends StatefulWidget {
  const _VersionHistoryDialog({required this.controller, required this.entry});

  final FilesController controller;
  final FileEntry entry;

  @override
  State<_VersionHistoryDialog> createState() => _VersionHistoryDialogState();
}

final class _VersionHistoryDialogState extends State<_VersionHistoryDialog> {
  late final Future<List<FileVersionEntry>?> _versions = widget.controller
      .fileVersions(widget.entry);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _localized(
        context,
        en: 'Version history: ${widget.entry.name}',
        ru: 'История версий: ${widget.entry.name}',
      ),
    ),
    content: SizedBox(
      width: 480,
      child: FutureBuilder<List<FileVersionEntry>?>(
        future: _versions,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final versions = snapshot.data;
          if (versions == null) {
            return Text(
              widget.controller.errorMessage ??
                  _localized(
                    context,
                    en: 'Could not load the version history.',
                    ru: 'Не удалось загрузить историю версий.',
                  ),
            );
          }
          if (versions.isEmpty) {
            return Text(
              _localized(
                context,
                en: 'This file has no stored content yet.',
                ru: 'У этого файла ещё нет сохранённого содержимого.',
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _localized(
                  context,
                  en: 'Older versions are removed automatically according to the server\'s retention policy.',
                  ru: 'Старые версии удаляются автоматически по политике хранения сервера.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: versions.length,
                  separatorBuilder: (context, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _versionTile(context, versions[index]),
                ),
              ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_localized(context, en: 'Close', ru: 'Закрыть')),
      ),
    ],
  );

  Widget _versionTile(BuildContext context, FileVersionEntry version) {
    final createdAt = version.createdAt;
    final size = version.plaintextSize;
    final title = createdAt == null
        ? _localized(context, en: 'Unknown date', ru: 'Дата неизвестна')
        : _formatLocalDateTime(createdAt);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        version.isCurrent ? Icons.check_circle_outline : Icons.history,
      ),
      title: Text(title),
      subtitle: Text(
        [
          if (version.isCurrent)
            _localized(context, en: 'Current version', ru: 'Текущая версия'),
          if (size != null) _formatFileSize(size),
        ].join(' • '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context, _SaveVersion(version)),
            icon: const Icon(Icons.download_outlined),
            tooltip: _localized(context, en: 'Save as…', ru: 'Сохранить как…'),
          ),
          if (!version.isCurrent)
            IconButton(
              onPressed: () => Navigator.pop(context, _RestoreVersion(version)),
              icon: const Icon(Icons.restore),
              tooltip: _localized(
                context,
                en: 'Restore this version',
                ru: 'Восстановить эту версию',
              ),
            ),
        ],
      ),
    );
  }
}
