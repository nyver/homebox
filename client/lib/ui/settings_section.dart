part of '../main.dart';

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.deviceSetupController,
    required this.deviceProvisioningController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.recoveryController,
    required this.onVaultProvisioned,
    required this.localeController,
    required this.themeController,
  });

  final DeviceSetupController deviceSetupController;
  final DeviceProvisioningController deviceProvisioningController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final RecoveryController recoveryController;
  final Future<void> Function() onVaultProvisioned;
  final AppLocaleController localeController;
  final AppThemeController themeController;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: _localized(context, en: 'Settings', ru: 'Настройки'),
    subtitle: _localized(
      context,
      en: 'Account, device security and app preferences.',
      ru: 'Аккаунт, безопасность устройства и параметры приложения.',
    ),
    child: ListView(
      children: [
        _SettingsGroupHeading(
          _localized(context, en: 'Account', ru: 'Аккаунт'),
        ),
        _ServerConnectionCard(controller: serverConnectionController),
        _SettingsGroupHeading(
          _localized(
            context,
            en: 'Devices and encryption',
            ru: 'Устройства и шифрование',
          ),
        ),
        _DeviceIdentityCard(controller: deviceSetupController),
        _DeviceProvisioningCard(
          controller: deviceProvisioningController,
          deviceSetupController: deviceSetupController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
          onVaultProvisioned: onVaultProvisioned,
        ),
        _AccountDevicesCard(
          controller: deviceProvisioningController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
        ),
        _VaultSetupCard(
          controller: vaultSetupController,
          serverConnectionController: serverConnectionController,
          deviceProvisioningController: deviceProvisioningController,
          recoveryController: recoveryController,
          onVaultProvisioned: onVaultProvisioned,
        ),
        _RecoveryCard(
          controller: recoveryController,
          serverConnectionController: serverConnectionController,
          vaultSetupController: vaultSetupController,
        ),
        _SettingsGroupHeading(
          _localized(context, en: 'Application', ru: 'Приложение'),
        ),
        _LanguageCard(controller: localeController),
        _ThemeCard(controller: themeController),
        // Autostart is a Windows sign-in feature; elsewhere it would only
        // be a disabled switch explaining that it does not apply.
        if (defaultTargetPlatform == TargetPlatform.windows)
          const _AutostartCard(),
      ],
    ),
  );
}

