part of '../main.dart';

/// A folder that can be opened in [_pickFolder].
typedef _FolderOption = ({String id, String name});

/// Lets the user browse to a destination folder, starting at [rootId]
/// (the account's root when null). Resolves to the chosen folder, a record
/// whose `id` is null for the root, or null when cancelled. Folders in
/// [excludedIds] (the ones being moved) can neither be chosen nor opened,
/// so nothing can be moved into itself.
Future<({String? id})?> _pickFolder(
  BuildContext context, {
  required String title,
  required String rootName,
  required String? rootId,
  required Future<List<_FolderOption>> Function(String? folderId) loadChildren,
  Set<String> excludedIds = const {},
}) {
  final trail = <({String? id, String name})>[(id: rootId, name: rootName)];
  Future<List<_FolderOption>>? children;
  return showDialog<({String? id})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final current = trail.last;
        children ??= loadChildren(current.id);
        void openFolder(_FolderOption folder) => setState(() {
          trail.add((id: folder.id, name: folder.name));
          children = null;
        });
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: trail.length == 1
                          ? null
                          : () => setState(() {
                              trail.removeLast();
                              children = null;
                            }),
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: _localized(
                        context,
                        en: 'Up one level',
                        ru: 'На уровень вверх',
                      ),
                    ),
                    Expanded(
                      child: Text(
                        trail.map((step) => step.name).join(' / '),
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: FutureBuilder<List<_FolderOption>>(
                    future: children,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return snapshot.hasError
                            ? Center(
                                child: Text(
                                  _localized(
                                    context,
                                    en: 'Could not load folders.',
                                    ru: 'Не удалось загрузить папки.',
                                  ),
                                ),
                              )
                            : const Center(child: CircularProgressIndicator());
                      }
                      final folders = snapshot.data!;
                      if (folders.isEmpty) {
                        return Center(
                          child: Text(
                            _localized(
                              context,
                              en: 'No folders here.',
                              ru: 'Здесь нет папок.',
                            ),
                          ),
                        );
                      }
                      return ListView(
                        children: [
                          for (final folder in folders)
                            ListTile(
                              leading: _folderListIcon(context, shared: false),
                              title: Text(folder.name),
                              enabled: !excludedIds.contains(folder.id),
                              onTap: () => openFolder(folder),
                              trailing: const Icon(Icons.chevron_right),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (id: current.id)),
              child: Text(
                _localized(context, en: 'Move here', ru: 'Переместить сюда'),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Asks where to save a multi-item download and runs it: into a folder or
/// as one ZIP archive on Windows, as a ZIP archive through Android's Save
/// dialog (which cannot receive a folder). [run] performs the download and
/// returns how many files it saved, or null on failure.
Future<void> _bulkDownload(
  BuildContext context, {
  required Future<int?> Function({String? directory, String? zipPath}) run,
  required String? Function() errorMessage,
  AndroidFileSaver? androidFileSaver,
}) async {
  final archiveName =
      'HomeBox ${DateTime.now().toIso8601String().substring(0, 10)}.zip';
  final messenger = ScaffoldMessenger.of(context);
  // Read now: [context] may be gone after the dialogs and the transfer.
  final russian = Localizations.localeOf(context).languageCode == 'ru';
  String saved(int n, String location) => russian
      ? 'Сохранено $n ${_pluralRu(n, 'файл', 'файла', 'файлов')} в $location.'
      : 'Saved $n ${n == 1 ? 'file' : 'files'} to $location.';
  void report(int? written, String location) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          written == null
              ? errorMessage() ??
                    (russian ? 'Не удалось скачать.' : 'Download failed.')
              : saved(written, location),
        ),
      ),
    );
  }

  if (androidFileSaver != null) {
    final temp = await getTemporaryDirectory();
    final zip = File(
      '${temp.path}/homebox-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    try {
      final written = await run(zipPath: zip.path);
      if (written == null) {
        report(null, '');
        return;
      }
      final location = await androidFileSaver.saveFile(
        sourcePath: zip.path,
        suggestedName: archiveName,
        mimeType: 'application/zip',
      );
      if (location != null) report(written, location);
    } finally {
      if (await zip.exists()) await zip.delete();
    }
    return;
  }
  if (!context.mounted) return;
  final asZip = await showDialog<bool>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(_localized(context, en: 'Download', ru: 'Скачать')),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, false),
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              _localized(
                context,
                en: 'Save to a folder',
                ru: 'Сохранить в папку',
              ),
            ),
            subtitle: Text(
              _localized(
                context,
                en: 'Keeps the folder structure.',
                ru: 'Структура папок сохранится.',
              ),
            ),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, true),
          child: ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(
              _localized(
                context,
                en: 'Save as ZIP archive',
                ru: 'Сохранить как ZIP',
              ),
            ),
            subtitle: Text(
              _localized(
                context,
                en: 'One file you can send or keep.',
                ru: 'Один файл, который удобно отправить или хранить.',
              ),
            ),
          ),
        ),
      ],
    ),
  );
  if (asZip == null) return;
  if (asZip) {
    final location = await getSaveLocation(
      suggestedName: archiveName,
      acceptedTypeGroups: [
        XTypeGroup(
          label: russian ? 'ZIP-архив' : 'ZIP archive',
          extensions: ['zip'],
        ),
      ],
    );
    if (location == null) return;
    final path = location.path.toLowerCase().endsWith('.zip')
        ? location.path
        : '${location.path}.zip';
    report(await run(zipPath: path), path);
  } else {
    final directory = await getDirectoryPath();
    if (directory == null) return;
    report(await run(directory: directory), directory);
  }
}

