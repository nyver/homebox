part of '../main.dart';

/// The rounded 0-100 percent for [FilesController.progress] — shared so the
/// Files page's own transfer row and the header's [_TransferProgressIndicator]
/// can never drift into different rounding/clamping.
int _transferProgressPercent(FilesController controller) =>
    ((controller.progress ?? 0) * 100).round().clamp(0, 100);

String _transferProgressLabel(FileTransferDirection? direction, int percent) =>
    switch (direction) {
      FileTransferDirection.upload => 'Upload progress $percent percent',
      FileTransferDirection.download => 'Download progress $percent percent',
      null => 'Transfer progress $percent percent',
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
String _fileEntrySubtitle(FileEntry entry, DateTime referenceNow) {
  final parts = <String>[];
  final size = entry.metadata.plaintextSize;
  if (size != null) parts.add(_formatFileSize(size));
  parts.add(
    'Updated ${_formatRelativeTime(entry.node.updatedAt, referenceNow)}',
  );
  return parts.join(' • ');
}

String _fileSortLabel(FileListSort sort) => switch (sort) {
  FileListSort.name => 'Name',
  FileListSort.extension => 'Extension',
  FileListSort.updatedAt => 'Date updated',
};

String _formatFileSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }
  final precision = unitIndex == 0 ? 0 : 1;
  return '${size.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _formatRelativeTime(DateTime utc, DateTime referenceNow) {
  final elapsed = referenceNow.toUtc().difference(utc.toUtc());
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  if (seconds < 60) return _relativeTimeUnit(seconds, 'second');
  final minutes = seconds ~/ 60;
  if (minutes < 60) return _relativeTimeUnit(minutes, 'minute');
  final hours = minutes ~/ 60;
  if (hours < 24) return _relativeTimeUnit(hours, 'hour');
  final days = hours ~/ 24;
  if (days < 30) return _relativeTimeUnit(days, 'day');
  final months = days ~/ 30;
  if (months < 12) return _relativeTimeUnit(months, 'month');
  return _relativeTimeUnit(days ~/ 365, 'year');
}

String _relativeTimeUnit(int value, String unit) =>
    '$value $unit${value == 1 ? '' : 's'} ago';

const double _fileListLeadingSize = 44;

const Widget _defaultFileListIcon = SizedBox.square(
  dimension: _fileListLeadingSize,
  child: Icon(Icons.insert_drive_file_outlined, size: _fileListLeadingSize),
);

const Widget _folderListIcon = SizedBox.square(
  dimension: _fileListLeadingSize,
  child: Icon(
    Icons.folder,
    size: _fileListLeadingSize,
    color: Colors.lightBlue,
  ),
);

/// A folder this account shares with family members (spec §28).
const Widget _sharedFolderListIcon = SizedBox.square(
  dimension: _fileListLeadingSize,
  child: Icon(
    Icons.folder_shared,
    size: _fileListLeadingSize,
    color: Colors.lightBlue,
    semanticLabel: 'Shared folder',
  ),
);

/// Shows a decrypted, downscaled image thumbnail when it is inexpensive to
/// fetch. All other files, including unsupported image encodings, retain the
/// regular file icon.
///
/// Stateful on purpose: the Files list rebuilds on every controller
/// notification (refreshes, transfer progress), and a [FutureBuilder] given
/// a fresh future on each rebuild would drop back to the icon for a frame,
/// making every thumbnail flicker. The row keeps its own bytes and only asks
/// again when the file or its content version changes.
class _FileListLeading extends StatefulWidget {
  const _FileListLeading({required this.entry, required this.controller});

  final FileEntry entry;
  final FilesController controller;

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
    if (bytes == null) return _defaultFileListIcon;
    return SizedBox.square(
      dimension: _fileListLeadingSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
          image: ResizeImage(
            MemoryImage(bytes),
            width: 132,
            height: 132,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _defaultFileListIcon,
        ),
      ),
    );
  }
}

enum _OverwriteChoice { overwrite, skip, cancel }