final class _SettingsGroupHeading extends StatelessWidget {
  const _SettingsGroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

final class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.controller});

  final AppThemeController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Card(
      child: ListTile(
        leading: const Icon(Icons.dark_mode_outlined),
        title: Text(_localized(context, en: 'Theme', ru: 'Тема')),
        subtitle: Text(
          _localized(
            context,
            en: 'Light, dark, or follow the system setting.',
            ru: 'Светлая, тёмная или как в системе.',
          ),
        ),
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<ThemeMode>(
            value: controller.mode,
            onChanged: (mode) {
              if (mode != null) unawaited(controller.setMode(mode));
            },
            items: [
              DropdownMenuItem(
                value: ThemeMode.system,
                child: Text(_localized(context, en: 'System', ru: 'Системная')),
              ),
              DropdownMenuItem(
                value: ThemeMode.light,
                child: Text(_localized(context, en: 'Light', ru: 'Светлая')),
              ),
              DropdownMenuItem(
                value: ThemeMode.dark,
                child: Text(_localized(context, en: 'Dark', ru: 'Тёмная')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _LanguageCard extends StatelessWidget {
  const _LanguageCard({required this.controller});

  final AppLocaleController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.language_outlined),
          title: Text(_localized(context, en: 'Language', ru: 'Язык')),
          subtitle: Text(
            _localized(
              context,
              en: 'Choose the application interface language.',
              ru: 'Выберите язык интерфейса приложения.',
            ),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<AppLanguage>(
              value: controller.language,
              onChanged: (language) {
                if (language != null) {
                  unawaited(controller.setLanguage(language));
                }
              },
              items: const [
                DropdownMenuItem(
                  value: AppLanguage.english,
                  child: Text('English'),
                ),
                DropdownMenuItem(
                  value: AppLanguage.russian,
                  child: Text('Русский'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

final class _DeviceProvisioningCard extends StatelessWidget {
  const _DeviceProvisioningCard({
    required this.controller,
    required this.deviceSetupController,
    required this.serverConnectionController,
    required this.vaultSetupController,
    required this.onVaultProvisioned,
  });

  final DeviceProvisioningController controller;
  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;
  final Future<void> Function() onVaultProvisioned;

  Future<void> _addDevice(BuildContext context) async {
    final devices = await controller.availableRecipientDevices();
    if (!context.mounted) return;
    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.errorMessage ?? 'No other active device is registered yet. Sign in on the new device first.',
          ),
        ),
      );
      return;
    }
    final target = await showDialog<transport.HomeBoxDevice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a device to approve'),
        content: SizedBox(
          width: 420,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: devices.length,
            separatorBuilder: (context, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final device = devices[index];
              return ListTile(
                leading: Icon(
                  device.platform == 'ANDROID'
                      ? Icons.phone_android_outlined
                      : Icons.desktop_windows_outlined,
                ),
                title: Text('${device.name} (${_deviceCode(device.id)})'),
                subtitle: Text(
                  '${device.platform} · Last seen ${device.lastSeenAt.toLocal()}',
                ),
                onTap: () => Navigator.pop(context, device),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!context.mounted || target == null) return;
    final targetFingerprint = await devicePublicKeyFingerprint(
      target.publicKey,
    );
    if (!context.mounted) return;
    var fingerprintVerified = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Verify and approve device'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'On ${target.name}, open Settings → This device. Compare the full pairing fingerprint before sharing the vault key.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  targetFingerprint,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: fingerprintVerified,
                  onChanged: (value) => setDialogState(
                    () => fingerprintVerified = value ?? false,
                  ),
                  title: const Text(
                    'The fingerprint exactly matches the new device',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: fingerprintVerified
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Sign and approve'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final approved = await controller.provisionDevice(
      target,
      fingerprintVerified: fingerprintVerified,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approved
              ? 'Device approved. Open Settings there and choose Check approval.'
              : (controller.errorMessage ?? 'Could not approve this device.'),
        ),
      ),
    );
  }

  Future<void> _checkApproval(BuildContext context) async {
    final provisioned = await controller.collectProvisioning();
    if (provisioned) await onVaultProvisioned();
    if (!context.mounted) return;
    final message = provisioned
        ? 'This device is approved and the vault is unlocked.'
        : controller.status == DeviceProvisioningStatus.awaitingApproval
        ? 'Waiting for approval from a trusted device.'
        : (controller.errorMessage ?? 'Could not check device approval.');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      deviceSetupController,
      serverConnectionController,
      vaultSetupController,
    ]),
    builder: (context, _) {
      final signedIn =
          serverConnectionController.status ==
          ServerConnectionStatus.authenticated;
      final vaultReady = vaultSetupController.status == VaultSetupStatus.ready;
      final deviceReady =
          deviceSetupController.status == DeviceSetupStatus.ready;
      final canApproveAnother = signedIn && vaultReady;
      final canCollectApproval = signedIn && !vaultReady && deviceReady;
      final deviceCode = signedIn
          ? _deviceCode(serverConnectionController.session!.device.id)
          : null;
      final subtitle = switch (controller.status) {
        DeviceProvisioningStatus.loading =>
          'Exchanging the encrypted vault key…',
        DeviceProvisioningStatus.awaitingApproval =>
          'Waiting for a trusted device to approve this device.',
        DeviceProvisioningStatus.ready =>
          vaultReady
              ? 'This device can approve another signed-in device.'
              : 'Vault key received from a trusted device.',
        DeviceProvisioningStatus.failed =>
          controller.errorMessage ?? 'Provisioning failed.',
        DeviceProvisioningStatus.idle when !signedIn =>
          'Sign in on both devices before linking them.',
        DeviceProvisioningStatus.idle when !deviceReady =>
          'Prepare this device identity before linking it.',
        DeviceProvisioningStatus.idle when vaultReady =>
          'Approve another device that has signed in to this account.',
        DeviceProvisioningStatus.idle => 'Sign in on a trusted device, approve this one there, then check here.',
      };
      final trailing = controller.busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : canApproveAnother
          ? OutlinedButton(
              onPressed: () => _addDevice(context),
              child: const Text('Add device'),
            )
          : canCollectApproval
          ? FilledButton(
              onPressed: () => _checkApproval(context),
              child: const Text('Check approval'),
            )
          : null;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: const Text('Trusted devices'),
          subtitle: Text(
            deviceCode == null
                ? subtitle
                : '$subtitle\nDevice code: $deviceCode',
          ),
          trailing: trailing,
          isThreeLine: true,
        ),
      );
    },
  );
}

String _deviceCode(String deviceId) => deviceId.substring(0, 8).toUpperCase();

final class _AccountDevicesCard extends StatefulWidget {
  const _AccountDevicesCard({
    required this.controller,
    required this.serverConnectionController,
    required this.vaultSetupController,
  });

  final DeviceProvisioningController controller;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;

  @override
  State<_AccountDevicesCard> createState() => _AccountDevicesCardState();
}

final class _AccountDevicesCardState extends State<_AccountDevicesCard> {
  List<transport.HomeBoxDevice> _devices = const [];
  bool _loading = false;
  bool _revoking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.serverConnectionController.addListener(_onConnectionChanged);
    _onConnectionChanged();
  }

  @override
  void dispose() {
    widget.serverConnectionController.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (widget.serverConnectionController.status ==
        ServerConnectionStatus.authenticated) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    var devices = await widget.controller.accountDevices();
    if (await _selfHealOwnApproval(devices)) {
      devices = await widget.controller.accountDevices();
    }
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _error = widget.controller.errorMessage;
      _loading = false;
    });
  }

  /// A vault's creator device never goes through the normal approve/collect
  /// flow (there is no other trusted device yet to approve it), so it can
  /// show up here as pending even though it already holds the vault key
  /// locally — including vaults created before this self-approval step
  /// existed. Silently repairs that the first time this device's own vault
  /// is ready but the server has no record of it, retrying on every load
  /// until it succeeds.
  Future<bool> _selfHealOwnApproval(
    List<transport.HomeBoxDevice> devices,
  ) async {
    final selfId = widget.serverConnectionController.session?.device.id;
    if (selfId == null ||
        widget.vaultSetupController.status != VaultSetupStatus.ready) {
      return false;
    }
    transport.HomeBoxDevice? self;
    for (final device in devices) {
      if (device.id == selfId) {
        self = device;
        break;
      }
    }
    if (self == null || self.hasVaultKey) return false;
    return widget.controller.selfApprove();
  }

  Future<void> _revoke(transport.HomeBoxDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this device?'),
        content: Text(
          '${device.name} (${_deviceCode(device.id)}) will be signed out '
          'immediately and must be approved again by a trusted device before '
          'it can access the vault. This cannot retract a vault key it has '
          'already received.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoking = true);
    final revoked = await widget.controller.revokeDevice(device);
    if (!mounted) return;
    setState(() => _revoking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          revoked
              ? '${device.name} has been revoked.'
              : (widget.controller.errorMessage ??
                    'Could not revoke this device.'),
        ),
      ),
    );
    if (revoked) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn =
        widget.serverConnectionController.status ==
        ServerConnectionStatus.authenticated;
    final currentDeviceId = signedIn
        ? widget.serverConnectionController.session?.device.id
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.devices_other_outlined),
              title: const Text('Account devices'),
              subtitle: const Text(
                'Approved devices hold the vault key; pending devices are '
                'signed in but still waiting for approval.',
              ),
              trailing: IconButton(
                tooltip: 'Refresh devices',
                onPressed: !signedIn || _loading ? null : _load,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else if (signedIn && !_loading && _devices.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No other device is signed in yet.'),
                ),
              )
            else
              for (final device in _devices)
                ListTile(
                  dense: true,
                  leading: Icon(
                    device.platform == 'ANDROID'
                        ? Icons.phone_android_outlined
                        : Icons.desktop_windows_outlined,
                    color: device.hasVaultKey
                        ? _successColor(context)
                        : Theme.of(context).colorScheme.outline,
                  ),
                  title: Text(
                    '${device.name} (${_deviceCode(device.id)})'
                    '${device.id == currentDeviceId ? ' · this device' : ''}',
                  ),
                  subtitle: Row(
                    children: [
                      Icon(
                        device.hasVaultKey
                            ? Icons.check_circle_outline
                            : Icons.hourglass_empty_outlined,
                        size: 14,
                        color: device.hasVaultKey
                            ? _successColor(context)
                            : _warningColor(context),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          device.hasVaultKey
                              ? (device.lastSyncAt != null
                                    ? 'Approved · Last sync: ${_formatLocalDateTime(device.lastSyncAt!)}'
                                    : 'Approved')
                              : 'Pending approval',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  trailing: device.id == currentDeviceId
                      ? null
                      : IconButton(
                          tooltip: 'Revoke device',
                          onPressed: _revoking ? null : () => _revoke(device),
                          icon: const Icon(Icons.block_outlined),
                        ),
                ),
          ],
        ),
      ),
    );
  }
}

