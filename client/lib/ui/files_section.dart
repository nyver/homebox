part of '../main.dart';

/// The rounded 0-100 percent for [FilesController.progress] — shared so the
/// Files page's own transfer row and the header's [_TransferProgressIndicator]
/// can never drift into different rounding/clamping.
int _transferProgressPercent(FilesController controller) =>
    ((controller.progress ?? 0) * 100).round().clamp(0, 100);

String _transferProgressLabel(
  BuildContext context,
  FileTransferDirection? direction,
  int percent,
) => switch (direction) {
  FileTransferDirection.upload => _localized(
    context,
    en: 'Upload progress $percent percent',
    ru: 'Отправка: $percent%',
  ),
  FileTransferDirection.download => _localized(
    context,
    en: 'Download progress $percent percent',
    ru: 'Скачивание: $percent%',
  ),
  null => _localized(
    context,
    en: 'Transfer progress $percent percent',
    ru: 'Передача: $percent%',
  ),
};

/// "size • Updated relative time" for a file's [ListTile] subtitle.
/// [FileEntry.metadata.plaintextSize] is null for files uploaded before that
/// field existed, so the size segment is simply omitted for those. Uses
/// [LocalNode.updatedAt] rather than [LocalNode.createdAt] so replacing a
/// file's content (spec: "Replace content…") is reflected here — the server
/// bumps `updated_at` on every node mutation, including a completed upload.
///
/// [referenceNow] should be [FilesController.entriesAsOf] rather than the
/// live wall clock, so this label stays fixed as of when the folder was
/// opened/refreshed instead of ticking forward on every unrelated rebuild
/// (e.g. upload/download progress notifications).
String _fileEntrySubtitle(
  BuildContext context,
  FileEntry entry,
  DateTime referenceNow,
) {
  final parts = <String>[];
  final size = entry.metadata.plaintextSize;
  if (size != null) parts.add(_formatFileSize(context, size));
  final when = _formatRelativeTime(context, entry.node.updatedAt, referenceNow);
  parts.add(_localized(context, en: 'Updated $when', ru: 'Изменён $when'));
  return parts.join(' • ');
}

String _fileSortLabel(BuildContext context, FileListSort sort) =>
    switch (sort) {
      FileListSort.name => _localized(context, en: 'Name', ru: 'Имя'),
      FileListSort.extension => _localized(
        context,
        en: 'Extension',
        ru: 'Расширение',
      ),
      FileListSort.updatedAt => _localized(
        context,
        en: 'Date updated',
        ru: 'Дата изменения',
      ),
      FileListSort.size => _localized(context, en: 'Size', ru: 'Размер'),
    };

/// The small badge telling where a file's content is; null when there is
/// nothing worth saying (no local folder in use and nothing pending).
(IconData, String)? _fileSyncBadge(
  BuildContext context,
  FileSyncState state, {
  required bool hasSyncFolder,
}) => switch (state) {
  FileSyncState.pendingUpload => (
    Icons.cloud_upload_outlined,
    _localized(context, en: 'Waiting to upload', ru: 'Ожидает отправки'),
  ),
  FileSyncState.onThisDevice => (
    Icons.offline_pin_outlined,
    _localized(context, en: 'On this device', ru: 'На этом устройстве'),
  ),
  FileSyncState.serverOnly when hasSyncFolder => (
    Icons.cloud_outlined,
    _localized(context, en: 'On the server only', ru: 'Только на сервере'),
  ),
  FileSyncState.serverOnly => null,
};

String _formatFileSize(BuildContext context, int bytes) {
  final units = _localized(
    context,
    en: 'B KB MB GB TB',
    ru: 'Б КБ МБ ГБ ТБ',
  ).split(' ');
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final precision = unitIndex == 0 ? 0 : 1;
  final number = size.toStringAsFixed(precision);
  // Russian uses a decimal comma.
  return '${_localized(context, en: number, ru: number.replaceAll('.', ','))} '
      '${units[unitIndex]}';
}

const double _fileListLeadingSize = 44;

/// A file-type icon from the name's extension, so documents, media and
/// archives can be told apart at a glance before any thumbnail loads.
IconData _fileTypeIcon(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final extension = dot <= 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' ||
    'svg' ||
    'tif' ||
    'tiff' => Icons.image_outlined,
    'mp4' ||
    'mov' ||
    'mkv' ||
    'avi' ||
    'webm' ||
    'm4v' ||
    '3gp' => Icons.movie_outlined,
    'mp3' ||
    'wav' ||
    'flac' ||
    'ogg' ||
    'm4a' ||
    'aac' ||
    'opus' => Icons.audiotrack_outlined,
    'zip' ||
    'rar' ||
    '7z' ||
    'tar' ||
    'gz' ||
    'bz2' ||
    'xz' => Icons.folder_zip_outlined,
    'doc' ||
    'docx' ||
    'odt' ||
    'rtf' ||
    'txt' ||
    'md' => Icons.description_outlined,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    'apk' => Icons.android,
    'exe' || 'msi' => Icons.terminal,
    'dart' ||
    'go' ||
    'py' ||
    'js' ||
    'ts' ||
    'java' ||
    'kt' ||
    'c' ||
    'cpp' ||
    'h' ||
    'cs' ||
    'html' ||
    'css' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'xml' ||
    'sh' => Icons.code,
    _ => Icons.insert_drive_file_outlined,
  };
}

Widget _fileTypeListIcon(
  BuildContext context,
  String fileName, {
  double size = _fileListLeadingSize,
}) => SizedBox.square(
  dimension: size,
  child: Icon(
    _fileTypeIcon(fileName),
    size: size * 0.8,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

Widget _folderListIcon(
  BuildContext context, {
  required bool shared,
  double size = _fileListLeadingSize,
}) => SizedBox.square(
  dimension: size,
  child: Icon(
    shared ? Icons.folder_shared : Icons.folder,
    size: size,
    color: Theme.of(context).colorScheme.primary,
    // A folder this account shares with family members (spec §28).
    semanticLabel: shared
        ? _localized(context, en: 'Shared folder', ru: 'Общая папка')
        : null,
  ),
);

// Shows a decrypted, downscaled image thumbnail when it is inexpensive to
/// fetch. All other files, including unsupported image encodings, retain the
/// regular file icon.
///
/// Stateful on purpose: the Files list rebuilds on every controller
/// notification (refreshes, transfer progress), and a [FutureBuilder] given
/// a fresh future on each rebuild would drop back to the icon for a frame,
/// making every thumbnail flicker. The row keeps its own bytes and only asks
/// again when the file or its content version changes.
class _FileListLeading extends StatefulWidget {
  const _FileListLeading({
    required this.entry,
    required this.controller,
    this.size = _fileListLeadingSize,
  });

  final FileEntry entry;
  final FilesController controller;
  final double size;

  @override
  State<_FileListLeading> createState() => _FileListLeadingState();
}

class _FileListLeadingState extends State<_FileListLeading> {
  Uint8List? _bytes;
  // The request this row is still waiting for, if any. Compared by identity
  // so a late completion for a previous file never paints over the current one.
  ({FilesController controller, FileEntry entry})? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FileListLeading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.entry.node.id != widget.entry.node.id ||
        oldWidget.entry.node.currentVersionId !=
            widget.entry.node.currentVersionId) {
      _release();
      _load();
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _load() {
    final controller = widget.controller;
    final entry = widget.entry;
    _bytes = controller.cachedImagePreview(entry);
    if (_bytes != null || !controller.canShowImagePreview(entry)) return;
    final request = (controller: controller, entry: entry);
    _pending = request;
    unawaited(
      controller.imagePreview(entry).then((bytes) {
        if (!identical(_pending, request)) return;
        _pending = null;
        if (mounted && bytes != null) setState(() => _bytes = bytes);
      }),
    );
  }

  void _release() {
    final pending = _pending;
    _pending = null;
    pending?.controller.releaseImagePreview(pending.entry);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final size = widget.size;
    if (bytes == null) {
      return _fileTypeListIcon(context, widget.entry.name, size: size);
    }
    // Decoded at device pixels for the display size, not the full image.
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
          image: ResizeImage(
            MemoryImage(bytes),
            width: pixels,
            height: pixels,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              _fileTypeListIcon(context, widget.entry.name, size: size),
        ),
      ),
    );
  }
}

/// What to do with an uploaded file whose name is already taken.
enum _NameClashChoice { replace, keepBoth, skip, cancel }

/// Asks how to resolve a name clash for [fileName]. When [remaining] more
/// clashes follow, offers to apply the same answer to all of them, so a
/// large drop does not turn into a long series of identical dialogs.
Future<({_NameClashChoice choice, bool applyToAll})> _askNameClash(
  BuildContext context,
  String fileName, {
  required int remaining,
}) async {
  var applyToAll = false;
  final choice = await showDialog<_NameClashChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'File already exists',
            ru: 'Файл уже существует',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _localized(
                context,
                en: '"$fileName" already exists in this folder. Replace keeps the old content in version history.',
                ru: '«$fileName» уже есть в этой папке. При замене прежнее содержимое останется в истории версий.',
              ),
            ),
            if (remaining > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: applyToAll,
                onChanged: (value) =>
                    setState(() => applyToAll = value ?? false),
                title: Text(
                  _localized(
                    context,
                    en: 'Do the same for the other $remaining',
                    ru: 'Сделать так же для остальных ($remaining)',
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _NameClashChoice.cancel),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _NameClashChoice.skip),
            child: Text(_localized(context, en: 'Skip', ru: 'Пропустить')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _NameClashChoice.keepBoth),
            child: Text(
              _localized(context, en: 'Keep both', ru: 'Сохранить оба'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _NameClashChoice.replace),
            child: Text(_localized(context, en: 'Replace', ru: 'Заменить')),
          ),
        ],
      ),
    ),
  );
  // A dismissed dialog (back button/tap outside) is treated the same as an
  // explicit Cancel — the safer default for a destructive action.
  return (choice: choice ?? _NameClashChoice.cancel, applyToAll: applyToAll);
}

