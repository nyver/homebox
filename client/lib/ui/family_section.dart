part of '../main.dart';

/// Family Vault (spec §28): this account's identity for family members,
/// folders shared with it, folders it shares, and an opened shared folder.
final class _FamilySection extends StatefulWidget {
  const _FamilySection({
    required this.controller,
    required this.androidFileSaver,
    required this.androidFileSharer,
    required this.onOpenSettings,
    this.shareToOpen,
    this.onShareOpened,
  });

  final FamilyVaultController? controller;
  final AndroidFileSaver? androidFileSaver;
  final AndroidFileSharer? androidFileSharer;

  /// Shows Settings, where the server connection and vault are set up.
  final VoidCallback onOpenSettings;

  /// A shared folder picked elsewhere (Files → Shared with me) to open now;
  /// [onShareOpened] is called once it has been taken.
  final IncomingShareView? shareToOpen;
  final VoidCallback? onShareOpened;

  @override
  State<_FamilySection> createState() => _FamilySectionState();
}

final class _FamilySectionState extends State<_FamilySection> {
  SharedFolderBrowser? _browser;

  /// The last share taken from [_FamilySection.shareToOpen].
  IncomingShareView? _takenShare;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller?.refresh());
    _takeShareToOpen();
  }

  @override
  void didUpdateWidget(covariant _FamilySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _closeBrowser();
      unawaited(widget.controller?.refresh());
    }
    _takeShareToOpen();
  }

  /// Opens a share chosen in Files. One that still needs verification is
  /// left to its tile here, which offers Verify.
  void _takeShareToOpen() {
    final view = widget.shareToOpen;
    if (view == null || identical(view, _takenShare)) return;
    _takenShare = view;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onShareOpened?.call();
      if (mounted && view.state == IncomingShareState.ready) {
        unawaited(_open(view));
      }
    });
  }

  @override
  void dispose() {
    _browser?.dispose();
    super.dispose();
  }

  void _closeBrowser() {
    _browser?.dispose();
    _browser = null;
  }

  Future<void> _open(IncomingShareView view) async {
    final browser = await widget.controller?.open(view);
    if (browser == null || !mounted) {
      browser?.dispose();
      return;
    }
    setState(() {
      _closeBrowser();
      _browser = browser;
    });
    unawaited(browser.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final title = _localized(context, en: 'Family', ru: 'Семья');
    if (controller == null) {
      return _PageFrame(
        title: title,
        subtitle: _localized(context, en: 'Shared folders', ru: 'Общие папки'),
        child: _FilesMessageState(
          icon: Icons.cloud_off_outlined,
          message: _localized(
            context,
            en: 'Connect to a server, sign in, and set up the vault in Settings to share folders with your family.',
            ru: 'Подключитесь к серверу, войдите и настройте хранилище в настройках, чтобы делиться папками с семьёй.',
          ),
          action: FilledButton.icon(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            label: Text(
              _localized(context, en: 'Open Settings', ru: 'Открыть настройки'),
            ),
          ),
        ),
      );
    }
    final browser = _browser;
    if (browser != null) {
      return _SharedFolderView(
        browser: browser,
        androidFileSaver: widget.androidFileSaver,
        onClose: () => setState(_closeBrowser),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _PageFrame(
        title: title,
        subtitle: _localized(
          context,
          en: 'Folders you share with family members and folders shared with you',
          ru: 'Папки, которыми вы делитесь с семьёй, и папки, доступные вам',
        ),
        child: RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (controller.busy) ...[
                const LinearProgressIndicator(),
                if (controller.busyMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(controller.busyMessage!),
                  ),
                const SizedBox(height: 16),
              ] else if (controller.loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(),
                ),
              if (controller.errorMessage != null)
                _FamilyBanner(
                  icon: Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  message: controller.errorMessage!,
                  onDismiss: controller.clearMessages,
                ),
              if (controller.noticeMessage != null)
                _FamilyBanner(
                  icon: Icons.info_outline,
                  color: Theme.of(context).colorScheme.primary,
                  message: controller.noticeMessage!,
                  onDismiss: controller.clearMessages,
                ),
              _IdentityCard(
                controller: controller,
                androidFileSharer: widget.androidFileSharer,
              ),
              const SizedBox(height: 24),
              _SectionHeading(
                _localized(context, en: 'Shared with me', ru: 'Доступно мне'),
              ),
              if (controller.incoming.isEmpty)
                ListTile(
                  leading: Icon(Icons.folder_off_outlined),
                  title: Text(
                    _localized(
                      context,
                      en: 'Nothing has been shared with you yet.',
                      ru: 'С вами пока ничем не поделились.',
                    ),
                  ),
                ),
              for (final view in controller.incoming)
                _IncomingShareTile(
                  view: view,
                  controller: controller,
                  onOpen: () => _open(view),
                ),
              const SizedBox(height: 24),
              _SectionHeading(
                _localized(context, en: 'Shared by me', ru: 'Я делюсь'),
              ),
              if (controller.outgoing.isEmpty)
                ListTile(
                  leading: Icon(Icons.folder_shared_outlined),
                  title: Text(
                    _localized(
                      context,
                      en: 'To share a folder, open its menu in Files and choose "Share with family…".',
                      ru: 'Чтобы поделиться папкой, откройте её меню в «Файлах» и выберите «Поделиться с семьёй…».',
                    ),
                  ),
                ),
              for (final view in controller.outgoing)
                _OutgoingShareTile(view: view, controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

final class _FamilyBanner extends StatelessWidget {
  const _FamilyBanner({
    required this.icon,
    required this.color,
    required this.message,
    required this.onDismiss,
  });

  final IconData icon;
  final Color color;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon, color: color),
      title: Text(message),
      trailing: IconButton(
        tooltip: _localized(context, en: 'Dismiss', ru: 'Скрыть'),
        icon: const Icon(Icons.close),
        onPressed: onDismiss,
      ),
    ),
  );
}

/// This account's ID (what a family member enters to share with it) and
/// identity fingerprint (what both sides compare out of band).
final class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.controller, this.androidFileSharer});

  final FamilyVaultController controller;

  /// Shares the account ID as text on Android; null elsewhere.
  final AndroidFileSharer? androidFileSharer;

  @override
  Widget build(BuildContext context) {
    final accountId = controller.accountId;
    final fingerprint = controller.accountFingerprint;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _localized(
                context,
                en: 'Your family identity',
                ru: 'Ваш семейный идентификатор',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _localized(
                context,
                en:
                    'Give your account ID to the family member who wants to share a folder with you. '
                    'Before either of you trusts the other, compare the fingerprints in person or over a call.',
                ru:
                    'Передайте ID аккаунта члену семьи, который хочет поделиться с вами папкой. '
                    'Прежде чем доверять друг другу, сверьте отпечатки лично или по телефону.',
              ),
            ),
            const SizedBox(height: 12),
            _CopyableValue(
              label: _localized(context, en: 'Account ID', ru: 'ID аккаунта'),
              value: accountId,
            ),
            const SizedBox(height: 8),
            _CopyableValue(
              label: _localized(
                context,
                en: 'Account fingerprint',
                ru: 'Отпечаток аккаунта',
              ),
              value: fingerprint,
              fingerprint: true,
            ),
            if (accountId != null && fingerprint != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showQrCodeDialog(
                      context,
                      title: _localized(
                        context,
                        en: 'Your family QR code',
                        ru: 'Ваш семейный QR-код',
                      ),
                      explanation: _localized(
                        context,
                        en: 'When a family member shares a folder with you, let them scan this code in HomeBox. It fills in your account ID and checks the fingerprint for both of you.',
                        ru: 'Когда член семьи будет делиться с вами папкой, дайте ему отсканировать этот код в HomeBox. Код подставит ваш ID и проверит отпечаток.',
                      ),
                      payload: FamilyInvite(
                        accountId: accountId,
                        fingerprint: fingerprint,
                      ).encode(),
                      caption: _FingerprintText(fingerprint),
                    ),
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(
                      _localized(
                        context,
                        en: 'Show QR code',
                        ru: 'Показать QR-код',
                      ),
                    ),
                  ),
                  if (androidFileSharer != null)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        androidFileSharer!.shareText(
                          _localized(
                            context,
                            en: 'My HomeBox account ID: $accountId',
                            ru: 'Мой ID аккаунта HomeBox: $accountId',
                          ),
                          subject: _localized(
                            context,
                            en: 'HomeBox account ID',
                            ru: 'ID аккаунта HomeBox',
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.share_outlined),
                      label: Text(
                        _localized(
                          context,
                          en: 'Share ID',
                          ru: 'Поделиться ID',
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Scans a family member's QR code and tells whether it carries
/// [fingerprint]. Shows why when it does not.
Future<bool> _scanAndMatchFamilyFingerprint(
  BuildContext context,
  String fingerprint,
) async {
  final raw = await _scanQrCode(context);
  if (raw == null || !context.mounted) return false;
  final invite = FamilyInvite.tryParse(raw);
  final matches =
      invite != null && fingerprintsMatch(invite.fingerprint, fingerprint);
  if (!matches) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          invite == null
              ? _localized(
                  context,
                  en: 'That is not a HomeBox family QR code.',
                  ru: 'Это не семейный QR-код HomeBox.',
                )
              : _localized(
                  context,
                  en: 'The scanned fingerprint does not match. Do not trust this account until the fingerprints match.',
                  ru: 'Отсканированный отпечаток не совпадает. Не доверяйте этому аккаунту, пока отпечатки не совпадут.',
                ),
        ),
      ),
    );
  }
  return matches;
}

final class _CopyableValue extends StatelessWidget {
  const _CopyableValue({
    required this.label,
    required this.value,
    this.fingerprint = false,
  });

  final String label;
  final String? value;

  /// Lays the value out as a fingerprint for comparing by eye.
  final bool fingerprint;

  @override
  Widget build(BuildContext context) {
    final text = value;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              fingerprint && text != null
                  ? _FingerprintText(text)
                  : SelectableText(
                      text ?? '…',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
            ],
          ),
        ),
        IconButton(
          tooltip: _localized(
            context,
            en: 'Copy $label',
            ru: 'Копировать: $label',
          ),
          icon: const Icon(Icons.copy_outlined),
          onPressed: text == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _localized(
                            context,
                            en: '$label copied.',
                            ru: '$label: скопировано.',
                          ),
                        ),
                      ),
                    );
                  }
                },
        ),
      ],
    );
  }
}