String _formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

final class _AutostartCard extends StatefulWidget {
  const _AutostartCard();

  @override
  State<_AutostartCard> createState() => _AutostartCardState();
}

final class _AutostartCardState extends State<_AutostartCard> {
  final WindowsAutostart _autostart = WindowsAutostart();
  bool? _enabled;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _autostart.enabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  Future<void> _set(bool value) async {
    setState(() => _loading = true);
    final enabled = await _autostart.setEnabled(value);
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: SwitchListTile(
      secondary: const Icon(Icons.rocket_launch_outlined),
      title: const Text('Start HomeBox with Windows'),
      subtitle: Text(
        _enabled == null
            ? 'Available in the Windows desktop build.'
            : 'Uses your current Windows account only.',
      ),
      value: _enabled ?? false,
      onChanged: _loading || _enabled == null ? null : _set,
    ),
  );
}

final class _DeviceIdentityCard extends StatelessWidget {
  const _DeviceIdentityCard({required this.controller});

  final DeviceSetupController controller;

  Future<void> _confirmPreparation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Prepare this device?'),
        content: Text(
          _localized(
            context,
            en:
                'HomeBox will create this device\'s own encryption key and keep it in the system\'s secure storage. '
                'It does not unlock your files until a trusted device or your Recovery Secret approves it.',
            ru:
                'HomeBox создаст собственный ключ шифрования этого устройства и сохранит его в защищённом хранилище системы. '
                'Файлы станут доступны только после подтверждения с доверенного устройства или по Recovery Secret.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create identity'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.prepareDevice();
  }

  Future<void> _copyFingerprint(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Device fingerprint copied.')));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final fingerprint = controller.publicKeyFingerprint;
      final subtitle = switch (controller.status) {
        DeviceSetupStatus.checking => 'Checking secure storage…',
        DeviceSetupStatus.missing =>
          'No device identity. Create one before requesting provisioning.',
        DeviceSetupStatus.creating => _localized(
          context,
          en: 'Creating this device\'s key…',
          ru: 'Создание ключа устройства…',
        ),
        DeviceSetupStatus.ready =>
          'Identity ready · Not provisioned\nFingerprint: $fingerprint',
        DeviceSetupStatus.failed =>
          'Secure storage is unavailable or contains invalid data.',
      };
      final trailing = switch (controller.status) {
        DeviceSetupStatus.checking ||
        DeviceSetupStatus.creating => const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        DeviceSetupStatus.missing => FilledButton(
          key: const ValueKey('prepare-device'),
          onPressed: () => _confirmPreparation(context),
          child: const Text('Prepare device'),
        ),
        DeviceSetupStatus.ready => IconButton(
          tooltip: 'Copy public-key fingerprint',
          onPressed: fingerprint == null
              ? null
              : () => _copyFingerprint(context, fingerprint),
          icon: const Icon(Icons.copy_outlined),
        ),
        DeviceSetupStatus.failed => TextButton(
          onPressed: controller.initialize,
          child: const Text('Retry'),
        ),
      };
      return Card(
        child: ListTile(
          leading: const Icon(Icons.devices_other_outlined),
          title: const Text('This device'),
          subtitle: Text(subtitle),
          trailing: trailing,
          isThreeLine: controller.status == DeviceSetupStatus.ready,
        ),
      );
    },
  );
}