Future<_OverwriteChoice> _askOverwrite(
  BuildContext context,
  String fileName,
) async {
  final choice = await showDialog<_OverwriteChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('File already exists'),
      content: Text('"$fileName" already exists in this folder.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.skip),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.overwrite),
          child: const Text('Overwrite'),
        ),
      ],
    ),
  );
  // A dismissed dialog (back button/tap outside) is treated the same as an
  // explicit Cancel — the safer default for a destructive action.
  return choice ?? _OverwriteChoice.cancel;
}

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
    required this.onDownloadCompleted,
  });

  final FilesController? controller;

  /// Family Vault sharing; null until a server and its local data are open.
  final FamilyVaultController? familyVault;
  final Future<void> Function()? onCapturePhoto;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;
  final String? syncFolder;
  final AndroidSyncFolder? androidSyncFolder;
  final Future<void> Function()? onPullToRefresh;
  final void Function({required String fileName, required String location})
  onDownloadCompleted;

  @override
  State<_FilesSection> createState() => _FilesSectionState();
}

final class _FilesSectionState extends State<_FilesSection> {
  final WindowsSyncFolder _windowsSyncFolder = WindowsSyncFolder();

  @override
  void initState() {
    super.initState();
    unawaited(WindowsFileDrop.listen(_uploadDroppedFiles));
  }

  @override
  void dispose() {
    WindowsFileDrop.stopListening();
    super.dispose();
  }

  Future<void> _createFolder(BuildContext context) async {
    final controller = widget.controller;
    if (controller == null) return;
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final ok = await controller.createFolder(name.trim());
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ?? 'Could not create the folder.',
          ),
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
  /// [FilesController.entries] prompts overwrite/skip/cancel, and an
  /// overwrite goes through [FilesController.replaceFileContent] (a new
  /// version of the existing node) rather than creating a duplicate.
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
    final toCreate = <String>[];
    final toReplace = <(FileEntry, String)>[];
    for (final path in paths) {
      final name = basenameOfLocalPath(path);
      FileEntry? existing;
      for (final entry in controller.entries) {
        if (!entry.isDirectory && entry.name == name) {
          existing = entry;
          break;
        }
      }
      if (existing == null) {
        toCreate.add(path);
        continue;
      }
      if (!context.mounted) return;
      final choice = await _askOverwrite(context, name);
      if (choice == _OverwriteChoice.cancel) return;
      if (choice == _OverwriteChoice.overwrite) {
        toReplace.add((existing, path));
      }
      // _OverwriteChoice.skip: leave this path out of both lists.
    }

    var succeeded = 0;
    var failed = 0;
    var syncFolderCopyFailures = 0;
    if (toCreate.isNotEmpty) {
      final result = await controller.uploadFiles(toCreate);
      succeeded += result.succeeded;
      failed += result.failed;
      for (final path in result.successfulPaths) {
        if (!await _copyUploadedFileToSyncFolder(
          path,
          syncFolderRelativePath,
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
        )) {
          syncFolderCopyFailures++;
        }
      } else {
        failed++;
      }
    }