String _permissionLabel(BuildContext context, String permission) =>
    permission == transport.SharePermission.readWrite
    ? _localized(context, en: 'Can edit', ru: 'Может изменять')
    : _localized(context, en: 'View only', ru: 'Только просмотр');

final class _IncomingShareTile extends StatelessWidget {
  const _IncomingShareTile({
    required this.view,
    required this.controller,
    required this.onOpen,
  });

  final IncomingShareView view;
  final FamilyVaultController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final owner = view.share.ownerUsername.isEmpty
        ? _localized(context, en: 'a family member', ru: 'член семьи')
        : view.share.ownerUsername;
    final permission = _permissionLabel(context, view.share.permission);
    final (icon, subtitle, action) = switch (view.state) {
      IncomingShareState.ready => (
        Icons.folder_shared,
        _localized(
          context,
          en: 'From $owner • $permission',
          ru: 'От $owner • $permission',
        ),
        null,
      ),
      IncomingShareState.unverified => (
        Icons.gpp_maybe_outlined,
        _localized(
          context,
          en: 'From $owner • Verify the owner\'s fingerprint before opening it.',
          ru: 'От $owner • Сверьте отпечаток владельца, прежде чем открывать.',
        ),
        TextButton(
          onPressed: () => _verifyOwner(context),
          child: Text(_localized(context, en: 'Verify', ru: 'Проверить')),
        ),
      ),
      IncomingShareState.identityChanged => (
        Icons.gpp_bad_outlined,
        _localized(
          context,
          en: 'From $owner • The owner\'s identity changed. Do not open this folder until you have compared fingerprints again.',
          ru: 'От $owner • Ключ владельца изменился. Не открывайте папку, пока снова не сверите отпечатки.',
        ),
        TextButton(
          onPressed: () => _verifyOwner(context),
          child: Text(
            _localized(context, en: 'Compare again', ru: 'Сверить снова'),
          ),
        ),
      ),
      IncomingShareState.waitingForKey => (
        Icons.hourglass_empty,
        _localized(
          context,
          en:
              'From $owner • Waiting for $owner to give this device access. '
              'It happens the next time $owner opens HomeBox.',
          ru:
              'От $owner • Ожидается, что $owner даст доступ этому устройству. '
              'Это произойдёт, когда $owner в следующий раз откроет HomeBox.',
        ),
        null,
      ),
      IncomingShareState.invalid => (
        Icons.error_outline,
        _localized(
          context,
          en: 'From $owner • This share could not be verified and was not opened.',
          ru: 'От $owner • Этот доступ не прошёл проверку и не был открыт.',
        ),
        null,
      ),
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(
        view.folderName ??
            _localized(context, en: 'Shared folder', ru: 'Общая папка'),
      ),
      subtitle: Text(subtitle),
      trailing: action,
      onTap: view.state == IncomingShareState.ready ? onOpen : null,
    );
  }

  Future<void> _verifyOwner(BuildContext context) async {
    final fingerprint = view.ownerFingerprint;
    if (fingerprint == null) return;
    final confirmed = await _confirmFingerprint(
      context,
      title: _localized(
        context,
        en: 'Verify ${view.share.ownerUsername}',
        ru: 'Проверка ${view.share.ownerUsername}',
      ),
      explanation: _localized(
        context,
        en:
            'Ask ${view.share.ownerUsername} to open Family in HomeBox and read out their account fingerprint. '
            'It must match this one exactly.',
        ru:
            'Попросите ${view.share.ownerUsername} открыть раздел «Семья» в HomeBox и зачитать отпечаток аккаунта. '
            'Он должен полностью совпадать с этим.',
      ),
      fingerprint: fingerprint,
    );
    if (confirmed) await controller.trustOwner(view);
  }
}

