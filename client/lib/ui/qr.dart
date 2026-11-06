part of '../main.dart';

/// Scanning needs a camera, which HomeBox only uses on Android.
bool get _canScanQr => defaultTargetPlatform == TargetPlatform.android;

/// Shows [payload] as a QR code for another device to scan, with [caption]
/// under it (typically the fingerprint it carries, for reading as well).
Future<void> _showQrCodeDialog(
  BuildContext context, {
  required String title,
  required String explanation,
  required String payload,
  Widget? caption,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(explanation),
            const SizedBox(height: 16),
            // Always dark on white with a quiet zone, also in the dark
            // theme, so every camera reads it reliably.
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: QrImageView(
                data: payload,
                size: 240,
                backgroundColor: Colors.white,
                semanticsLabel: title,
              ),
            ),
            if (caption != null) ...[const SizedBox(height: 12), caption],
          ],
        ),
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_localized(context, en: 'Done', ru: 'Готово')),
      ),
    ],
  ),
);

/// Opens the camera and returns the text of the first QR code it reads, or
/// null when the user goes back.
Future<String?> _scanQrCode(BuildContext context) => Navigator.of(context)
    .push<String>(MaterialPageRoute(builder: (_) => const _QrScannerPage()));

final class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

final class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    unawaited(_scanner.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _done = true;
        Navigator.pop(context, value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(
        _localized(context, en: 'Scan QR code', ru: 'Сканирование QR-кода'),
      ),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _scanner,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? _localized(
                        context,
                        en: 'HomeBox needs camera access to scan the code. Allow it in Android settings, or compare the fingerprint by eye instead.',
                        ru: 'Для сканирования нужен доступ к камере. Разрешите его в настройках Android или сверьте отпечаток вручную.',
                      )
                    : _localized(
                        context,
                        en: 'The camera could not be started. Compare the fingerprint by eye instead.',
                        ru: 'Не удалось включить камеру. Сверьте отпечаток вручную.',
                      ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _localized(
                context,
                en: 'Point the camera at the QR code shown on the other device.',
                ru: 'Наведите камеру на QR-код на другом устройстве.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Shows this device's pairing record as a QR code, so a trusted Android
/// device can verify it by scanning instead of comparing by eye. Does
/// nothing until this device is signed in and has its key.
Future<void> _showDevicePairingQr(
  BuildContext context, {
  required DeviceSetupController deviceSetup,
  required ServerConnectionController server,
}) async {
  final publicKey = deviceSetup.publicKey;
  final fingerprint = deviceSetup.publicKeyFingerprint;
  final session = server.session;
  if (publicKey == null || fingerprint == null || session == null) return;
  await _showQrCodeDialog(
    context,
    title: _localized(
      context,
      en: 'Pairing QR code',
      ru: 'QR-код для привязки',
    ),
    explanation: _localized(
      context,
      en: 'On your trusted Android device choose Add device, pick this device, and scan this code. On a computer, compare the fingerprint below instead.',
      ru: 'На доверенном Android-устройстве выберите «Добавить устройство», укажите это устройство и отсканируйте код. На компьютере сверьте отпечаток ниже.',
    ),
    payload: devicePairingPayload(
      deviceId: session.device.id,
      keyVersion: homeBoxDeviceKeyVersion,
      publicKey: publicKey,
    ),
    caption: _FingerprintText(fingerprint),
  );
}
