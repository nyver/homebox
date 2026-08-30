import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// The mobile camera capture boundary used before an ordinary E2EE upload.
///
/// Captured paths are app-private temporary files. Callers must encrypt and
/// upload them immediately; this class never reads image bytes or metadata.
abstract interface class CameraPhotoPicker {
  Future<String?> capturePhoto();

  /// Returns a camera result Android preserved after recreating the activity.
  Future<String?> recoverLostPhoto();
}

/// Android is the only currently supported HomeBox camera-capture target.
bool supportsCameraCapture(TargetPlatform platform) =>
    platform == TargetPlatform.android;

final class ImagePickerCameraPhotoPicker implements CameraPhotoPicker {
  ImagePickerCameraPhotoPicker({ImagePicker? imagePicker})
    : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  @override
  Future<String?> capturePhoto() async {
    final photo = await _imagePicker.pickImage(
      source: ImageSource.camera,
      requestFullMetadata: false,
    );
    return _usablePath(photo);
  }

  @override
  Future<String?> recoverLostPhoto() async {
    final result = await _imagePicker.retrieveLostData();
    if (result.isEmpty) return null;
    final photo = result.file;
    if (photo != null) return _usablePath(photo);
    final error = result.exception;
    if (error != null) throw error;
    return null;
  }

  String? _usablePath(XFile? file) {
    final path = file?.path;
    return path == null || path.isEmpty ? null : path;
  }
}