final class _OutgoingShareTile extends StatelessWidget {
  const _OutgoingShareTile({required this.view, required this.controller});

  final OutgoingShareView view;
  final FamilyVaultController controller;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.folder_shared),
    title: Text(view.folderName),
    subtitle: Text(
      '${view.share.targetUsername} • ${_permissionLabel(context, view.share.permission)}'
      '${view.recipientTrusted ? '' : _localized(context, en: ' • Not verified on this device', ru: ' • не проверен на этом устройстве')}',
    ),
    trailing: PopupMenuButton<String>(
      tooltip: _localized(context, en: 'More actions', ru: 'Другие действия'),
      enabled: !controller.busy,
      onSelected: (value) => switch (value) {
        'deliver' => _deliver(context),
        'revoke' => _revoke(context),
        _ => null,
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'deliver',
          child: Text(
            view.recipientTrusted
                ? _localized(
                    context,
                    en: 'Give access to new devices',
                    ru: 'Дать доступ новым устройствам',
                  )
                : _localized(
                    context,
                    en: 'Verify and give access to new devices…',
                    ru: 'Проверить и дать доступ новым устройствам…',
                  ),
          ),
        ),
        PopupMenuItem(
          value: 'revoke',
          child: Text(
            _localized(context, en: 'Remove access…', ru: 'Закрыть доступ…'),
          ),
        ),
      ],
    ),
  );

  Future<void> _deliver(BuildContext context) async {
    RecipientCandidate? candidate;
    if (!view.recipientTrusted) {
      candidate = await controller.lookupRecipient(view.share.targetUserId);
      if (candidate == null || !context.mounted) return;
      final confirmed = await _confirmFingerprint(
        context,
        title: _localized(
          context,
          en: 'Verify ${view.share.targetUsername}',
          ru: 'Проверка ${view.share.targetUsername}',
        ),
        explanation: _localized(
          context,
          en: 'Ask ${view.share.targetUsername} to read out the account fingerprint shown in Family on their device.',
          ru: 'Попросите ${view.share.targetUsername} зачитать отпечаток аккаунта из раздела «Семья» на своём устройстве.',
        ),
        fingerprint: candidate.fingerprint,
      );
      if (!confirmed) return;
    }
    await controller.deliverKeys(view, candidate: candidate);
  }

  Future<void> _revoke(BuildContext context) =>
      _confirmAndRevoke(context, controller, view);
}