final class _ServerConnectionCard extends StatelessWidget {
  const _ServerConnectionCard({required this.controller});

  final ServerConnectionController controller;

  Future<void> _promptForServer(BuildContext context) async {
    final urlController = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to a HomeBox server'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'homebox.local:8787',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, urlController.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (entered == null || entered.trim().isEmpty) return;
    await controller.discover(entered);
    // Shown from here, once per discovery, rather than from build(): a
    // rebuild while awaiting trust must not stack a second dialog.
    final fingerprint = controller.discoveredFingerprint;
    if (!context.mounted ||
        controller.status != ServerConnectionStatus.awaitingTrust ||
        fingerprint == null) {
      return;
    }
    await _confirmFingerprint(context, fingerprint);
  }

  Future<void> _confirmForget(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Forget this server?',
            ru: 'Забыть этот сервер?',
          ),
        ),
        content: Text(
          _localized(
            context,
            en:
                'This device signs out and forgets the server\'s verified identity. '
                'To reconnect you will have to verify its fingerprint and sign in again. '
                'Files on the server are not affected.',
            ru:
                'Устройство выйдет из аккаунта и забудет проверенный отпечаток сервера. '
                'Для повторного подключения придётся снова сверить отпечаток и войти. '
                'Файлы на сервере не пострадают.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_localized(context, en: 'Forget', ru: 'Забыть')),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.forgetServer();
  }

  Future<void> _confirmFingerprint(
    BuildContext context,
    String fingerprint,
  ) async {
    final trust = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify server identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Compare this fingerprint with the one printed by "homebox server fingerprint" '
              'on the server, over a channel you trust, before continuing.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              fingerprint,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Trust this server'),
          ),
        ],
      ),
    );
    if (trust == true) {
      await controller.confirmTrust();
    } else {
      controller.cancelTrust();
    }
  }

  Future<void> _promptForLogin(BuildContext context) async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (submitted == true) {
      await controller.login(usernameController.text, passwordController.text);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final cards = <Widget>[
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(controller.server?.baseUrl ?? 'Not connected'),
            trailing: switch (controller.status) {
              ServerConnectionStatus.discovering ||
              ServerConnectionStatus.authenticating => const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              ServerConnectionStatus.disconnected ||
              ServerConnectionStatus.failed => FilledButton(
                onPressed: () => _promptForServer(context),
                child: const Text('Connect'),
              ),
              _ => TextButton(
                onPressed: () => _confirmForget(context),
                child: Text(_localized(context, en: 'Forget', ru: 'Забыть')),
              ),
            },
          ),
        ),
      ];

      if (controller.status == ServerConnectionStatus.failed &&
          controller.errorMessage != null) {
        cards.add(
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: const Text('Connection failed'),
              subtitle: Text(controller.errorMessage!),
            ),
          ),
        );
      }

      if (controller.status == ServerConnectionStatus.connectedLoggedOut ||
          controller.status == ServerConnectionStatus.authenticated) {
        final session = controller.session;
        cards.add(
          Card(
            child: ListTile(
              leading: Icon(
                session != null
                    ? Icons.verified_user_outlined
                    : Icons.person_outline,
              ),
              title: Text(
                session != null
                    ? 'Signed in as ${session.user.username}'
                    : 'Not signed in',
              ),
              subtitle: session == null && controller.errorMessage != null
                  ? Text(controller.errorMessage!)
                  : null,
              trailing: session != null
                  ? TextButton(
                      onPressed: () => controller.logout(),
                      child: const Text('Sign out'),
                    )
                  : FilledButton(
                      onPressed: () => _promptForLogin(context),
                      child: const Text('Sign in'),
                    ),
            ),
          ),
        );
      }

      return Column(children: cards);
    },
  );
}

