/// The final path segment of a local filesystem [path], normalizing `\` to
/// `/` first so it works for a Windows path regardless of which platform
/// this code happens to run on (tests exercise both). Shared by every call
/// site that needs to name an uploaded file the same way the upload itself
/// will (FilesController, LocalFolderUploader, and the Files page's
/// same-name-collision check), so they can never drift apart.
String basenameOfLocalPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}