/// Asks before removing a member, then removes them and rotates the key.
Future<void> _confirmAndRevoke(
  BuildContext context,
  FamilyVaultController controller,
  OutgoingShareView view,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        _localized(
          context,
          en: 'Remove ${view.share.targetUsername}?',
          ru: 'Закрыть доступ для ${view.share.targetUsername}?',
        ),
      ),
      content: Text(
        _localized(
          context,
          en:
              'They lose access to this folder immediately and HomeBox switches the folder to a new key, '
              'so they cannot read anything added from now on. Files they already opened or downloaded '
              'cannot be taken back.',
          ru:
              'Доступ к папке пропадёт сразу, а HomeBox переведёт папку на новый ключ, '
              'поэтому новые файлы будут недоступны. Уже открытые или скачанные файлы '
              'вернуть нельзя.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            _localized(context, en: 'Remove access', ru: 'Закрыть доступ'),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.revoke(view);
}

/// Asks the user to confirm they compared [fingerprint] out of band.
Future<bool> _confirmFingerprint(
  BuildContext context, {
  required String title,
  required String explanation,
  required String fingerprint,
}) async {
  var compared = false;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(explanation),
            const SizedBox(height: 12),
            _FingerprintText(fingerprint),
            if (_canScanQr) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  if (await _scanAndMatchFamilyFingerprint(
                        context,
                        fingerprint,
                      ) &&
                      context.mounted) {
                    Navigator.pop(context, true);
                  }
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  _localized(
                    context,
                    en: 'Scan their QR code instead',
                    ru: 'Отсканировать их QR-код',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: compared,
              onChanged: (value) => setState(() => compared = value ?? false),
              title: Text(
                _localized(
                  context,
                  en: 'Every group matches',
                  ru: 'Все группы совпадают',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: compared ? () => Navigator.pop(context, true) : null,
            child: Text(_localized(context, en: 'Trust', ru: 'Доверять')),
          ),
        ],
      ),
    ),
  );
  return result == true;
}