/// Keyboard commands of the Files page; see [_FilesSectionState._runCommand].
enum _FilesCommand {
  search,
  selectAll,
  clearSelection,
  trash,
  rename,
  open,
  refresh,
  newFolder,
  upload,
  goUp,
}

final class _FilesCommandIntent extends Intent {
  const _FilesCommandIntent(this.command);

  final _FilesCommand command;
}

/// Runs a Files keyboard command only while it applies; a disabled command
/// is not consumed, so the key keeps its usual meaning elsewhere.
final class _FilesCommandAction extends Action<_FilesCommandIntent> {
  _FilesCommandAction({required this.canRun, required this.run});

  final bool Function(_FilesCommand command) canRun;
  final void Function(_FilesCommand command) run;

  @override
  bool isEnabled(_FilesCommandIntent intent) => canRun(intent.command);

  @override
  void invoke(_FilesCommandIntent intent) => run(intent.command);
}

const Map<ShortcutActivator, Intent> _filesShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyF, control: true): _FilesCommandIntent(
    _FilesCommand.search,
  ),
  SingleActivator(LogicalKeyboardKey.keyA, control: true): _FilesCommandIntent(
    _FilesCommand.selectAll,
  ),
  SingleActivator(LogicalKeyboardKey.escape): _FilesCommandIntent(
    _FilesCommand.clearSelection,
  ),
  SingleActivator(LogicalKeyboardKey.delete): _FilesCommandIntent(
    _FilesCommand.trash,
  ),
  SingleActivator(LogicalKeyboardKey.f2): _FilesCommandIntent(
    _FilesCommand.rename,
  ),
  SingleActivator(LogicalKeyboardKey.enter): _FilesCommandIntent(
    _FilesCommand.open,
  ),
  SingleActivator(LogicalKeyboardKey.f5): _FilesCommandIntent(
    _FilesCommand.refresh,
  ),
  SingleActivator(LogicalKeyboardKey.keyR, control: true): _FilesCommandIntent(
    _FilesCommand.refresh,
  ),
  SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true):
      _FilesCommandIntent(_FilesCommand.newFolder),
  SingleActivator(LogicalKeyboardKey.keyU, control: true): _FilesCommandIntent(
    _FilesCommand.upload,
  ),
  SingleActivator(LogicalKeyboardKey.backspace): _FilesCommandIntent(
    _FilesCommand.goUp,
  ),
  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _FilesCommandIntent(
    _FilesCommand.goUp,
  ),
};

final class _FilesSection extends StatefulWidget {
  const _FilesSection({
    required this.controller,
    required this.familyVault,
    required this.onCapturePhoto,
    required this.androidFileSaver,
    required this.androidFileSharer,
    required this.syncFolder,
    required this.androidSyncFolder,
    required this.onPullToRefresh,
    required this.onRefresh,
    required this.onOpenSettings,
    required this.onDownloadCompleted,
    required this.onOpenSharedFolder,
  });

  final FilesController? controller;

  /// Opens a folder shared with this account in the Family section.
  final void Function(IncomingShareView view) onOpenSharedFolder;

  /// Family Vault sharing; null until a server and its local data are open.
  final FamilyVaultController? familyVault;
  final Future<void> Function()? onCapturePhoto;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final String? syncFolder;
  final AndroidSyncFolder? androidSyncFolder;
  final Future<void> Function()? onPullToRefresh;

  /// Runs a sync pass and reloads the listing (toolbar button and F5).
  final Future<void> Function() onRefresh;

  /// Shows Settings, where the server connection and vault are set up.
  final VoidCallback onOpenSettings;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  State<_FilesSection> createState() => _FilesSectionState();
}

final class _FilesSectionState extends State<_FilesSection> {
  final WindowsSyncFolder _windowsSyncFolder = WindowsSyncFolder();
  final FocusNode _focusNode = FocusNode(debugLabel: 'files');
  bool _refreshing = false;

  /// The list row under the mouse pointer, which shows its checkbox.
  String? _hoveredEntryId;

  void _setHoveredEntry(String? id) {
    if (_hoveredEntryId != id) setState(() => _hoveredEntryId = id);
  }

  /// Keys of the visible folder rows, to find the folder under a file drag.
  final Map<String, GlobalKey> _folderKeys = {};

  /// Set while files are dragged over the window.
  bool _dragging = false;

  /// The folder row the dragged files would go into, if any.
  String? _dropFolderId;

  Offset _toLogical(Offset physical) =>
      physical / View.of(context).devicePixelRatio;

  void _onDragHover(Offset physical) {
    if (!mounted || widget.controller == null) return;
    final folderId = _folderAt(_toLogical(physical))?.node.id;
    if (_dragging && folderId == _dropFolderId) return;
    setState(() {
      _dragging = true;
      _dropFolderId = folderId;
    });
  }

  void _onDragExit() {
    if (!mounted || !_dragging) return;
    setState(() {
      _dragging = false;
      _dropFolderId = null;
    });
  }

