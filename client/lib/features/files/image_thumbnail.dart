import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Longest edge of a cached file-list thumbnail, in physical pixels. The
/// list paints previews at 96 logical pixels; this keeps them sharp on a
/// 2x display.
const int fileThumbnailMaxDimension = 192;

/// Decodes [image] at thumbnail size and re-encodes it as PNG, so the
/// preview cache holds a few kilobytes per photo instead of the full-size
/// original. Returns [image] unchanged when it is already small or cannot
/// be decoded (the list then falls back to decoding it directly).
Future<Uint8List> shrinkImageForThumbnail(
  Uint8List image, {
  int maxDimension = fileThumbnailMaxDimension,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(image);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = math.max(descriptor.width, descriptor.height);
    if (longest <= maxDimension) return image;
    final scale = maxDimension / longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    frame = (await codec.getNextFrame()).image;
    final encoded = await frame.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null || encoded.lengthInBytes >= image.length) return image;
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } catch (_) {
    return image;
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