/// Searches decrypted file and folder names on this device and shows where
/// a hit lives. Selecting a hit opens its folder in Files.
final class _SearchPage extends StatefulWidget {
  const _SearchPage({required this.controller});

  final FilesController controller;

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

final class _SearchPageState extends State<_SearchPage> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<LocatedEntry> _results = const [];
  bool _searching = false;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(value));
  }

  Future<void> _run(String value) async {
    final generation = ++_generation;
    setState(() => _searching = true);
    final results = await widget.controller.search(value);
    // A later keystroke already started a newer search.
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _query,
        autofocus: true,
        onChanged: _onChanged,
        onSubmitted: _run,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: _localized(
            context,
            en: 'Search file and folder names',
            ru: 'Поиск по именам файлов и папок',
          ),
          border: InputBorder.none,
        ),
      ),
      actions: [
        if (_query.text.isNotEmpty)
          IconButton(
            onPressed: () {
              _query.clear();
              _run('');
            },
            icon: const Icon(Icons.clear),
            tooltip: _localized(context, en: 'Clear', ru: 'Очистить'),
          ),
      ],
    ),
    body: Column(
      children: [
        if (_searching) const LinearProgressIndicator(),
        Expanded(
          child: _query.text.trim().isEmpty
              ? _FilesMessageState(
                  icon: Icons.search,
                  message: _localized(
                    context,
                    en: 'Names are searched on this device; the server never sees them.',
                    ru: 'Поиск идёт на этом устройстве, сервер имён не видит.',
                  ),
                )
              : _results.isEmpty && !_searching
              ? _FilesMessageState(
                  icon: Icons.search_off,
                  message: _localized(
                    context,
                    en: 'Nothing found.',
                    ru: 'Ничего не найдено.',
                  ),
                )
              : _LocatedEntryList(
                  entries: _results,
                  controller: widget.controller,
                ),
        ),
      ],
    ),
  );
}

/// This account's favorites; selecting one opens it in Files.
final class _FavoritesPage extends StatefulWidget {
  const _FavoritesPage({required this.controller});

  final FilesController controller;

  @override
  State<_FavoritesPage> createState() => _FavoritesPageState();
}

final class _FavoritesPageState extends State<_FavoritesPage> {
  List<LocatedEntry>? _entries;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await widget.controller.favoriteEntries();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _remove(LocatedEntry item) async {
    final changed = await widget.controller.setFavorite([item.entry], false);
    if (!mounted) return;
    if (changed == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ??
                _localized(
                  context,
                  en: 'Could not change favorites.',
                  ru: 'Не удалось изменить избранное.',
                ),
          ),
        ),
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(_localized(context, en: 'Favorites', ru: 'Избранное')),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: _localized(context, en: 'Refresh', ru: 'Обновить'),
          ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? _FilesMessageState(
              icon: Icons.star_outline,
              message: _localized(
                context,
                en: 'No favorites yet. Choose "Add to favorites" in a file or folder menu.',
                ru: 'Избранного пока нет. Выберите «Добавить в избранное» в меню файла или папки.',
              ),
            )
          : _LocatedEntryList(
              entries: entries,
              controller: widget.controller,
              trailing: (item) => IconButton(
                onPressed: () => _remove(item),
                icon: const Icon(Icons.star, color: Colors.amber),
                tooltip: _localized(
                  context,
                  en: 'Remove from favorites',
                  ru: 'Убрать из избранного',
                ),
              ),
            ),
    );
  }
}

/// Entries shown with their folder; selecting one opens it in Files.
final class _LocatedEntryList extends StatelessWidget {
  const _LocatedEntryList({
    required this.entries,
    required this.controller,
    this.trailing,
  });

  final List<LocatedEntry> entries;
  final FilesController controller;
  final Widget Function(LocatedEntry item)? trailing;

  @override
  Widget build(BuildContext context) => ListView.separated(
    itemCount: entries.length,
    separatorBuilder: (context, _) => const Divider(height: 1),
    itemBuilder: (context, index) {
      final item = entries[index];
      final entry = item.entry;
      return ListTile(
        leading: entry.isDirectory
            ? _folderListIcon(context, shared: false)
            : _fileTypeListIcon(context, entry.name),
        title: Text(entry.name),
        subtitle: Text(
          item.location.isEmpty
              ? _localized(context, en: 'Root', ru: 'Корень')
              : item.location,
        ),
        trailing: trailing?.call(item),
        onTap: () {
          // A folder opens itself; a file opens the folder it is in.
          unawaited(
            controller.revealFolder(
              entry.isDirectory ? entry.node.id : entry.node.parentId,
            ),
          );
          Navigator.pop(context);
        },
      );
    },
  );
}