final class _VaultSetupCard extends StatelessWidget {
  const _VaultSetupCard({
    required this.controller,
    required this.serverConnectionController,
    required this.deviceProvisioningController,
    required this.recoveryController,
    required this.onVaultProvisioned,
  });

  final VaultSetupController controller;
  final ServerConnectionController serverConnectionController;
  final DeviceProvisioningController deviceProvisioningController;
  final RecoveryController recoveryController;
  final Future<void> Function() onVaultProvisioned;

  Future<void> _createVault(BuildContext context) async {
    final userId = serverConnectionController.session?.user.id;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in to the server before creating a vault.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create this account\'s vault?'),
        content: const Text(
          'HomeBox generates the encryption keys that protect your files on this server, plus a Recovery Secret you must save. '
          'If every trusted device and the Recovery Secret are lost, nobody — including HomeBox — can recover your files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create vault'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final secret = await controller.createVault(userId);
    if (secret == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.errorMessage ?? 'Could not create the vault.',
            ),
          ),
        );
      }
      return;
    }
    // This device is the vault's root of trust and never goes through
    // collectProvisioning, so without this it would show as still pending
    // approval in Account devices. Best-effort: the vault itself already
    // exists and its Recovery Secret must still be shown either way.
    final selfApproved = await deviceProvisioningController.selfApprove();
    if (!context.mounted) return;
    await _showRecoverySecretDialog(context, secret);
    if (!selfApproved && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Vault created, but this device could not record its own approval: '
            '${deviceProvisioningController.errorMessage ?? 'unknown error'}. '
            'It may show as pending in Account devices until this is retried.',
          ),
        ),
      );
    }
  }

  Future<void> _restoreVault(BuildContext context) async {
    if (serverConnectionController.session == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _localized(
              context,
              en: 'Sign in to the account you want to recover first.',
              ru: 'Сначала войдите в аккаунт, который нужно восстановить.',
            ),
          ),
        ),
      );
      return;
    }
    final secretController = TextEditingController();
    final secret = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Restore with Recovery Secret',
            ru: 'Восстановить по Recovery Secret',
          ),
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _localized(
                  context,
                  en: 'Enter the Recovery Secret you saved when the vault was created. It unlocks the existing vault on this device without another trusted device.',
                  ru: 'Введите Recovery Secret, сохранённый при создании vault. Он разблокирует существующий vault на этом устройстве без другого доверенного устройства.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretController,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Recovery Secret',
                  hintText: 'HBXR1-…',
                ),
                onSubmitted: (value) => Navigator.pop(context, value),
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
            onPressed: () => Navigator.pop(context, secretController.text),
            child: Text(_localized(context, en: 'Restore', ru: 'Восстановить')),
          ),
        ],
      ),
    );
    // Not disposed here: the dialog's exit animation may still rebuild the
    // field, matching how the sign-in dialog leaves its controllers to GC.
    if (secret == null || secret.trim().isEmpty) return;
    final restored = await recoveryController.restoreVault(secret);
    if (!context.mounted) return;
    if (!restored) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            recoveryController.errorMessage ??
                _localized(
                  context,
                  en: 'Could not restore the vault.',
                  ru: 'Не удалось восстановить vault.',
                ),
          ),
        ),
      );
      return;
    }
    // Like a newly created vault, a recovered device holds the Vault Key
    // without ever having been approved, so it certifies itself.
    final selfApproved = await deviceProvisioningController.selfApprove();
    await onVaultProvisioned();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selfApproved
              ? _localized(
                  context,
                  en: 'Vault restored. This device is unlocked and approved.',
                  ru: 'Vault восстановлен. Это устройство разблокировано и подтверждено.',
                )
              : _localized(
                  context,
                  en: 'Vault restored, but this device could not record its approval: ${deviceProvisioningController.errorMessage ?? 'unknown error'}.',
                  ru: 'Vault восстановлен, но устройство не смогло записать своё подтверждение: ${deviceProvisioningController.errorMessage ?? 'неизвестная ошибка'}.',
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, recoveryController]),
    builder: (context, _) {
      final subtitle = switch (controller.status) {
        VaultSetupStatus.checking => 'Checking for an existing vault…',
        VaultSetupStatus.locked => 'No vault on this device yet. Create one here, or unlock this device from an existing trusted device / Recovery Secret.',
        VaultSetupStatus.creating => 'Creating vault keys…',
        VaultSetupStatus.ready => 'Vault ready on this device.',
        VaultSetupStatus.failed =>
          controller.errorMessage ?? 'Vault storage is unavailable.',
      };
      final restoring =
          controller.status == VaultSetupStatus.locked &&
          recoveryController.busy;
      final trailing = switch (controller.status) {
        VaultSetupStatus.checking ||
        VaultSetupStatus.creating => const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        VaultSetupStatus.locked when restoring => const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        VaultSetupStatus.locked => null,
        VaultSetupStatus.ready => const Icon(Icons.check_circle_outline),
        VaultSetupStatus.failed => TextButton(
          onPressed: controller.initialize,
          child: const Text('Retry'),
        ),
      };
      return Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.enhanced_encryption_outlined),
              title: const Text('Personal vault'),
              subtitle: Text(subtitle),
              trailing: trailing,
              isThreeLine: true,
            ),
            if (controller.status == VaultSetupStatus.locked)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: restoring
                          ? null
                          : () => _restoreVault(context),
                      icon: const Icon(Icons.key_outlined),
                      label: Text(
                        _localized(
                          context,
                          en: 'Restore with Recovery Secret',
                          ru: 'Восстановить по Recovery Secret',
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: restoring ? null : () => _createVault(context),
                      child: const Text('Create vault'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

Future<void> _showRecoverySecretDialog(BuildContext context, String secret) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        var confirmedSaved = false;
        // A single StatefulBuilder wraps the whole dialog so toggling the
        // checkbox also rebuilds the "Done" button's enabled state — two
        // separate StatefulBuilders (one per widget) would each keep their
        // own rebuild scope and never see the other's state change.
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Save your Recovery Secret'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This is shown only once. Without it — and without another trusted device — your files can never be recovered.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  secret,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: confirmedSaved,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (value) =>
                      setState(() => confirmedSaved = value ?? false),
                  title: const Text(
                    'I have saved this Recovery Secret somewhere safe.',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy'),
              ),
              FilledButton(
                onPressed: confirmedSaved ? () => Navigator.pop(context) : null,
                child: const Text('Done'),
              ),
            ],
          ),
        );
      },
    );