  /// The listed folder whose row contains the global [position].
  FileEntry? _folderAt(Offset position) {
    final controller = widget.controller;
    if (controller == null || controller.selectionMode) return null;
    for (final entry in controller.entries) {
      if (!entry.isDirectory) continue;
      final box =
          _folderKeys[entry.node.id]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(position)) return entry;
    }
    return null;
  }

  /// Marks a folder row as a drop target and highlights it while files are
  /// dragged over it.
  Widget _asDropTarget(FileEntry entry, Widget tile) {
    if (!entry.isDirectory || defaultTargetPlatform != TargetPlatform.windows) {
      return tile;
    }
    final highlighted = _dragging && _dropFolderId == entry.node.id;
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: _folderKeys.putIfAbsent(entry.node.id, GlobalKey.new),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: highlighted ? scheme.primaryContainer : null,
          border: Border.all(
            color: highlighted ? scheme.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: tile,
      ),
    );
  }

  /// Uploads files dropped onto [folder] without opening it. A name that is
  /// already taken there gets the next free "name (n).ext": the folder is
  /// not open, so replacing an existing file is left to an explicit upload.
  Future<void> _uploadIntoFolder(FileEntry folder, List<String> paths) async {
    final controller = widget.controller;
    if (controller == null) return;
    final relativePath = [...controller.breadcrumbNames, folder.name].join('/');
    final taken = await controller.childNames(folder.node.id);
    final names = <String, String>{};
    var renamed = 0;
    for (final path in paths) {
      final name = basenameOfLocalPath(path);
      final unique = uniqueSiblingName(name, taken);
      taken.add(unique);
      if (unique != name) {
        names[path] = unique;
        renamed++;
      }
    }
    final result = await controller.uploadFilesInto(
      paths,
      folder.node.id,
      fileNames: names,
    );
    for (final path in result.successfulPaths) {
      await _copyUploadedFileToSyncFolder(
        path,
        relativePath,
        names[path] ?? basenameOfLocalPath(path),
      );
    }
    if (!mounted) return;
    String files(int n) => _countOf(
      context,
      n,
      enOne: 'file',
      enMany: 'files',
      ruOne: 'файл',
      ruFew: 'файла',
      ruMany: 'файлов',
    );
    var message = result.failed == 0
        ? _localized(
            context,
            en: 'Encrypted and uploaded ${files(result.succeeded)} to "${folder.name}".',
            ru: 'Зашифровано и загружено в «${folder.name}»: ${files(result.succeeded)}.',
          )
        : _localized(
            context,
            en: 'Uploaded ${files(result.succeeded)} to "${folder.name}"; ${files(result.failed)} could not be uploaded. ${controller.errorMessage ?? ''}',
            ru: 'Загружено в «${folder.name}»: ${files(result.succeeded)}; не удалось: ${files(result.failed)}. ${controller.errorMessage ?? ''}',
          );
    if (renamed > 0) {
      message += _localized(
        context,
        en: ' ${files(renamed)} got a new name because the folder already had that name.',
        ru: ' ${files(renamed)} получили новое имя, потому что такое уже было в папке.',
      );
    }
    _snack(context, message);
  }

  /// The Family Vault controller whose shares this page already asked for,
  /// so "Shared with me" is loaded once per server, not on every rebuild.
  FamilyVaultController? _familyLoaded;

  void _loadSharedWithMe(FilesController controller) {
    final familyVault = widget.familyVault;
    if (familyVault == null ||
        identical(familyVault, _familyLoaded) ||
        controller.status != FilesStatus.ready) {
      return;
    }
    _familyLoaded = familyVault;
    unawaited(familyVault.refresh());
  }

  @override
  void initState() {
    super.initState();
    unawaited(
      WindowsFileDrop.listen(
        onFilesDropped: _uploadDroppedFiles,
        onHover: _onDragHover,
        onExit: _onDragExit,
      ),
    );
  }

  @override
  void dispose() {
    WindowsFileDrop.stopListening();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _createFolder(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final name = await _askName(
      context,
      title: _localized(context, en: 'New folder', ru: 'Новая папка'),
      label: _localized(context, en: 'Folder name', ru: 'Имя папки'),
      confirm: _localized(context, en: 'Create', ru: 'Создать'),
      initial: '',
    );
    if (name == null) return;
    final ok = await controller.createFolder(name);
    if (!ok && context.mounted) {
      _snack(
        context,
        controller.errorMessage ??
            _localized(
              context,
              en: 'Could not create the folder.',
              ru: 'Не удалось создать папку.',
            ),
      );
    }
  }

  Future<void> _uploadFiles(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final files = await openFiles();
    if (files.isEmpty || !context.mounted) return;
    await _uploadPathsWithOverwritePrompt(
      context,
      files.map((file) => file.path).toList(growable: false),
    );
  }

  /// Uploads [paths] into the currently open folder, asking before silently
  /// clobbering a same-named file already there: a name already present in
  /// [FilesController.entries] prompts replace/keep both/skip/cancel. A
  /// replace goes through [FilesController.replaceFileContent] (a new
  /// version of the existing node) rather than creating a duplicate; "keep
  /// both" uploads under the next free "name (n).ext".
  Future<void> _uploadPathsWithOverwritePrompt(
    BuildContext context,
    List<String> paths,
  ) async {
    final controller = widget.controller;
    if (controller == null || paths.isEmpty) return;
    // uploadFiles captures this same folder before awaiting work. Preserve
    // the readable path now too, so a completed upload is copied into the
    // equivalent sync-folder location even if the user navigates meanwhile.
    final syncFolderRelativePath = controller.breadcrumbNames.join('/');
    final existingFiles = <String, FileEntry>{
      for (final entry in controller.entries)
        if (!entry.isDirectory) entry.name: entry,
    };
    final takenNames = {for (final entry in controller.entries) entry.name};
    var clashesLeft = paths
        .where((path) => existingFiles.containsKey(basenameOfLocalPath(path)))
        .length;
    final toCreate = <String>[];
    final uploadNames = <String, String>{};
    final toReplace = <(FileEntry, String)>[];
    _NameClashChoice? rememberedChoice;
    for (final path in paths) {
      final name = basenameOfLocalPath(path);
      final existing = existingFiles[name];
      if (existing == null) {
        // Two dropped files from different folders can share a name; the
        // second one must not collide with the first.
        if (takenNames.contains(name)) {
          final unique = uniqueSiblingName(name, takenNames);
          uploadNames[path] = unique;
          takenNames.add(unique);
        } else {
          takenNames.add(name);
        }
        toCreate.add(path);
        continue;
      }
      clashesLeft--;
      var choice = rememberedChoice;
      if (choice == null) {
        if (!context.mounted) return;
        final answer = await _askNameClash(
          context,
          name,
          remaining: clashesLeft,
        );
        choice = answer.choice;
        if (answer.applyToAll) rememberedChoice = choice;
      }
      switch (choice) {
        case _NameClashChoice.cancel:
          return;
        case _NameClashChoice.skip:
          break;
        case _NameClashChoice.replace:
          toReplace.add((existing, path));
        case _NameClashChoice.keepBoth:
          final unique = uniqueSiblingName(name, takenNames);
          takenNames.add(unique);
          uploadNames[path] = unique;
          toCreate.add(path);
      }
    }

    var succeeded = 0;
    var failed = 0;
    var syncFolderCopyFailures = 0;
    if (toCreate.isNotEmpty) {
      final result = await controller.uploadFiles(
        toCreate,
        fileNames: uploadNames,
      );
      succeeded += result.succeeded;
      failed += result.failed;
      for (final path in result.successfulPaths) {
        if (!await _copyUploadedFileToSyncFolder(
          path,
          syncFolderRelativePath,
          uploadNames[path] ?? basenameOfLocalPath(path),
        )) {
          syncFolderCopyFailures++;
        }
      }
    }
    for (final (entry, path) in toReplace) {
      if (await controller.replaceFileContent(entry, path)) {
        succeeded++;
        if (!await _copyUploadedFileToSyncFolder(
          path,
          syncFolderRelativePath,
          entry.name,
        )) {
          syncFolderCopyFailures++;
        }
      } else {
        failed++;
      }
    }

    if (!context.mounted || (succeeded == 0 && failed == 0)) return;
    String files(int n) => _countOf(
      context,
      n,
      enOne: 'file',
      enMany: 'files',
      ruOne: 'файл',
      ruFew: 'файла',
      ruMany: 'файлов',
    );
    var message = switch ((succeeded, failed)) {
      (0, final f) =>
        controller.errorMessage ??
            _localized(
              context,
              en: 'Could not upload ${files(f)}.',
              ru: 'Не удалось загрузить: ${files(f)}.',
            ),
      (final s, 0) => _localized(
        context,
        en: 'Encrypted and uploaded ${files(s)}.',
        ru: 'Зашифровано и загружено: ${files(s)}.',
      ),
      (final s, final f) => _localized(
        context,
        en: 'Uploaded ${files(s)}; ${files(f)} could not be uploaded. ${controller.errorMessage ?? ''}',
        ru: 'Загружено: ${files(s)}; не удалось загрузить: ${files(f)}. ${controller.errorMessage ?? ''}',
      ),
    };
    if (syncFolderCopyFailures > 0) {
      message += _localized(
        context,
        en: ' The sync folder could not be updated for ${files(syncFolderCopyFailures)}; HomeBox will download them from the server instead.',
        ru: ' Не удалось обновить папку синхронизации для ${files(syncFolderCopyFailures)}; HomeBox скачает их с сервера.',
      );
    }
    _snack(context, message);
  }

  /// Copies a freshly uploaded Windows file into the matching sync-folder
  /// location under [fileName]. The materializer later verifies its hash
  /// before recognizing the copy, preserving the server as the
  /// authoritative source on changes.
  Future<bool> _copyUploadedFileToSyncFolder(
    String sourcePath,
    String relativeParentPath,
    String fileName,
  ) async {
    final syncFolder = widget.syncFolder;
    if (defaultTargetPlatform != TargetPlatform.windows || syncFolder == null) {
      return true;
    }
    final source = File(sourcePath);
    final destination = File(
      relativeParentPath.isEmpty
          ? '$syncFolder/$fileName'
          : '$syncFolder/$relativeParentPath/$fileName',
    );
    if (source.absolute.path.toLowerCase() ==
        destination.absolute.path.toLowerCase()) {
      return true;
    }
    try {
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _downloadFile(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final saver = widget.androidFileSaver;
    if (saver != null) {
      await _downloadFileWithAndroidSaveDialog(
        context,
        controller,
        saver,
        entry,
      );
      return;
    }
    final destination = await getSaveLocation(suggestedName: entry.name);
    if (destination == null) return;
    final ok = await controller.downloadFile(entry, destination.path);
    if (ok) {
      widget.onDownloadCompleted(
        fileName: entry.name,
        location: destination.path,
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ??
                _localized(
                  context,
                  en: 'Download failed.',
                  ru: 'Не удалось скачать.',
                ),
          ),
        ),
      );
    }
  }

  Future<void> _shareFile(BuildContext context, FileEntry entry) async {
    final sharer = widget.androidFileSharer;
    if (sharer == null || entry.isDirectory) return;

    try {
      final sharedFile = await _prepareTempFileForHandoff(
        context,
        entry,
        _localized(
          context,
          en: 'Could not prepare the file for sharing.',
          ru: 'Не удалось подготовить файл для отправки.',
        ),
      );
      if (sharedFile == null) return;
      try {
        await sharer.shareFile(
          sourcePath: sharedFile.path,
          suggestedName: entry.name,
          mimeType: entry.metadata.mimeType,
        );
      } catch (_) {
        await sharedFile.parent.delete(recursive: true);
        rethrow;
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _localized(
                context,
                en: 'Could not open the share sheet.',
                ru: 'Не удалось открыть меню «Поделиться».',
              ),
            ),
          ),
        );
      }
    }
  }

  /// Downloads and decrypts [entry] into a fresh directory under this app's
  /// share cache — the same sandboxed boundary [AndroidFileSharer] verifies
  /// before granting another app a read URI — for hand-off to either the
  /// share sheet ([_shareFile]) or an installed viewer
  /// ([_openOrDownloadFile]). Returns null on failure, having already shown
  /// [failureMessage] (or the controller's own error) and cleaned up.
  Future<File?> _prepareTempFileForHandoff(
    BuildContext context,
    FileEntry entry,
    String failureMessage,
  ) async {
    final controller = widget.controller;
    if (controller == null) return null;
    final tempDir = await getTemporaryDirectory();
    final shareRoot = Directory('${tempDir.path}/homebox_shared');
    await _deleteExpiredSharedFiles(shareRoot);
    final shareDirectory = Directory(
      '${shareRoot.path}/${entry.node.id}_${DateTime.now().microsecondsSinceEpoch}',
    );
    await shareDirectory.create(recursive: true);
    // SensitiveNodeMetadata validates file names, so this is a single safe
    // path component. Keeping the original name helps recipient apps infer
    // the extension in addition to the MIME type supplied separately.
    final sharedFile = File('${shareDirectory.path}/${entry.name}');
    final downloaded = await controller.downloadFile(
      entry,
      sharedFile.path,
      retryable: false,
    );
    if (!downloaded) {
      await shareDirectory.delete(recursive: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.errorMessage ?? failureMessage)),
        );
      }
      return null;
    }
    return sharedFile;
  }

  Future<void> _deleteExpiredSharedFiles(Directory shareRoot) async {
    if (!await shareRoot.exists()) return;
    final expiresAt = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in shareRoot.list()) {
      try {
        if ((await entity.stat()).modified.isBefore(expiresAt)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // A recipient application can still be reading a shared file. Leave
        // it for the next cleanup attempt instead of interrupting that read.
      }
    }
  }

  Future<void> _openOrDownloadFile(
    BuildContext context,
    FileEntry entry,
  ) async {
    final syncFolder = widget.syncFolder;
    final androidSyncFolder = widget.androidSyncFolder;
    final controller = widget.controller;
    final relativePath = controller?.materializedRelativePath(entry.node.id);
    if (syncFolder != null &&
        androidSyncFolder != null &&
        relativePath != null) {
      try {
        final opened = await androidSyncFolder.openFile(
          treeUri: syncFolder,
          relativePath: relativePath,
          mimeType: entry.metadata.mimeType,
        );
        if (opened) return;
      } on PlatformException {
        // If an external app cannot open the mirrored document, fall through
        // to the temp-file open path below.
      }
    }
    if (defaultTargetPlatform == TargetPlatform.windows &&
        syncFolder != null &&
        relativePath != null) {
      // The file is already mirrored on disk: open that copy in place so the
      // edits made by the external application are noticed by the sync-folder
      // watcher and uploaded, instead of editing a detached download.
      final localPath = '$syncFolder/$relativePath';
      if (await _windowsSyncFolder.openFile(localPath)) return;
      final stillPresent = await File(localPath).exists();
      if (!context.mounted) return;
      if (stillPresent) {
        // Present but refused (for example an executable type): do not
        // launch it, and do not silently download a second copy either.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _localized(
                context,
                en: 'HomeBox could not open this file. Use Save as… instead.',
                ru: 'HomeBox не удалось открыть файл. Используйте «Сохранить как…».',
              ),
            ),
          ),
        );
        return;
      }
      // The local copy vanished since the last sync pass; fall through to the
      // regular download below.
    }
    if (!context.mounted) return;

    // Not (yet) materialized to a local sync folder, so there is no document
    // to open directly. Download a temp copy — same as _shareFile does for
    // the share sheet — and hand it to an installed viewer via ACTION_VIEW,
    // instead of jumping straight to "Save as" for every unsynced tap.
    final sharer = widget.androidFileSharer;
    if (sharer != null) {
      final tempFile = await _prepareTempFileForHandoff(
        context,
        entry,
        _localized(
          context,
          en: 'Could not open the file.',
          ru: 'Не удалось открыть файл.',
        ),
      );
      if (tempFile == null) return;
      try {
        final opened = await sharer.openFile(
          sourcePath: tempFile.path,
          suggestedName: entry.name,
          mimeType: entry.metadata.mimeType,
        );
        if (opened) return;
      } on PlatformException {
        // No installed app can open this file type; fall back to Save as.
      }
    }

    if (!context.mounted) return;
    await _downloadFile(context, entry);
  }

  Future<void> _openFileLocation(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    final syncFolder = widget.syncFolder;
    final relativePath = controller?.materializedRelativePath(entry.node.id);
    if (defaultTargetPlatform != TargetPlatform.windows ||
        syncFolder == null ||
        relativePath == null) {
      return;
    }

    final opened = await _windowsSyncFolder.openFileLocation(
      '$syncFolder/$relativePath',
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _localized(
              context,
              en: 'HomeBox could not open the file location.',
              ru: 'HomeBox не удалось открыть расположение файла.',
            ),
          ),
        ),
      );
    }
  }

  /// Android's `file_selector` has no save-dialog implementation, so this
  /// decrypts to a private temp file first, then hands that off to the OS
  /// "Save As" picker (defaulting to Downloads) via [AndroidFileSaver] —
  /// which only ever copies already-decrypted bytes, keeping the E2EE
  /// boundary in [FilesController] unchanged.
  Future<void> _downloadFileWithAndroidSaveDialog(
    BuildContext context,
    FilesController controller,
    AndroidFileSaver saver,
    FileEntry entry, {
    Future<bool> Function(String path)? downloadTo,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/download_${entry.node.id}');
    final downloaded =
        await (downloadTo ??
            (path) => controller.downloadFile(entry, path, retryable: false))(
          tempFile.path,
        );
    if (!downloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.errorMessage ??
                  _localized(
                    context,
                    en: 'Download failed.',
                    ru: 'Не удалось скачать.',
                  ),
            ),
          ),
        );
      }
      unawaited(tempFile.delete().catchError((_) => tempFile));
      return;
    }
    try {
      final destination = await saver.saveFile(
        sourcePath: tempFile.path,
        suggestedName: entry.name,
        mimeType: entry.metadata.mimeType,
      );
      if (destination != null) {
        widget.onDownloadCompleted(fileName: entry.name, location: destination);
      }
    } catch (_) {
      // The file was already decrypted successfully at this point — only
      // handing it to the chosen destination failed (e.g. the device ran
      // out of storage), distinct from a decrypt/download failure above.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _localized(
                context,
                en: 'Could not save to the selected location.',
                ru: 'Не удалось сохранить в выбранное место.',
              ),
            ),
          ),
        );
      }
    } finally {
      unawaited(tempFile.delete().catchError((_) => tempFile));
    }
  }

  Future<void> _replaceContent(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final file = await openFile();
    if (file == null) return;
    final ok = await controller.replaceFileContent(entry, file.path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ??
                _localized(
                  context,
                  en: 'Could not replace the file.',
                  ru: 'Не удалось заменить файл.',
                ),
          ),
        ),
      );
    }
  }

  Future<void> _openTrash(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _TrashPage(controller: controller),
      ),
    );
  }

  Future<void> _showVersionHistory(
    BuildContext context,
    FileEntry entry,
  ) async {
    final controller = widget.controller;
    if (controller == null || entry.isDirectory) return;
    final action = await showDialog<_VersionAction>(
      context: context,
      builder: (context) =>
          _VersionHistoryDialog(controller: controller, entry: entry),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _SaveVersion(:final version):
        await _saveFileVersion(context, controller, entry, version);
      case _RestoreVersion(:final version):
        await _restoreFileVersion(context, controller, entry, version);
    }
  }

  Future<void> _saveFileVersion(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
    FileVersionEntry version,
  ) async {
    final saver = widget.androidFileSaver;
    if (saver != null) {
      await _downloadFileWithAndroidSaveDialog(
        context,
        controller,
        saver,
        entry,
        downloadTo: (path) => controller.downloadFileVersion(
          entry,
          version,
          path,
          retryable: false,
        ),
      );
      return;
    }
    final destination = await getSaveLocation(suggestedName: entry.name);
    if (destination == null) return;
    final ok = await controller.downloadFileVersion(
      entry,
      version,
      destination.path,
    );
    if (ok) {
      widget.onDownloadCompleted(
        fileName: entry.name,
        location: destination.path,
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ??
                _localized(
                  context,
                  en: 'Download failed.',
                  ru: 'Не удалось скачать.',
                ),
          ),
        ),
      );
    }
  }

  Future<void> _restoreFileVersion(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
    FileVersionEntry version,
  ) async {
    final createdAt = version.createdAt;
    final when = createdAt == null
        ? ''
        : ' (${_formatLocalDateTime(createdAt)})';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Restore this version?',
            ru: 'Восстановить эту версию?',
          ),
        ),
        content: Text(
          _localized(
            context,
            en: 'The version$when becomes the current content of "${entry.name}". The content it replaces stays in the version history.',
            ru: 'Версия$when станет текущим содержимым «${entry.name}». Заменённое содержимое останется в истории версий.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_localized(context, en: 'Restore', ru: 'Восстановить')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await controller.restoreFileVersion(entry, version);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? _localized(
                  context,
                  en: 'Restored the selected version of "${entry.name}".',
                  ru: 'Выбранная версия «${entry.name}» восстановлена.',
                )
              : controller.errorMessage ??
                    _localized(
                      context,
                      en: 'Could not restore this version.',
                      ru: 'Не удалось восстановить версию.',
                    ),
        ),
      ),
    );
  }

  Future<void> _renameEntry(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final name = await _askName(
      context,
      title: _localized(context, en: 'Rename', ru: 'Переименовать'),
      confirm: _localized(context, en: 'Rename', ru: 'Переименовать'),
      initial: entry.name,
    );
    if (name == null || name == entry.name) return;
    final ok = await controller.renameNode(entry, name);
    if (!ok && context.mounted) {
      _snack(
        context,
        controller.errorMessage ??
            _localized(
              context,
              en: 'Could not rename.',
              ru: 'Не удалось переименовать.',
            ),
      );
    }
  }

  Future<void> _markConflictResolved(
    BuildContext context,
    FileEntry entry,
  ) async {
    final controller = widget.controller;
    if (controller == null) return;
    final ok = await controller.markConflictResolved(entry);
    if (!ok && context.mounted) {
      _snack(
        context,
        controller.errorMessage ??
            _localized(
              context,
              en: 'Could not update the conflict copy.',
              ru: 'Не удалось обновить конфликтную копию.',
            ),
      );
    }
  }

  /// Moves [entries] to Trash at once, without a confirmation dialog: Trash
  /// is reversible, so an Undo action on the result is both safer (it also
  /// covers a slip of the Delete key) and quicker than asking every time.
  Future<void> _moveToTrash(
    BuildContext context,
    List<FileEntry> entries,
  ) async {
    final controller = widget.controller;
    if (controller == null || entries.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final undoLabel = _localized(context, en: 'Undo', ru: 'Отменить');
    final failedUndo = _localized(
      context,
      en: 'Could not restore everything. Open Trash to restore the rest.',
      ru: 'Не удалось восстановить всё. Остальное можно вернуть из корзины.',
    );
    final deleted = await controller.deleteNodes(entries);
    if (!context.mounted) return;
    final total = entries.length;
    final message = deleted == 0
        ? controller.errorMessage ??
              _localized(
                context,
                en: 'Could not move to Trash.',
                ru: 'Не удалось переместить в корзину.',
              )
        : deleted == total
        ? (total == 1
              ? _localized(
                  context,
                  en: 'Moved "${entries.single.name}" to Trash.',
                  ru: '«${entries.single.name}» перемещён в корзину.',
                )
              : _localized(
                  context,
                  en: 'Moved ${_itemCount(context, total)} to Trash.',
                  ru: 'В корзину перемещено: ${_itemCount(context, total)}.',
                ))
        : _localized(
            context,
            en: 'Moved $deleted of ${_itemCount(context, total)} to Trash. ${controller.errorMessage ?? ''}',
            ru: 'В корзину перемещено $deleted из ${_itemCount(context, total)}. ${controller.errorMessage ?? ''}',
          );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.trim()),
          duration: const Duration(seconds: 8),
          // Auto-hide even though it has an action: the undo window is
          // short on purpose, and Trash remains the long-term way back.
          persist: false,
          action: deleted == 0
              ? null
              : SnackBarAction(
                  label: undoLabel,
                  onPressed: () async {
                    var restored = 0;
                    for (final entry in entries) {
                      if (await controller.restoreFromTrash(entry)) restored++;
                    }
                    if (restored < entries.length) {
                      messenger.showSnackBar(
                        SnackBar(content: Text(failedUndo)),
                      );
                    }
                  },
                ),
        ),
      );
  }

  Future<void> _openPage(BuildContext context, WidgetBuilder builder) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));

  void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message.trim())));
  }

  /// Picks a destination folder and moves [entries] there.
  Future<void> _moveEntries(
    BuildContext context,
    List<FileEntry> entries,
  ) async {
    final controller = widget.controller;
    if (controller == null || entries.isEmpty) return;
    final target = await _pickFolder(
      context,
      title: entries.length == 1
          ? _localized(
              context,
              en: 'Move "${entries.single.name}" to…',
              ru: 'Переместить «${entries.single.name}» в…',
            )
          : _localized(
              context,
              en: 'Move ${_itemCount(context, entries.length)} to…',
              ru: 'Переместить ${_itemCount(context, entries.length)} в…',
            ),
      rootName: _localized(context, en: 'Root', ru: 'Корень'),
      rootId: null,
      loadChildren: (folderId) async => [
        for (final folder in await controller.folderChoices(folderId))
          (id: folder.id, name: folder.name),
      ],
      excludedIds: {
        for (final entry in entries)
          if (entry.isDirectory) entry.node.id,
      },
    );
    if (target == null || !context.mounted) return;
    final total = entries.length;
    final moved = await controller.moveNodes(entries, target.id);
    if (!context.mounted) return;
    _snack(
      context,
      moved == total
          ? _localized(
              context,
              en: 'Moved ${_itemCount(context, moved)}.',
              ru: 'Перемещено: ${_itemCount(context, moved)}.',
            )
          : _localized(
              context,
              en: 'Moved $moved of ${_itemCount(context, total)}. ${controller.errorMessage ?? ''}',
              ru: 'Перемещено $moved из ${_itemCount(context, total)}. ${controller.errorMessage ?? ''}',
            ),
    );
  }

  Future<void> _downloadEntries(
    BuildContext context,
    List<FileEntry> entries,
  ) async {
    final controller = widget.controller;
    if (controller == null || entries.isEmpty) return;
    await _bulkDownload(
      context,
      run: ({String? directory, String? zipPath}) => controller.downloadEntries(
        entries,
        directory: directory,
        zipPath: zipPath,
        // Android saves a temporary ZIP through the system dialog.
        retryable: widget.androidFileSaver == null,
      ),
      errorMessage: () => controller.errorMessage,
      androidFileSaver: widget.androidFileSaver,
    );
  }

  Future<void> _setFavorite(
    BuildContext context,
    List<FileEntry> entries,
    bool favorite,
  ) async {
    final controller = widget.controller;
    if (controller == null || entries.isEmpty) return;
    final changed = await controller.setFavorite(entries, favorite);
    if (changed < entries.length && context.mounted) {
      _snack(
        context,
        controller.errorMessage ??
            _localized(
              context,
              en: 'Could not change favorites.',
              ru: 'Не удалось изменить избранное.',
            ),
      );
    }
  }

  Future<void> _uploadDroppedFiles(List<String> paths, Offset? position) async {
    final controller = widget.controller;
    if (controller == null || !mounted) return;
    final folder = position == null ? null : _folderAt(_toLogical(position));
    if (folder != null) {
      await _uploadIntoFolder(folder, paths);
    } else {
      await _uploadPathsWithOverwritePrompt(context, paths);
    }
  }

  /// The actions of one row's menu, shared by its "⋮" button and the
  /// right-click context menu. Built only when a menu opens: whether a
  /// folder can be shared walks its subtree, too costly for every row.
  List<PopupMenuEntry<String>> _entryMenuItems(
    BuildContext context,
    FileEntry entry,
  ) {
    final controller = widget.controller!;
    final familyVault = widget.familyVault;
    final canOpenFileLocation =
        !entry.isDirectory &&
        defaultTargetPlatform == TargetPlatform.windows &&
        widget.syncFolder != null &&
        controller.materializedRelativePath(entry.node.id) != null;
    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String en,
      String ru,
    ) => PopupMenuItem(
      value: value,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(_localized(context, en: en, ru: ru)),
      ),
    );
    final favorite = controller.isFavorite(entry);
    return [
      if (entry.isDirectory)
        item('open', Icons.folder_open_outlined, 'Open', 'Открыть'),
      if (entry.isDirectory &&
          familyVault != null &&
          familyVault.canShare(entry.node))
        item(
          'family_share',
          Icons.family_restroom_outlined,
          'Share with family…',
          'Поделиться с семьёй…',
        ),
      if (!entry.isDirectory && widget.androidFileSharer != null)
        item('share', Icons.share_outlined, 'Share', 'Поделиться'),
      if (!entry.isDirectory)
        item('save_as', Icons.download_outlined, 'Save as…', 'Сохранить как…'),
      if (canOpenFileLocation)
        item(
          'open_file_location',
          Icons.folder_open_outlined,
          'Open file location',
          'Открыть расположение',
        ),
      if (!entry.isDirectory)
        item(
          'replace',
          Icons.file_upload_outlined,
          'Replace content…',
          'Заменить содержимое…',
        ),
      if (!entry.isDirectory)
        item('versions', Icons.history, 'Version history…', 'История версий…'),
      if (entry.isConflictCopy)
        item(
          'resolve_conflict',
          Icons.check_circle_outline,
          'Mark conflict resolved',
          'Отметить конфликт решённым',
        ),
      const PopupMenuDivider(),
      favorite
          ? item(
              'favorite',
              Icons.star,
              'Remove from favorites',
              'Убрать из избранного',
            )
          : item(
              'favorite',
              Icons.star_outline,
              'Add to favorites',
              'Добавить в избранное',
            ),
      item(
        'rename',
        Icons.drive_file_rename_outline,
        'Rename',
        'Переименовать',
      ),
      item('move', Icons.drive_file_move_outline, 'Move to…', 'Переместить…'),
      item('delete', Icons.delete_outline, 'Move to trash', 'В корзину'),
    ];
  }

  void _onEntryMenuSelected(
    BuildContext context,
    FileEntry entry,
    String? value,
  ) {
    final controller = widget.controller;
    if (controller == null || value == null) return;
    unawaited(switch (value) {
      'open' => Future.sync(() => controller.openFolder(entry)),
      'save_as' => _downloadFile(context, entry),
      'open_file_location' => _openFileLocation(context, entry),
      'share' => _shareFile(context, entry),
      'replace' => _replaceContent(context, entry),
      'versions' => _showVersionHistory(context, entry),
      'rename' => _renameEntry(context, entry),
      'resolve_conflict' => _markConflictResolved(context, entry),
      'delete' => _moveToTrash(context, [entry]),
      'move' => _moveEntries(context, [entry]),
      'favorite' => _setFavorite(context, [
        entry,
      ], !controller.isFavorite(entry)),
      'family_share' => _showShareFolderDialog(
        context,
        widget.familyVault!,
        folderId: entry.node.id,
        folderName: entry.name,
      ),
      _ => Future<void>.value(),
    });
  }

  Future<void> _showContextMenu(
    BuildContext context,
    FileEntry entry,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _entryMenuItems(context, entry),
    );
    if (context.mounted) _onEntryMenuSelected(context, entry, value);
  }

  /// A row tap: Ctrl+click toggles and Shift+click extends the selection, as
  /// in desktop file managers; otherwise it opens the item (or toggles it
  /// while selecting).
  void _onEntryTap(BuildContext context, FileEntry entry) {
    final controller = widget.controller!;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) {
      controller.extendSelectionTo(entry);
    } else if (keyboard.isControlPressed || controller.selectionMode) {
      controller.toggleSelection(entry);
    } else if (entry.isDirectory) {
      controller.openFolder(entry);
    } else if (controller.canShowImagePreview(entry)) {
      unawaited(_openImageViewer(context, controller, entry));
    } else {
      unawaited(_openOrDownloadFile(context, entry));
    }
  }

  /// Opens the in-app viewer on [entry], paging through every viewable
  /// image of the open folder.
  Future<void> _openImageViewer(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) {
    final images = [
      for (final candidate in controller.entries)
        if (controller.canShowImagePreview(candidate)) candidate,
    ];
    return _openPage(
      context,
      (_) => _ImageViewerPage(
        controller: controller,
        images: images,
        initialIndex: images.indexWhere((e) => e.node.id == entry.node.id),
        onSaveAs: (image) => _downloadFile(context, image),
        onOpenExternally: (image) => _openOrDownloadFile(context, image),
        onShare: widget.androidFileSharer == null
            ? null
            : (image) => _shareFile(context, image),
      ),
    );
  }

  /// Whether a keyboard command applies right now. A command that does not
  /// apply leaves its key to other handlers, so Enter still presses a
  /// focused button and Esc still reaches the rest of the app.
  bool _canRunCommand(FilesController controller, _FilesCommand command) =>
      switch (command) {
        _FilesCommand.search ||
        _FilesCommand.refresh ||
        _FilesCommand.newFolder ||
        _FilesCommand.upload => true,
        _FilesCommand.selectAll =>
          controller.entries.isNotEmpty &&
              controller.selectedEntries.length != controller.entries.length,
        _FilesCommand.clearSelection => controller.selectionMode,
        _FilesCommand.trash => controller.selectedEntries.isNotEmpty,
        _FilesCommand.rename ||
        _FilesCommand.open => controller.selectedEntries.length == 1,
        _FilesCommand.goUp => controller.canGoUp,
      };

  void _runCommand(
    BuildContext context,
    FilesController controller,
    _FilesCommand command,
  ) {
    final selected = controller.selectedEntries;
    switch (command) {
      case _FilesCommand.search:
        unawaited(
          _openPage(context, (context) => _SearchPage(controller: controller)),
        );
      case _FilesCommand.selectAll:
        controller.toggleSelectAll();
      case _FilesCommand.clearSelection:
        controller.clearSelection();
      case _FilesCommand.trash:
        unawaited(_moveToTrash(context, selected));
      case _FilesCommand.rename:
        unawaited(_renameEntry(context, selected.single));
      case _FilesCommand.open:
        final entry = selected.single;
        if (entry.isDirectory) {
          controller.openFolder(entry);
        } else {
          unawaited(_openOrDownloadFile(context, entry));
        }
      case _FilesCommand.refresh:
        unawaited(_refresh());
      case _FilesCommand.newFolder:
        unawaited(_createFolder(context));
      case _FilesCommand.upload:
        unawaited(_uploadFiles(context));
      case _FilesCommand.goUp:
        controller.goUp();
    }
  }

  Future<void> _showAddSheet(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_outlined),
              title: Text(
                _localized(context, en: 'Upload files', ru: 'Загрузить файлы'),
              ),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            if (widget.onCapturePhoto != null)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: Text(
                  _localized(context, en: 'Take a photo', ru: 'Сделать фото'),
                ),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(
                _localized(context, en: 'New folder', ru: 'Новая папка'),
              ),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'upload':
        await _uploadFiles(context);
      case 'camera':
        await widget.onCapturePhoto?.call();
      case 'folder':
        await _createFolder(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return _FilesMessageState(
        icon: Icons.cloud_off_outlined,
        message: _localized(
          context,
          en: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
          ru: 'Подключитесь к серверу, войдите и настройте хранилище в настройках, чтобы увидеть файлы.',
        ),
        action: FilledButton.icon(
          onPressed: widget.onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
          label: Text(
            _localized(context, en: 'Open Settings', ru: 'Открыть настройки'),
          ),
        ),
      );
    }
    final android = defaultTargetPlatform == TargetPlatform.android;
    return AnimatedBuilder(
      // The Family Vault controller too, so a folder's shared badge and its
      // "Share with family" action follow share changes immediately.
      animation: Listenable.merge([controller, ?widget.familyVault]),
      builder: (context, _) {
        // Forget drop-target keys of folders no longer listed.
        final listedIds = {for (final e in controller.entries) e.node.id};
        _folderKeys.removeWhere((id, _) => !listedIds.contains(id));
        if (controller.status == FilesStatus.ready &&
            widget.familyVault != null &&
            !identical(widget.familyVault, _familyLoaded)) {
          // After the frame: refresh() notifies listeners right away.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadSharedWithMe(controller);
          });
        }
        // Whichever message/spinner widget a non-list state below renders,
        // it has no Scrollable of its own, so pull-to-refresh (below) would
        // have nothing to detect the drag gesture against — wrapping it in
        // an always-scrollable, viewport-height ListView fixes that without
        // changing how it looks.
        Widget scrollableMessage(Widget child) => LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [SizedBox(height: constraints.maxHeight, child: child)],
          ),
        );
        final Widget body;
        if (controller.status == FilesStatus.idle) {
          body = scrollableMessage(
            _FilesMessageState(
              icon: Icons.cloud_off_outlined,
              message: _localized(
                context,
                en: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
                ru: 'Подключитесь к серверу, войдите и настройте хранилище в настройках, чтобы увидеть файлы.',
              ),
              action: FilledButton.icon(
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
                label: Text(
                  _localized(
                    context,
                    en: 'Open Settings',
                    ru: 'Открыть настройки',
                  ),
                ),
              ),
            ),
          );
        } else if (controller.status == FilesStatus.failed) {
          body = scrollableMessage(
            _FilesMessageState(
              icon: Icons.error_outline,
              message:
                  controller.errorMessage ??
                  _localized(
                    context,
                    en: 'Files are unavailable.',
                    ru: 'Файлы недоступны.',
                  ),
              action: OutlinedButton.icon(
                onPressed: _refreshing ? null : () => unawaited(_refresh()),
                icon: const Icon(Icons.refresh),
                label: Text(
                  _localized(context, en: 'Try again', ru: 'Повторить'),
                ),
              ),
            ),
          );
        } else if (controller.status == FilesStatus.loading &&
            controller.entries.isEmpty) {
          body = scrollableMessage(
            const Center(child: CircularProgressIndicator()),
          );
        } else if (controller.entries.isEmpty) {
          body = scrollableMessage(
            _FilesMessageState(
              icon: Icons.folder_open_outlined,
              message: defaultTargetPlatform == TargetPlatform.windows
                  ? _localized(
                      context,
                      en: 'This folder is empty. Drag files into this window to encrypt and upload them here.',
                      ru: 'Папка пуста. Перетащите файлы в это окно, чтобы зашифровать и загрузить их сюда.',
                    )
                  : _localized(
                      context,
                      en: 'This folder is empty.',
                      ru: 'Папка пуста.',
                    ),
            ),
          );
        } else {
          body = controller.viewMode == FileViewMode.grid
              ? GridView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(bottom: android ? 88 : 0),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisExtent: 172,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: controller.entries.length,
                  itemBuilder: (context, index) => _buildEntryGridTile(
                    context,
                    controller,
                    controller.entries[index],
                  ),
                )
              : ListView.separated(
                  // Always scrollable (not just when content overflows) so
                  // the pull-to-refresh gesture below still has room to
                  // register on a short list.
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Room for the add button so it never hides the last row.
                  padding: EdgeInsets.only(bottom: android ? 88 : 0),
                  itemCount: controller.entries.length,
                  separatorBuilder: (context, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _buildEntryTile(
                    context,
                    controller,
                    controller.entries[index],
                  ),
                );
        }
        final page = _PageFrame(
          title: _localized(context, en: 'Files', ru: 'Файлы'),
          subtitle: controller.breadcrumbNames.isEmpty
              ? _localized(context, en: 'Root', ru: 'Корень')
              : controller.breadcrumbNames.join(' / '),
          subtitleWidget: _Breadcrumbs(controller: controller),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.selectionMode)
                _SelectionBar(
                  controller: controller,
                  onDelete: () =>
                      _moveToTrash(context, controller.selectedEntries),
                  onMove: () =>
                      _moveEntries(context, controller.selectedEntries),
                  onDownload: () =>
                      _downloadEntries(context, controller.selectedEntries),
                  onFavorite: (favorite) => _setFavorite(
                    context,
                    controller.selectedEntries,
                    favorite,
                  ),
                )
              else
                _buildToolbar(context, controller, android: android),
              if (!controller.canGoUp &&
                  !controller.selectionMode &&
                  widget.familyVault != null)
                _SharedWithMeStrip(
                  familyVault: widget.familyVault!,
                  onOpen: widget.onOpenSharedFolder,
                ),
              const SizedBox(height: 12),
              Expanded(
                child: widget.onPullToRefresh == null
                    ? body
                    : RefreshIndicator(
                        onRefresh: widget.onPullToRefresh!,
                        child: body,
                      ),
              ),
            ],
          ),
        );
        // Android's back gesture leaves selection mode first, then walks up
        // the folder tree, and only leaves the app from the root folder.
        return PopScope(
          canPop: !controller.selectionMode && !controller.canGoUp,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (controller.selectionMode) {
              controller.clearSelection();
            } else if (controller.canGoUp) {
              controller.goUp();
            }
          },
          child: Shortcuts(
            shortcuts: _filesShortcuts,
            child: Actions(
              actions: {
                _FilesCommandIntent: _FilesCommandAction(
                  canRun: (command) => _canRunCommand(controller, command),
                  run: (command) => _runCommand(context, controller, command),
                ),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                child: Listener(
                  // The mouse "back" side button goes up a level, and any click
                  // returns keyboard focus here so shortcuts keep working.
                  onPointerDown: (event) {
                    if (event.buttons & kBackMouseButton != 0) {
                      if (controller.canGoUp) controller.goUp();
                    } else if (!_focusNode.hasFocus) {
                      _focusNode.requestFocus();
                    }
                  },
                  child: android
                      ? Stack(
                          children: [
                            Positioned.fill(child: page),
                            Positioned(
                              right: 16,
                              bottom: 16,
                              child: FloatingActionButton(
                                heroTag: null,
                                onPressed: controller.selectionMode
                                    ? null
                                    : () => unawaited(_showAddSheet(context)),
                                tooltip: _localized(
                                  context,
                                  en: 'Add',
                                  ru: 'Добавить',
                                ),
                                child: const Icon(Icons.add),
                              ),
                            ),
                          ],
                        )
                      : _dragging
                      ? Stack(
                          children: [
                            Positioned.fill(child: page),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: _DropOverlay(
                                  folderName: _dropFolderId == null
                                      ? (controller
                                                .breadcrumbNames
                                                .lastOrNull ??
                                            _localized(
                                              context,
                                              en: 'Root',
                                              ru: 'Корень',
                                            ))
                                      : controller.entries
                                            .where(
                                              (e) => e.node.id == _dropFolderId,
                                            )
                                            .firstOrNull
                                            ?.name,
                                  intoSubfolder: _dropFolderId != null,
                                ),
                              ),
                            ),
                          ],
                        )
                      : page,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// "size • Updated …", led by an icon telling where the file is.
  Widget _entrySubtitle(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) {
    final text = _fileEntrySubtitle(context, entry, controller.entriesAsOf);
    final badge = _fileSyncBadge(
      context,
      controller.syncStateOf(entry),
      hasSyncFolder: widget.syncFolder != null,
    );
    if (badge == null) return Text(text);
    final (icon, label) = badge;
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Tooltip(
              message: label,
              child: Icon(icon, size: 14, semanticLabel: label),
            ),
          ),
          TextSpan(text: ' $text'),
        ],
      ),
    );
  }

  /// One item of the grid view: a large thumbnail or icon with its name,
  /// and the same tap, long-press and context-menu behavior as a list row.
  Widget _buildEntryGridTile(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) => _asDropTarget(
    entry,
    _buildEntryGridTileContent(context, controller, entry),
  );

  Widget _buildEntryGridTileContent(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final familyVault = widget.familyVault;
    final selecting = controller.selectionMode;
    final selected = controller.isSelected(entry);
    final favorite = controller.isFavorite(entry);
    final badge = entry.isDirectory
        ? null
        : _fileSyncBadge(
            context,
            controller.syncStateOf(entry),
            hasSyncFolder: widget.syncFolder != null,
          );
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          unawaited(_showContextMenu(context, entry, details.globalPosition)),
      child: Tooltip(
        message: entry.name,
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          color: selecting && selected
              ? scheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _onEntryTap(context, entry),
            onLongPress: () => controller.toggleSelection(entry),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Center(
                          child: entry.isDirectory
                              ? _folderListIcon(
                                  context,
                                  shared:
                                      familyVault?.isShared(entry.node.id) ??
                                      false,
                                  size: 88,
                                )
                              : _FileListLeading(
                                  entry: entry,
                                  controller: controller,
                                  size: 104,
                                ),
                        ),
                        if (selecting)
                          Positioned(
                            top: 0,
                            left: 0,
                            child: Checkbox(
                              value: selected,
                              onChanged: (_) =>
                                  controller.toggleSelection(entry),
                              semanticLabel: _localized(
                                context,
                                en: 'Select ${entry.name}',
                                ru: 'Выбрать ${entry.name}',
                              ),
                            ),
                          )
                        else
                          Positioned(
                            top: 0,
                            right: 0,
                            child: PopupMenuButton<String>(
                              tooltip: _localized(
                                context,
                                en: 'More actions',
                                ru: 'Другие действия',
                              ),
                              onSelected: (value) =>
                                  _onEntryMenuSelected(context, entry, value),
                              itemBuilder: (context) =>
                                  _entryMenuItems(context, entry),
                            ),
                          ),
                        if (favorite)
                          const Positioned(
                            left: 4,
                            bottom: 4,
                            child: Icon(
                              Icons.star,
                              size: 18,
                              color: Colors.amber,
                            ),
                          ),
                        if (entry.isConflictCopy)
                          Positioned(
                            left: favorite ? 24 : 4,
                            bottom: 4,
                            child: Icon(
                              Icons.call_split,
                              size: 18,
                              color: scheme.tertiary,
                            ),
                          ),
                        if (badge != null)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: Icon(
                              badge.$1,
                              size: 18,
                              semanticLabel: badge.$2,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) => _asDropTarget(entry, _buildEntryTileContent(context, controller, entry));

  Widget _buildEntryTileContent(
    BuildContext context,
    FilesController controller,
    FileEntry entry,
  ) {
    final familyVault = widget.familyVault;
    final sharedFolder =
        entry.isDirectory && (familyVault?.isShared(entry.node.id) ?? false);
    final selecting = controller.selectionMode;
    final selected = controller.isSelected(entry);
    final favorite = controller.isFavorite(entry);
    // With a mouse, hovering a row offers its checkbox, so selecting does
    // not need a long press or Ctrl+click.
    final showCheckbox = selecting || _hoveredEntryId == entry.node.id;
    return MouseRegion(
      onEnter: (_) => _setHoveredEntry(entry.node.id),
      onExit: (_) {
        if (_hoveredEntryId == entry.node.id) _setHoveredEntry(null);
      },
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            unawaited(_showContextMenu(context, entry, details.globalPosition)),
        child: ListTile(
          selected: selecting && selected,
          leading: showCheckbox
              ? SizedBox.square(
                  dimension: _fileListLeadingSize,
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => controller.toggleSelection(entry),
                    semanticLabel: _localized(
                      context,
                      en: 'Select ${entry.name}',
                      ru: 'Выбрать ${entry.name}',
                    ),
                  ),
                )
              : entry.isDirectory
              ? _folderListIcon(context, shared: sharedFolder)
              : _FileListLeading(entry: entry, controller: controller),
          title: entry.isConflictCopy || favorite
              ? Row(
                  children: [
                    Flexible(child: Text(entry.name)),
                    if (favorite) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.star,
                        size: 16,
                        color: Colors.amber,
                        semanticLabel: _localized(
                          context,
                          en: 'Favorite',
                          ru: 'В избранном',
                        ),
                      ),
                    ],
                    if (entry.isConflictCopy) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: entry.metadata.conflictDetails!,
                        child: Icon(
                          Icons.call_split,
                          size: 18,
                          color: Theme.of(context).colorScheme.tertiary,
                          semanticLabel: _localized(
                            context,
                            en: 'Conflict copy',
                            ru: 'Конфликтная копия',
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : Text(entry.name),
          subtitle: entry.isDirectory
              ? null
              : _entrySubtitle(context, controller, entry),
          onTap: () => _onEntryTap(context, entry),
          // A long press starts selecting, as in other file managers.
          onLongPress: () => controller.toggleSelection(entry),
          trailing: selecting
              ? null
              : PopupMenuButton<String>(
                  tooltip: _localized(
                    context,
                    en: 'More actions',
                    ru: 'Другие действия',
                  ),
                  onSelected: (value) =>
                      _onEntryMenuSelected(context, entry, value),
                  itemBuilder: (context) => _entryMenuItems(context, entry),
                ),
        ),
      ),
    );
  }

  Widget _buildToolbar(
    BuildContext context,
    FilesController controller, {
    required bool android,
  }) {
    final tools = <Widget>[
      if (!android)
        IconButton(
          onPressed: _refreshing ? null : () => unawaited(_refresh()),
          icon: _refreshing
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          tooltip: _localized(context, en: 'Refresh (F5)', ru: 'Обновить (F5)'),
        ),
      IconButton(
        onPressed: () => _openPage(
          context,
          (context) => _SearchPage(controller: controller),
        ),
        icon: const Icon(Icons.search),
        tooltip: android
            ? _localized(context, en: 'Search', ru: 'Поиск')
            : _localized(context, en: 'Search (Ctrl+F)', ru: 'Поиск (Ctrl+F)'),
      ),
      IconButton(
        onPressed: () => _openPage(
          context,
          (context) => _FavoritesPage(controller: controller),
        ),
        icon: const Icon(Icons.star_outline),
        tooltip: _localized(context, en: 'Favorites', ru: 'Избранное'),
      ),
      if (controller.entries.isNotEmpty)
        IconButton(
          onPressed: controller.startSelection,
          icon: const Icon(Icons.checklist),
          tooltip: _localized(context, en: 'Select', ru: 'Выбрать'),
        ),
      IconButton(
        onPressed: () => controller.setViewMode(
          controller.viewMode == FileViewMode.list
              ? FileViewMode.grid
              : FileViewMode.list,
        ),
        icon: Icon(
          controller.viewMode == FileViewMode.list
              ? Icons.grid_view_outlined
              : Icons.view_list_outlined,
        ),
        tooltip: controller.viewMode == FileViewMode.list
            ? _localized(context, en: 'Show as grid', ru: 'Показать сеткой')
            : _localized(context, en: 'Show as list', ru: 'Показать списком'),
      ),
      PopupMenuButton<Object>(
        tooltip: _localized(context, en: 'Sort', ru: 'Сортировка'),
        icon: const Icon(Icons.sort),
        onSelected: (value) => value is FileListSort
            ? controller.setSort(value)
            : controller.toggleSortReversed(),
        itemBuilder: (context) => [
          for (final sort in FileListSort.values)
            CheckedPopupMenuItem<Object>(
              value: sort,
              checked: sort == controller.sort,
              child: Text(_fileSortLabel(context, sort)),
            ),
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(
            value: #reverse,
            checked: controller.sortReversed,
            child: Text(
              _localized(context, en: 'Reverse order', ru: 'Обратный порядок'),
            ),
          ),
        ],
      ),
      IconButton(
        onPressed: () => _openTrash(context),
        icon: const Icon(Icons.delete_outline),
        tooltip: _localized(context, en: 'Trash', ru: 'Корзина'),
      ),
      IconButton(
        onPressed: () => unawaited(_showTransfersPanel(context, controller)),
        icon: Badge(
          isLabelVisible: controller.unseenFailedTransfers > 0,
          label: Text('${controller.unseenFailedTransfers}'),
          child: const Icon(Icons.swap_vert),
        ),
        tooltip: _localized(context, en: 'Transfers', ru: 'Передачи'),
      ),
    ];
    if (android) {
      // Adding files lives in the floating button, so the toolbar keeps to
      // one row even on a narrow phone.
      return Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: tools,
      );
    }
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Tooltip(
              message: _localized(
                context,
                en: 'Or drag files into this window (Ctrl+U)',
                ru: 'Или перетащите файлы в это окно (Ctrl+U)',
              ),
              child: FilledButton.icon(
                onPressed: () => _uploadFiles(context),
                icon: const Icon(Icons.upload_outlined),
                label: Text(
                  _localized(
                    context,
                    en: 'Upload files',
                    ru: 'Загрузить файлы',
                  ),
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _createFolder(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(
                _localized(context, en: 'New folder', ru: 'Новая папка'),
              ),
            ),
            if (widget.onCapturePhoto != null)
              OutlinedButton.icon(
                onPressed: widget.onCapturePhoto,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(_localized(context, en: 'Camera', ru: 'Камера')),
              ),
          ],
        ),
        Wrap(children: tools),
      ],
    );
  }
}