    if (!context.mounted || (succeeded == 0 && failed == 0)) return;
    var message = switch ((succeeded, failed)) {
      (0, final f) => controller.errorMessage ?? 'Could not upload $f file(s).',
      (final s, 0) => 'Encrypted and uploaded $s file(s).',
      (final s, final f) =>
        'Uploaded $s file(s); $f file(s) could not be uploaded.',
    };
    if (syncFolderCopyFailures > 0) {
      message +=
          ' The sync folder could not be updated for $syncFolderCopyFailures file(s); HomeBox will download them from the server instead.';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Copies a freshly uploaded Windows file into the matching sync-folder
  /// location. The materializer later verifies its hash before recognizing
  /// the copy, preserving the server as the authoritative source on changes.
  Future<bool> _copyUploadedFileToSyncFolder(
    String sourcePath,
    String relativeParentPath,
  ) async {
    final syncFolder = widget.syncFolder;
    if (defaultTargetPlatform != TargetPlatform.windows || syncFolder == null) {
      return true;
    }
    final source = File(sourcePath);
    final destination = File(
      relativeParentPath.isEmpty
          ? '$syncFolder/${basenameOfLocalPath(sourcePath)}'
          : '$syncFolder/$relativeParentPath/${basenameOfLocalPath(sourcePath)}',
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
        SnackBar(content: Text(controller.errorMessage ?? 'Download failed.')),
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
        'Could not prepare the file for sharing.',
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
          const SnackBar(content: Text('Could not open the share sheet.')),
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
    final downloaded = await controller.downloadFile(entry, sharedFile.path);
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
        'Could not open the file.',
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
        await (downloadTo ?? (path) => controller.downloadFile(entry, path))(
          tempFile.path,
        );
    if (!downloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(controller.errorMessage ?? 'Download failed.'),
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
          const SnackBar(
            content: Text('Could not save to the selected location.'),
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
            controller.errorMessage ?? 'Could not replace the file.',
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
        downloadTo: (path) =>
            controller.downloadFileVersion(entry, version, path),
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
        SnackBar(content: Text(controller.errorMessage ?? 'Download failed.')),
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
    final nameController = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == entry.name) {
      return;
    }
    final ok = await controller.renameNode(entry, name.trim());
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Could not rename.')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ??
                _localized(
                  context,
                  en: 'Could not update the conflict copy.',
                  ru: 'Не удалось обновить конфликтную копию.',
                ),
          ),
        ),
      );
    }
  }

  Future<void> _deleteEntry(BuildContext context, FileEntry entry) async {
    final controller = widget.controller;
    if (controller == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to trash?'),
        content: Text('"${entry.name}" will be moved to the trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await controller.deleteNode(entry);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.errorMessage ?? 'Could not delete.')),
      );
    }
  }

  Future<void> _uploadDroppedFiles(List<String> paths) async {
    final controller = widget.controller;
    if (controller == null) return;
    await _uploadPathsWithOverwritePrompt(context, paths);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return const _FilesMessageState(
        icon: Icons.cloud_off_outlined,
        message: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
      );
    }
    return AnimatedBuilder(
      // The Family Vault controller too, so a folder's shared badge and its
      // "Share with family" action follow share changes immediately.
      animation: Listenable.merge([controller, ?widget.familyVault]),
      builder: (context, _) {
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
            const _FilesMessageState(
              icon: Icons.cloud_off_outlined,
              message: 'Connect to a server, sign in, and set up the vault in Settings to see your files.',
            ),
          );
        } else if (controller.status == FilesStatus.failed) {
          body = scrollableMessage(
            _FilesMessageState(
              icon: Icons.error_outline,
              message: controller.errorMessage ?? 'Files are unavailable.',
            ),
          );
        } else if (controller.status == FilesStatus.loading &&
            controller.entries.isEmpty) {
          body = scrollableMessage(
            const Center(child: CircularProgressIndicator()),
          );
        } else if (controller.entries.isEmpty) {
          body = scrollableMessage(
            const _FilesMessageState(
              icon: Icons.folder_open_outlined,
              message: 'This folder is empty.',
            ),
          );
        } else {
          body = ListView.separated(
            // Always scrollable (not just when content overflows) so the
            // pull-to-refresh gesture below still has room to register on
            // a short list.
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: controller.entries.length,
            separatorBuilder: (context, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = controller.entries[index];
              final canOpenFileLocation =
                  !entry.isDirectory &&
                  defaultTargetPlatform == TargetPlatform.windows &&
                  widget.syncFolder != null &&
                  controller.materializedRelativePath(entry.node.id) != null;
              final familyVault = widget.familyVault;
              final sharedFolder =
                  entry.isDirectory &&
                  (familyVault?.isShared(entry.node.id) ?? false);
              return ListTile(
                leading: sharedFolder
                    ? _sharedFolderListIcon
                    : entry.isDirectory
                    ? _folderListIcon
                    : _FileListLeading(entry: entry, controller: controller),
                title: entry.isConflictCopy
                    ? Row(
                        children: [
                          Flexible(child: Text(entry.name)),
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
                      )
                    : Text(entry.name),
                subtitle: entry.isDirectory
                    ? null
                    : Text(_fileEntrySubtitle(entry, controller.entriesAsOf)),
                onTap: entry.isDirectory
                    ? () => controller.openFolder(entry)
                    : () => _openOrDownloadFile(context, entry),
                trailing: PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (value) => switch (value) {
                    'save_as' => _downloadFile(context, entry),
                    'open_file_location' => _openFileLocation(context, entry),
                    'share' => _shareFile(context, entry),
                    'replace' => _replaceContent(context, entry),
                    'versions' => _showVersionHistory(context, entry),
                    'rename' => _renameEntry(context, entry),
                    'resolve_conflict' => _markConflictResolved(context, entry),
                    'delete' => _deleteEntry(context, entry),
                    'family_share' => _showShareFolderDialog(
                      context,
                      widget.familyVault!,
                      folderId: entry.node.id,
                      folderName: entry.name,
                    ),
                    _ => null,
                  },
                  // Built only when the menu opens: whether a folder can be
                  // shared walks its subtree, too costly for every row.
                  itemBuilder: (context) => [
                    if (entry.isDirectory &&
                        familyVault != null &&
                        familyVault.canShare(entry.node))
                      PopupMenuItem(
                        value: 'family_share',
                        child: Text(
                          _localized(
                            context,
                            en: 'Share with family…',
                            ru: 'Поделиться с семьёй…',
                          ),
                        ),
                      ),
                    if (!entry.isDirectory && widget.androidFileSharer != null)
                      PopupMenuItem(
                        value: 'share',
                        child: Text(
                          _localized(context, en: 'Share', ru: 'Поделиться'),
                        ),
                      ),
                    if (!entry.isDirectory)
                      const PopupMenuItem(
                        value: 'save_as',
                        child: Text('Save as…'),
                      ),
                    if (canOpenFileLocation)
                      PopupMenuItem(
                        value: 'open_file_location',
                        child: Text(
                          _localized(
                            context,
                            en: 'Open file location',
                            ru: 'Открыть расположение',
                          ),
                        ),
                      ),
                    if (!entry.isDirectory)
                      const PopupMenuItem(
                        value: 'replace',
                        child: Text('Replace content…'),
                      ),
                    if (!entry.isDirectory)
                      PopupMenuItem(
                        value: 'versions',
                        child: Text(
                          _localized(
                            context,
                            en: 'Version history…',
                            ru: 'История версий…',
                          ),
                        ),
                      ),
                    if (entry.isConflictCopy)
                      PopupMenuItem(
                        value: 'resolve_conflict',
                        child: Text(
                          _localized(
                            context,
                            en: 'Mark conflict resolved',
                            ru: 'Отметить конфликт решённым',
                          ),
                        ),
                      ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Move to trash'),
                    ),
                  ],
                ),
              );
            },
          );
        }
        return _PageFrame(
          title: _localized(context, en: 'Files', ru: 'Файлы'),
          subtitle: controller.breadcrumbNames.isEmpty
              ? _localized(context, en: 'Root', ru: 'Корень')
              : controller.breadcrumbNames.join(' / '),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  PopupMenuButton<FileListSort>(
                    tooltip: 'Sort files',
                    icon: const Icon(Icons.sort),
                    onSelected: controller.setSort,
                    itemBuilder: (context) => FileListSort.values
                        .map(
                          (sort) => CheckedPopupMenuItem<FileListSort>(
                            value: sort,
                            checked: sort == controller.sort,
                            child: Text(_fileSortLabel(sort)),
                          ),
                        )
                        .toList(growable: false),
                  ),
                  IconButton(
                    onPressed: () => _openTrash(context),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: _localized(context, en: 'Trash', ru: 'Корзина'),
                  ),
                  if (controller.canGoUp)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: controller.goUp,
                          icon: const Icon(Icons.arrow_upward),
                          tooltip: 'Up one level',
                        ),
                        IconButton(
                          onPressed: controller.goToRoot,
                          icon: const Icon(Icons.home_outlined),
                          tooltip: 'Root',
                        ),
                      ],
                    ),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    IconButton(
                      onPressed: () => _createFolder(context),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      tooltip: 'New folder',
                    ),
                    if (widget.onCapturePhoto != null)
                      IconButton(
                        onPressed: widget.onCapturePhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        tooltip: 'Camera',
                      ),
                    IconButton(
                      onPressed: () => _uploadFiles(context),
                      icon: const Icon(Icons.upload_outlined),
                      tooltip: 'Upload files',
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: () => _createFolder(context),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New folder'),
                    ),
                    if (widget.onCapturePhoto != null)
                      FilledButton.tonalIcon(
                        onPressed: widget.onCapturePhoto,
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Camera'),
                      ),
                    FilledButton.icon(
                      onPressed: () => _uploadFiles(context),
                      icon: const Icon(Icons.upload_outlined),
                      label: const Text('Upload files'),
                    ),
                  ],
                ],
              ),
              if (defaultTargetPlatform == TargetPlatform.windows) ...[
                const SizedBox(height: 8),
                Text(
                  'Drag files into this window to encrypt and upload them to this folder.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
      },
    );
  }
}

final class _FilesMessageState extends StatelessWidget {
  const _FilesMessageState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