/// Shows whether the server holds this account's recovery bundle, uploads
/// it automatically from the device that created the vault, and lets any
/// unlocked device issue a new Recovery Secret.
final class _RecoveryCard extends StatefulWidget {
  const _RecoveryCard({
    required this.controller,
    required this.serverConnectionController,
    required this.vaultSetupController,
  });

  final RecoveryController controller;
  final ServerConnectionController serverConnectionController;
  final VaultSetupController vaultSetupController;

  @override
  State<_RecoveryCard> createState() => _RecoveryCardState();
}

final class _RecoveryCardState extends State<_RecoveryCard> {
  bool _wasAvailable = false;

  bool get _available =>
      widget.serverConnectionController.status ==
          ServerConnectionStatus.authenticated &&
      widget.vaultSetupController.status == VaultSetupStatus.ready;

  @override
  void initState() {
    super.initState();
    widget.serverConnectionController.addListener(_onPrerequisitesChanged);
    widget.vaultSetupController.addListener(_onPrerequisitesChanged);
    _onPrerequisitesChanged();
  }

  @override
  void dispose() {
    widget.serverConnectionController.removeListener(_onPrerequisitesChanged);
    widget.vaultSetupController.removeListener(_onPrerequisitesChanged);
    super.dispose();
  }

  /// Checks the server copy once each time this device becomes signed in
  /// with an unlocked vault, rather than on every connection notification.
  void _onPrerequisitesChanged() {
    final available = _available;
    if (available && !_wasAvailable) unawaited(widget.controller.refresh());
    _wasAvailable = available;
  }