/// Shares [folderId] with a family member: account ID and permission, a
/// fingerprint comparison the first time, then the actual key exchange.
/// Also lists and removes the folder's current members.
Future<void> _showShareFolderDialog(
  BuildContext context,
  FamilyVaultController controller, {
  required String folderId,
  required String folderName,
}) async {
  controller.clearMessages();
  final accountController = TextEditingController();
  var permission = transport.SharePermission.read;
  RecipientCandidate? candidate;
  var compared = false;
  var looking = false;
  // From a scanned family QR code: checked against what the server returns.
  String? scannedFingerprint;
  var verifiedByQr = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => StatefulBuilder(
        builder: (context, setState) {
          final members = controller.sharesOf(folderId);
          final working = controller.busy || looking;
          Future<void> find() async {
            setState(() => looking = true);
            final found = await controller.lookupRecipient(
              accountController.text,
            );
            setState(() {
              looking = false;
              candidate = found;
              compared = found?.alreadyTrusted ?? false;
              final scanned = scannedFingerprint;
              verifiedByQr =
                  found != null &&
                  scanned != null &&
                  fingerprintsMatch(scanned, found.fingerprint);
              if (verifiedByQr) compared = true;
            });
            final scanned = scannedFingerprint;
            if (found != null &&
                scanned != null &&
                !verifiedByQr &&
                context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _localized(
                      context,
                      en: 'The scanned fingerprint does not match this account. Do not share until the fingerprints match.',
                      ru: 'Отсканированный отпечаток не совпадает с этим аккаунтом. Не делитесь, пока отпечатки не совпадут.',
                    ),
                  ),
                ),
              );
            }
          }

          Future<void> scan() async {
            final raw = await _scanQrCode(context);
            if (raw == null || !context.mounted) return;
            final invite = FamilyInvite.tryParse(raw);
            if (invite == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _localized(
                      context,
                      en: 'That is not a HomeBox family QR code.',
                      ru: 'Это не семейный QR-код HomeBox.',
                    ),
                  ),
                ),
              );
              return;
            }
            accountController.text = invite.accountId;
            scannedFingerprint = invite.fingerprint;
            await find();
          }

          Future<void> share() async {
            final target = candidate;
            if (target == null) return;
            final ok = await controller.shareFolder(
              folderId: folderId,
              candidate: target,
              permission: permission,
            );
            if (ok) {
              setState(() {
                candidate = null;
                compared = false;
                accountController.clear();
              });
            }
          }

          return AlertDialog(
            title: Text(
              _localized(
                context,
                en: 'Share "$folderName"',
                ru: 'Доступ к «$folderName»',
              ),
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _localized(
                        context,
                        en:
                            'Everything in this folder is encrypted with its own key, '
                            'which only the members you add receive. The server never sees it.',
                        ru:
                            'Всё в этой папке шифруется её собственным ключом, '
                            'который получают только добавленные вами участники. Сервер его не видит.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (members.isNotEmpty) ...[
                      Text(
                        _localized(context, en: 'Members', ru: 'Участники'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final member in members)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline),
                          title: Text(member.share.targetUsername),
                          subtitle: Text(
                            _permissionLabel(context, member.share.permission),
                          ),
                          trailing: IconButton(
                            tooltip: _localized(
                              context,
                              en: 'Remove access',
                              ru: 'Закрыть доступ',
                            ),
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: working
                                ? null
                                : () => _confirmAndRevoke(
                                    context,
                                    controller,
                                    member,
                                  ),
                          ),
                        ),
                      const Divider(),
                    ],
                    TextField(
                      controller: accountController,
                      enabled: !working && candidate == null,
                      decoration: InputDecoration(
                        labelText: _localized(
                          context,
                          en: 'Family member\'s account ID',
                          ru: 'ID аккаунта члена семьи',
                        ),
                        helperText: _localized(
                          context,
                          en: 'They find it under Family → Your family identity.',
                          ru: 'Он указан в разделе «Семья → Ваш семейный идентификатор».',
                        ),
                      ),
                      // A typed ID no longer comes from the scanned code.
                      onChanged: (_) => scannedFingerprint = null,
                      onSubmitted: (_) => find(),
                    ),
                    if (_canScanQr && candidate == null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: working ? null : () => unawaited(scan()),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: Text(
                            _localized(
                              context,
                              en: 'Scan their QR code',
                              ru: 'Отсканировать их QR-код',
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: transport.SharePermission.read,
                          label: Text(
                            _permissionLabel(
                              context,
                              transport.SharePermission.read,
                            ),
                          ),
                          icon: const Icon(Icons.visibility_outlined),
                        ),
                        ButtonSegment(
                          value: transport.SharePermission.readWrite,
                          label: Text(
                            _permissionLabel(
                              context,
                              transport.SharePermission.readWrite,
                            ),
                          ),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                      selected: {permission},
                      onSelectionChanged: working
                          ? null
                          : (value) => setState(() => permission = value.first),
                    ),
                    if (candidate != null && !candidate!.alreadyTrusted) ...[
                      const SizedBox(height: 16),
                      Text(
                        _localized(
                          context,
                          en:
                              'Ask the family member to read out the account fingerprint shown in Family on their device. '
                              'It must match exactly; otherwise someone could be intercepting the share.',
                          ru:
                              'Попросите члена семьи зачитать отпечаток аккаунта из раздела «Семья» на его устройстве. '
                              'Он должен совпасть полностью, иначе доступ может быть перехвачен.',
                        ),
                      ),
                      const SizedBox(height: 8),
                      _FingerprintText(candidate!.fingerprint),
                      if (verifiedByQr)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.verified_outlined,
                                size: 18,
                                color: _successColor(context),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _localized(
                                    context,
                                    en: 'Verified by the scanned QR code.',
                                    ru: 'Проверено по отсканированному QR-коду.',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: compared,
                        onChanged: working
                            ? null
                            : (value) =>
                                  setState(() => compared = value ?? false),
                        title: Text(
                          _localized(
                            context,
                            en: 'Every group matches',
                            ru: 'Все группы совпадают',
                          ),
                        ),
                      ),
                    ],
                    if (candidate != null && candidate!.alreadyTrusted)
                      Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          _localized(
                            context,
                            en: 'You verified this family member on this device before.',
                            ru: 'Вы уже проверяли этого члена семьи на этом устройстве.',
                          ),
                        ),
                      ),
                    if (working) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                      if (controller.busyMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(controller.busyMessage!),
                        ),
                    ],
                    if (controller.errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        controller.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (controller.noticeMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(controller.noticeMessage!),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: working ? null : () => Navigator.pop(dialogContext),
                child: Text(_localized(context, en: 'Close', ru: 'Закрыть')),
              ),
              if (candidate == null)
                FilledButton(
                  onPressed: working ? null : find,
                  child: Text(_localized(context, en: 'Find', ru: 'Найти')),
                )
              else
                FilledButton(
                  onPressed: working || !compared ? null : share,
                  child: Text(
                    _localized(context, en: 'Share', ru: 'Поделиться'),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
  accountController.dispose();
}

/// An opened folder shared with this account.
final class _SharedFolderView extends StatelessWidget {
  const _SharedFolderView({
    required this.browser,
    required this.androidFileSaver,
    required this.onClose,
  });

  final SharedFolderBrowser browser;
  final AndroidFileSaver? androidFileSaver;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: browser,
    builder: (context, _) {
      final crumbs = browser.breadcrumbNames;
      final selecting = browser.selectionMode;
      return PopScope(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) browser.clearSelection();
        },
        child: _PageFrame(
          title: browser.rootName,
          subtitle: _localized(
            context,
            en: 'Shared by ${browser.share.ownerUsername} • ${_permissionLabel(context, browser.share.permission)}',
            ru: 'Владелец: ${browser.share.ownerUsername} • ${_permissionLabel(context, browser.share.permission)}',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting)
                _SharedSelectionBar(
                  browser: browser,
                  onMove: () => _moveSelected(context),
                  onDownload: () => _downloadSelected(context),
                  onDelete: () => _deleteSelected(context),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                      label: Text(
                        _localized(context, en: 'Close', ru: 'Закрыть'),
                      ),
                    ),
                    if (browser.canGoUp)
                      OutlinedButton.icon(
                        onPressed: browser.goUp,
                        icon: const Icon(Icons.arrow_upward),
                        label: Text(_localized(context, en: 'Up', ru: 'Вверх')),
                      ),
                    if (browser.canWrite) ...[
                      FilledButton.icon(
                        onPressed: browser.busy ? null : () => _upload(context),
                        icon: const Icon(Icons.upload_file),
                        label: Text(
                          _localized(
                            context,
                            en: 'Upload files',
                            ru: 'Загрузить файлы',
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: browser.busy
                            ? null
                            : () => _createFolder(context),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(
                          _localized(
                            context,
                            en: 'New folder',
                            ru: 'Новая папка',
                          ),
                        ),
                      ),
                    ],
                    if (browser.entries.isNotEmpty)
                      IconButton(
                        tooltip: _localized(
                          context,
                          en: 'Select',
                          ru: 'Выбрать',
                        ),
                        onPressed: browser.startSelection,
                        icon: const Icon(Icons.checklist),
                      ),
                    IconButton(
                      tooltip: _localized(
                        context,
                        en: 'Refresh',
                        ru: 'Обновить',
                      ),
                      onPressed: browser.refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Wrap(
                children: [
                  for (final (index, name) in crumbs.indexed) ...[
                    if (index > 0) const Text(' / '),
                    InkWell(
                      onTap: () => browser.goToBreadcrumb(index),
                      child: Text(
                        name,
                        style: index == crumbs.length - 1
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
              if (browser.busy || browser.loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(
                    value: browser.busy ? browser.progress : null,
                  ),
                ),
              if (browser.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    browser.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: browser.entries.isEmpty && !browser.loading
                    ? _FilesMessageState(
                        icon: Icons.folder_open_outlined,
                        message: _localized(
                          context,
                          en: 'This folder is empty.',
                          ru: 'Папка пуста.',
                        ),
                      )
                    : ListView.separated(
                        itemCount: browser.entries.length,
                        separatorBuilder: (context, _) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = browser.entries[index];
                          final selected = browser.isSelected(entry);
                          return ListTile(
                            selected: selecting && selected,
                            leading: selecting
                                ? SizedBox.square(
                                    dimension: _fileListLeadingSize,
                                    child: Checkbox(
                                      value: selected,
                                      onChanged: (_) =>
                                          browser.toggleSelection(entry),
                                    ),
                                  )
                                : entry.isDirectory
                                ? _folderListIcon(context, shared: false)
                                : _fileTypeListIcon(context, entry.name),
                            title: Text(entry.name),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(
                                    _formatFileSize(
                                      context,
                                      entry.metadata.plaintextSize ?? 0,
                                    ),
                                  ),
                            onTap: selecting
                                ? () => browser.toggleSelection(entry)
                                : entry.isDirectory
                                ? () => browser.open(entry)
                                : () => _download(context, entry),
                            onLongPress: () => browser.toggleSelection(entry),
                            trailing: selecting
                                ? null
                                : PopupMenuButton<String>(
                                    tooltip: _localized(
                                      context,
                                      en: 'More actions',
                                      ru: 'Другие действия',
                                    ),
                                    enabled: !browser.busy,
                                    onSelected: (value) => switch (value) {
                                      'save_as' => _download(context, entry),
                                      'replace' => _replace(context, entry),
                                      'rename' => _rename(context, entry),
                                      'delete' => _delete(context, entry),
                                      _ => null,
                                    },
                                    itemBuilder: (context) => [
                                      if (!entry.isDirectory)
                                        PopupMenuItem(
                                          value: 'save_as',
                                          child: Text(
                                            _localized(
                                              context,
                                              en: 'Save as…',
                                              ru: 'Сохранить как…',
                                            ),
                                          ),
                                        ),
                                      if (browser.canWrite &&
                                          !entry.isDirectory)
                                        PopupMenuItem(
                                          value: 'replace',
                                          child: Text(
                                            _localized(
                                              context,
                                              en: 'Replace content…',
                                              ru: 'Заменить содержимое…',
                                            ),
                                          ),
                                        ),
                                      if (browser.canWrite)
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text(
                                            _localized(
                                              context,
                                              en: 'Rename',
                                              ru: 'Переименовать',
                                            ),
                                          ),
                                        ),
                                      if (browser.canWrite)
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            _localized(
                                              context,
                                              en: 'Move to trash',
                                              ru: 'В корзину',
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _moveSelected(BuildContext context) async {
    final entries = browser.selectedEntries;
    if (entries.isEmpty) return;
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
      rootName: browser.rootName,
      rootId: browser.share.nodeId,
      // The picker starts at the shared folder, never the member's root.
      loadChildren: (folderId) =>
          browser.folderChoices(folderId ?? browser.share.nodeId),
      excludedIds: {
        for (final entry in entries)
          if (entry.isDirectory) entry.node.id,
      },
    );
    if (target == null || !context.mounted) return;
    final moved = await browser.moveEntries(
      entries,
      target.id ?? browser.share.nodeId,
    );
    if (context.mounted) {
      _reportBulk(
        context,
        moved,
        entries.length,
        _localized(context, en: 'Moved', ru: 'Перемещено'),
      );
    }
  }

  Future<void> _downloadSelected(BuildContext context) => _bulkDownload(
    context,
    run: ({String? directory, String? zipPath}) => browser.downloadEntries(
      browser.selectedEntries,
      directory: directory,
      zipPath: zipPath,
    ),
    errorMessage: () => browser.errorMessage,
    androidFileSaver: androidFileSaver,
  );

  Future<void> _deleteSelected(BuildContext context) async {
    final entries = browser.selectedEntries;
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          entries.length == 1
              ? _localized(
                  context,
                  en: 'Move "${entries.single.name}" to Trash?',
                  ru: 'Переместить «${entries.single.name}» в корзину?',
                )
              : _localized(
                  context,
                  en: 'Move ${_itemCount(context, entries.length)} to Trash?',
                  ru: 'Переместить в корзину ${_itemCount(context, entries.length)}?',
                ),
        ),
        content: Text(
          _localized(
            context,
            en: 'They move to ${browser.share.ownerUsername}\'s Trash, where they can restore them.',
            ru: 'Они попадут в корзину пользователя ${browser.share.ownerUsername}, откуда их можно восстановить.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _localized(context, en: 'Move to trash', ru: 'В корзину'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final deleted = await browser.deleteEntries(entries);
    if (context.mounted) {
      _reportBulk(
        context,
        deleted,
        entries.length,
        _localized(context, en: 'Moved to Trash', ru: 'В корзину перемещено'),
      );
    }
  }

  void _reportBulk(BuildContext context, int done, int total, String verb) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done == total
              ? '$verb: ${_itemCount(context, done)}.'
              : _localized(
                  context,
                  en: '$verb $done of ${_itemCount(context, total)}. ${browser.errorMessage ?? ''}',
                  ru: '$verb $done из ${_itemCount(context, total)}. ${browser.errorMessage ?? ''}',
                ).trim(),
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context, SharedEntry entry) async {
    final saver = androidFileSaver;
    if (saver != null) {
      final tempDir = await getTemporaryDirectory();
      final temp = File('${tempDir.path}/shared_${entry.node.id}');
      try {
        if (!await browser.download(entry, temp.path)) return;
        await saver.saveFile(
          sourcePath: temp.path,
          suggestedName: entry.name,
          mimeType: entry.metadata.mimeType,
        );
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      return;
    }
    final destination = await getSaveLocation(suggestedName: entry.name);
    if (destination == null) return;
    final ok = await browser.download(entry, destination.path);
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _localized(
              context,
              en: 'Saved ${entry.name}.',
              ru: 'Сохранено: ${entry.name}.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _upload(BuildContext context) async {
    final files = await openFiles();
    if (files.isEmpty) return;
    await browser.uploadFiles(files.map((file) => file.path).toList());
  }

  Future<void> _replace(BuildContext context, SharedEntry entry) async {
    final file = await openFile();
    if (file == null) return;
    await browser.replaceContent(entry, file.path);
  }

  Future<void> _createFolder(BuildContext context) async {
    final name = await _askName(
      context,
      title: _localized(context, en: 'New folder', ru: 'Новая папка'),
      confirm: _localized(context, en: 'Create', ru: 'Создать'),
      initial: '',
    );
    if (name != null) await browser.createFolder(name);
  }

  Future<void> _rename(BuildContext context, SharedEntry entry) async {
    final name = await _askName(
      context,
      title: _localized(context, en: 'Rename', ru: 'Переименовать'),
      confirm: _localized(context, en: 'Rename', ru: 'Переименовать'),
      initial: entry.name,
    );
    if (name != null && name != entry.name) await browser.rename(entry, name);
  }

  Future<void> _delete(BuildContext context, SharedEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Move "${entry.name}" to trash?',
            ru: 'Переместить «${entry.name}» в корзину?',
          ),
        ),
        content: Text(
          _localized(
            context,
            en: 'It moves to ${browser.share.ownerUsername}\'s Trash, where they can restore it.',
            ru: 'Элемент попадёт в корзину пользователя ${browser.share.ownerUsername}, откуда его можно восстановить.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _localized(context, en: 'Move to trash', ru: 'В корзину'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await browser.delete(entry);
  }
}

/// Asks for a file or folder name. Returns the trimmed name, or null when
/// cancelled or left empty. When renaming, the part before the extension is
/// preselected, so typing replaces the name but keeps ".jpg".
Future<String?> _askName(
  BuildContext context, {
  required String title,
  required String initial,
  String? label,
  String? confirm,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(
      title: title,
      initial: initial,
      label: label ?? _localized(context, en: 'Name', ru: 'Имя'),
      confirm: confirm ?? _localized(context, en: 'OK', ru: 'OK'),
    ),
  );
  final name = result?.trim();
  return name == null || name.isEmpty ? null : name;
}

final class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.confirm,
  });

  final String title;
  final String initial;
  final String label;
  final String confirm;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

final class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final dot = initial.lastIndexOf('.');
    _controller = TextEditingController(text: initial)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: dot > 0 ? dot : initial.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(widget.confirm),
      ),
    ],
  );
}

// The selection toolbar of an opened shared folder. Moving and trashing
/// need "Can edit"; downloading works for every member.
final class _SharedSelectionBar extends StatelessWidget {
  const _SharedSelectionBar({
    required this.browser,
    required this.onMove,
    required this.onDownload,
    required this.onDelete,
  });

  final SharedFolderBrowser browser;
  final VoidCallback onMove;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final count = browser.selectedCount;
    final total = browser.entries.length;
    final idle = count > 0 && !browser.busy;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Checkbox(
          tristate: true,
          value: count == 0 ? false : (count == total ? true : null),
          onChanged: (_) => browser.toggleSelectAll(),
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
        OutlinedButton.icon(
          onPressed: idle ? onDownload : null,
          icon: const Icon(Icons.download_outlined),
          label: Text(_localized(context, en: 'Download', ru: 'Скачать')),
        ),
        if (browser.canWrite) ...[
          OutlinedButton.icon(
            onPressed: idle ? onMove : null,
            icon: const Icon(Icons.drive_file_move_outline),
            label: Text(
              _localized(context, en: 'Move to…', ru: 'Переместить…'),
            ),
          ),
          FilledButton.icon(
            onPressed: idle ? onDelete : null,
            icon: const Icon(Icons.delete_outline),
            label: Text(
              _localized(context, en: 'Move to trash', ru: 'В корзину'),
            ),
          ),
        ],
        TextButton(
          onPressed: browser.clearSelection,
          child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
        ),
      ],
    );
  }
}
