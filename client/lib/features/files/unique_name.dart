/// Longest suffix treated as a file extension; anything longer is part of
/// the base name, matching how conflict copies are named.
const int _maxExtensionLength = 16;

/// The first of `name`, `name (1).ext`, `name (2).ext`, … not present in
/// [takenNames]. Compared case-insensitively, because the Windows sync
/// folder cannot hold two names that differ only by case.
///
/// Used when the user keeps both files on an upload name clash.
String uniqueSiblingName(String name, Iterable<String> takenNames) {
  final taken = {for (final taken in takenNames) taken.toLowerCase()};
  if (!taken.contains(name.toLowerCase())) return name;
  final (base, extension) = _splitExtension(name);
  for (var counter = 1; ; counter++) {
    final candidate = '$base ($counter)$extension';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
}

(String, String) _splitExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  // A leading dot is a hidden-file name, not an extension (".gitignore").
  if (dot <= 0 || fileName.length - dot > _maxExtensionLength) {
    return (fileName, '');
  }
  final extension = fileName.substring(dot);
  if (extension.contains(' ')) return (fileName, '');
  return (fileName.substring(0, dot), extension);
}
