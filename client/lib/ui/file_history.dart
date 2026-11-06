part of '../main.dart';

/// Lists this account's Trash, restores items from it, and deletes them
/// permanently, one at a time or as a selection. Items are read from the
/// local cache, so the list also works offline; a restore is queued in the
/// durable outbox like any other change, while a permanent delete needs the
/// server.
final class _TrashPage extends StatefulWidget {
  const _TrashPage({required this.controller});

  final FilesController controller;

  @override
  State<_TrashPage> createState() => _TrashPageState();
}

final class _TrashPageState extends State<_TrashPage> {
  List<TrashEntry>? _entries;
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await widget.controller.trashEntries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _selected.retainAll(entries.map((item) => item.entry.node.id));
    });
  }

  List<TrashEntry> get _selectedItems => [
    for (final item in _entries ?? const <TrashEntry>[])
      if (_selected.contains(item.entry.node.id)) item,
  ];

  void _toggle(TrashEntry item) => setState(() {
    _selecting = true;
    if (!_selected.remove(item.entry.node.id)) {
      _selected.add(item.entry.node.id);
    }
  });

  void _toggleAll() => setState(() {
    final all = _entries ?? const <TrashEntry>[];
    if (_selected.length == all.length) {
      _selected.clear();
    } else {
      _selected
        ..clear()
        ..addAll(all.map((item) => item.entry.node.id));
    }
  });

  void _endSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message.trim())));
  }

  Future<void> _restore(List<TrashEntry> items) async {
    if (items.isEmpty) return;
    setState(() => _working = true);
    final restored = await widget.controller.restoreEntries(items);
    if (!mounted) return;
    setState(() {
      _working = false;
      _selecting = false;
      _selected.clear();
    });
    _report(
      restored == items.length
          ? _localized(
              context,
              en: restored == 1
                  ? '"${items.single.entry.name}" was restored.'
                  : 'Restored $restored items.',
              ru: restored == 1
                  ? '«${items.single.entry.name}» восстановлен.'
                  : 'Восстановлено: $restored.',
            )
          : '${_localized(context, en: 'Restored $restored of ${items.length} items.', ru: 'Восстановлено $restored из ${items.length}.')} '
                '${widget.controller.errorMessage ?? ''}',
    );
    await _load();
  }

  Future<void> _purge(List<TrashEntry> items) async {
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          items.length == 1
              ? _localized(
                  context,
                  en: 'Delete "${items.single.entry.name}" permanently?',
                  ru: 'Удалить «${items.single.entry.name}» навсегда?',
                )
              : _localized(
                  context,
                  en: 'Delete ${items.length} items permanently?',
                  ru: 'Удалить навсегда элементов: ${items.length}?',
                ),
        ),
        content: Text(
          _localized(
            context,
            en: 'Folders are deleted with everything inside them, including all file versions. This cannot be undone.',
            ru: 'Папки удаляются вместе со всем содержимым и всеми версиями файлов. Это нельзя отменить.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _localized(
                context,
                en: 'Delete permanently',
                ru: 'Удалить навсегда',
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    final purged = await widget.controller.purgeEntries([
      for (final item in items) item.entry,
    ]);
    if (!mounted) return;
    setState(() {
      _working = false;
      _selecting = false;
      _selected.clear();
    });
    _report(
      purged == items.length
          ? _localized(
              context,
              en: purged == 1
                  ? 'Deleted permanently.'
                  : 'Deleted $purged items permanently.',
              ru: purged == 1
                  ? 'Удалено навсегда.'
                  : 'Удалено навсегда: $purged.',
            )
          : '${_localized(context, en: 'Deleted $purged of ${items.length} items.', ru: 'Удалено $purged из ${items.length}.')} '
                '${widget.controller.errorMessage ?? ''}',
    );
    await _load();
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
          final selected = _selected.contains(entry.node.id);
          return ListTile(
            selected: _selecting && selected,
            leading: _selecting
                ? Checkbox(
                    value: selected,
                    onChanged: _working ? null : (_) => _toggle(item),
                  )
                : entry.isDirectory
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
            onTap: _selecting && !_working ? () => _toggle(item) : null,
            onLongPress: _working ? null : () => _toggle(item),
            trailing: _selecting
                ? null
                : PopupMenuButton<String>(
                    tooltip: 'More actions',
                    enabled: !_working,
                    onSelected: (value) => switch (value) {
                      'restore' => _restore([item]),
                      'purge' => _purge([item]),
                      _ => null,
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'restore',
                        child: Text(
                          _localized(
                            context,
                            en: 'Restore',
                            ru: 'Восстановить',
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'purge',
                        child: Text(
                          _localized(
                            context,
                            en: 'Delete permanently…',
                            ru: 'Удалить навсегда…',
                          ),
                        ),
                      ),
                    ],
                  ),
          );
        },
      );
    }
    final count = _selected.length;
    final total = entries?.length ?? 0;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _selecting
                ? _localized(
                    context,
                    en: '$count selected',
                    ru: 'Выбрано: $count',
                  )
                : _localized(context, en: 'Trash', ru: 'Корзина'),
          ),
          leading: _selecting
              ? IconButton(
                  onPressed: _endSelection,
                  icon: const Icon(Icons.close),
                  tooltip: _localized(context, en: 'Cancel', ru: 'Отмена'),
                )
              : null,
          actions: _selecting
              ? [
                  Checkbox(
                    tristate: true,
                    value: count == 0 ? false : (count == total ? true : null),
                    onChanged: _working ? null : (_) => _toggleAll(),
                    semanticLabel: 'Select all',
                  ),
                  IconButton(
                    onPressed: count == 0 || _working
                        ? null
                        : () => _restore(_selectedItems),
                    icon: const Icon(Icons.restore),
                    tooltip: _localized(
                      context,
                      en: 'Restore',
                      ru: 'Восстановить',
                    ),
                  ),
                  IconButton(
                    onPressed: count == 0 || _working
                        ? null
                        : () => _purge(_selectedItems),
                    icon: const Icon(Icons.delete_forever_outlined),
                    tooltip: _localized(
                      context,
                      en: 'Delete permanently',
                      ru: 'Удалить навсегда',
                    ),
                  ),
                ]
              : [
                  if (total > 0)
                    IconButton(
                      onPressed: () => setState(() => _selecting = true),
                      icon: const Icon(Icons.checklist),
                      tooltip: _localized(context, en: 'Select', ru: 'Выбрать'),
                    ),
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
            if (_working) const LinearProgressIndicator(),
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