/// Folders shared with this account, at the top of the Files root, so they
/// are found where files are rather than only under Family.
final class _SharedWithMeStrip extends StatelessWidget {
  const _SharedWithMeStrip({required this.familyVault, required this.onOpen});

  final FamilyVaultController familyVault;
  final void Function(IncomingShareView view) onOpen;

  @override
  Widget build(BuildContext context) {
    final shares = familyVault.incoming;
    if (shares.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _localized(context, en: 'Shared with me', ru: 'Доступно мне'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final view in shares)
                ActionChip(
                  avatar: Icon(
                    view.state == IncomingShareState.ready
                        ? Icons.folder_shared
                        : Icons.gpp_maybe_outlined,
                    size: 18,
                  ),
                  label: Text(
                    '${view.folderName ?? _localized(context, en: 'Shared folder', ru: 'Общая папка')}'
                    '${view.share.ownerUsername.isEmpty ? '' : ' · ${view.share.ownerUsername}'}',
                  ),
                  tooltip: view.state == IncomingShareState.ready
                      ? _localized(context, en: 'Open', ru: 'Открыть')
                      : _localized(
                          context,
                          en: 'Needs verification in Family',
                          ru: 'Нужна проверка в разделе «Семья»',
                        ),
                  onPressed: () => onOpen(view),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown over the Files page while files are dragged over the window: a
/// frame and a label saying where a drop would upload them.
final class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.folderName, required this.intoSubfolder});

  final String? folderName;
  final bool intoSubfolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = folderName ?? '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.06),
        border: Border.all(color: scheme.primary, width: 3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(24),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.upload_outlined, color: scheme.onPrimary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      intoSubfolder
                          ? _localized(
                              context,
                              en: 'Drop to encrypt and upload into "$name"',
                              ru: 'Отпустите, чтобы зашифровать и загрузить в «$name»',
                            )
                          : _localized(
                              context,
                              en: 'Drop to encrypt and upload to "$name"',
                              ru: 'Отпустите, чтобы зашифровать и загрузить в «$name»',
                            ),
                      style: TextStyle(color: scheme.onPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The open folder's path as links: each ancestor jumps straight there.
final class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.controller});

  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    final names = controller.breadcrumbNames;
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    final linkStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final rootLabel = _localized(context, en: 'Root', ru: 'Корень');
    Widget separator() => Icon(
      Icons.chevron_right,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (names.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                const Icon(Icons.home_outlined, size: 18),
                Text(rootLabel, style: textStyle),
              ],
            ),
          )
        else
          TextButton.icon(
            style: linkStyle,
            onPressed: controller.goToRoot,
            icon: const Icon(Icons.home_outlined, size: 18),
            label: Text(rootLabel),
          ),
        for (final (index, name) in names.indexed) ...[
          separator(),
          if (index == names.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Text(
                name,
                style: textStyle?.copyWith(fontWeight: FontWeight.w600),
              ),
            )
          else
            TextButton(
              style: linkStyle,
              onPressed: () => controller.goToBreadcrumb(index),
              child: Text(name),
            ),
        ],
      ],
    );
  }
}