  Future<void> _createNewSecret(BuildContext context) async {
    final replacing =
        widget.controller.status == RecoveryBackupStatus.protected;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Create a new Recovery Secret?',
            ru: 'Создать новый Recovery Secret?',
          ),
        ),
        content: Text(
          replacing
              ? _localized(
                  context,
                  en: 'The new secret replaces the current one: the old Recovery Secret will no longer restore this vault from the server. A server backup made earlier can still be opened with the old secret.',
                  ru: 'Новый секрет заменит текущий: старый Recovery Secret больше не восстановит vault с сервера. Ранее сделанную резервную копию сервера по-прежнему можно открыть старым секретом.',
                )
              : _localized(
                  context,
                  en: 'HomeBox stores an encrypted recovery copy on the server that only this new secret can open. Save it somewhere safe and offline.',
                  ru: 'HomeBox сохранит на сервере зашифрованную копию для восстановления, которую сможет открыть только этот новый секрет. Сохраните его в надёжном месте вне устройства.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_localized(context, en: 'Create', ru: 'Создать')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final secret = await widget.controller.createNewRecoverySecret();
    if (!context.mounted) return;
    if (secret == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.errorMessage ??
                _localized(
                  context,
                  en: 'Could not create a Recovery Secret.',
                  ru: 'Не удалось создать Recovery Secret.',
                ),
          ),
        ),
      );
      return;
    }
    await _showRecoverySecretDialog(context, secret);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.serverConnectionController,
      widget.vaultSetupController,
    ]),
    builder: (context, _) {
      if (!_available) return const SizedBox.shrink();
      final controller = widget.controller;
      final updatedAt = controller.updatedAt;
      final (icon, subtitle) = switch (controller.status) {
        RecoveryBackupStatus.unknown || RecoveryBackupStatus.checking => (
          Icons.key_outlined,
          _localized(
            context,
            en: 'Checking the recovery backup…',
            ru: 'Проверка резервной копии для восстановления…',
          ),
        ),
        RecoveryBackupStatus.protected => (
          Icons.verified_outlined,
          _localized(
            context,
            en: 'An encrypted recovery copy is stored on the server${updatedAt == null ? '' : ' (updated ${_formatLocalDateTime(updatedAt)})'}. With your Recovery Secret you can restore this vault on a new device even if every trusted device is lost.',
            ru: 'Зашифрованная копия для восстановления хранится на сервере${updatedAt == null ? '' : ' (обновлена ${_formatLocalDateTime(updatedAt)})'}. По Recovery Secret vault можно восстановить на новом устройстве, даже если потеряны все доверенные устройства.',
          ),
        ),
        RecoveryBackupStatus.unprotected => (
          Icons.warning_amber_outlined,
          _localized(
            context,
            en: 'The server has no recovery copy yet. Create a Recovery Secret so the vault can be restored without another trusted device.',
            ru: 'На сервере ещё нет копии для восстановления. Создайте Recovery Secret, чтобы vault можно было восстановить без другого доверенного устройства.',
          ),
        ),
        RecoveryBackupStatus.failed => (
          Icons.error_outline,
          controller.errorMessage ??
              _localized(
                context,
                en: 'Could not check the recovery backup.',
                ru: 'Не удалось проверить резервную копию.',
              ),
        ),
      };
      final Widget? trailing = controller.busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : switch (controller.status) {
              RecoveryBackupStatus.failed => TextButton(
                onPressed: controller.refresh,
                child: Text(_localized(context, en: 'Retry', ru: 'Повторить')),
              ),
              RecoveryBackupStatus.unprotected => FilledButton(
                onPressed: () => _createNewSecret(context),
                child: Text(
                  _localized(
                    context,
                    en: 'Create secret',
                    ru: 'Создать секрет',
                  ),
                ),
              ),
              RecoveryBackupStatus.protected => TextButton(
                onPressed: () => _createNewSecret(context),
                child: Text(
                  _localized(context, en: 'New secret', ru: 'Новый секрет'),
                ),
              ),
              _ => null,
            };
      return Card(
        child: ListTile(
          leading: Icon(icon),
          title: const Text('Recovery Secret'),
          subtitle: Text(subtitle),
          trailing: trailing,
          isThreeLine: true,
        ),
      );
    },
  );
}