final class _FilesMessageState extends StatelessWidget {
  const _FilesMessageState({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;

  /// The one thing to do next from this state, if any.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 72,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

/// Replaces the Files toolbar while entries are being selected. On a phone
/// the actions collapse to icons so they fit one row.
final class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.controller,
    required this.onDelete,
    required this.onMove,
    required this.onDownload,
    required this.onFavorite,
  });

  final FilesController controller;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onDownload;
  final void Function(bool favorite) onFavorite;

  @override
  Widget build(BuildContext context) {
    final count = controller.selectedCount;
    final total = controller.entries.length;
    final selected = controller.selectedEntries;
    final allFavorite =
        selected.isNotEmpty && selected.every(controller.isFavorite);
    final compact = MediaQuery.sizeOf(context).width < 600;
    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      bool primary = false,
    }) {
      if (compact) {
        return IconButton(
          onPressed: onPressed,
          icon: Icon(icon),
          tooltip: label,
        );
      }
      return primary
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            );
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: compact ? 0 : 8,
      runSpacing: 8,
      children: [
        Checkbox(
          tristate: true,
          value: count == 0 ? false : (count == total ? true : null),
          onChanged: (_) => controller.toggleSelectAll(),
          semanticLabel: _localized(
            context,
            en: 'Select all',
            ru: 'Выбрать все',
          ),
        ),
        Text(
          _localized(context, en: '$count selected', ru: 'Выбрано: $count'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (!compact) const SizedBox(width: 8),
        action(
          icon: Icons.drive_file_move_outline,
          label: _localized(context, en: 'Move to…', ru: 'Переместить…'),
          onPressed: count == 0 ? null : onMove,
        ),
        action(
          icon: Icons.download_outlined,
          label: _localized(context, en: 'Download', ru: 'Скачать'),
          onPressed: count == 0 || controller.busy ? null : onDownload,
        ),
        IconButton(
          onPressed: count == 0 ? null : () => onFavorite(!allFavorite),
          icon: Icon(
            allFavorite ? Icons.star : Icons.star_outline,
            color: allFavorite ? Colors.amber : null,
          ),
          tooltip: allFavorite
              ? _localized(
                  context,
                  en: 'Remove from favorites',
                  ru: 'Убрать из избранного',
                )
              : _localized(
                  context,
                  en: 'Add to favorites',
                  ru: 'Добавить в избранное',
                ),
        ),
        action(
          icon: Icons.delete_outline,
          label: _localized(context, en: 'Move to trash', ru: 'В корзину'),
          onPressed: count == 0 ? null : onDelete,
          primary: true,
        ),
        compact
            ? IconButton(
                onPressed: controller.clearSelection,
                icon: const Icon(Icons.close),
                tooltip: _localized(context, en: 'Cancel', ru: 'Отмена'),
              )
            : TextButton(
                onPressed: controller.clearSelection,
                child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
              ),
      ],
    );
  }
}
