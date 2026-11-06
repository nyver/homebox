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
            controller.errorMessage ??
                _localized(
                  context,
                  en: 'No other active device is registered yet. Sign in on the new device first.',
                  ru: 'Других активных устройств пока нет. Сначала войдите в аккаунт на новом устройстве.',
                ),
          ),
        ),
      );
      return;
    }
    final target = await showDialog<transport.HomeBoxDevice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Choose a device to approve',
            ru: 'Выберите устройство для подтверждения',
          ),
        ),
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
                  _localized(
                    context,
                    en: '${device.platform} · Last seen ${device.lastSeenAt.toLocal()}',
                    ru: '${device.platform} · был в сети ${_formatLocalDateTime(device.lastSeenAt)}',
                  ),
                ),
                onTap: () => Navigator.pop(context, device),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
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
          title: Text(
            _localized(
              context,
              en: 'Verify and approve device',
              ru: 'Проверьте и подтвердите устройство',
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
                    en: 'On ${target.name}, open Settings → This device. Compare the full pairing fingerprint before sharing the vault key.',
                    ru: 'На устройстве ${target.name} откройте «Настройки → Это устройство». Сверьте отпечаток полностью, прежде чем передавать ключ хранилища.',
                  ),
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
                  title: Text(
                    _localized(
                      context,
                      en: 'The fingerprint exactly matches the new device',
                      ru: 'Отпечаток полностью совпадает с новым устройством',
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
            ),
            FilledButton(
              onPressed: fingerprintVerified
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(
                _localized(
                  context,
                  en: 'Sign and approve',
                  ru: 'Подписать и подтвердить',
                ),
              ),
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
              ? _localized(
                  context,
                  en: 'Device approved. Open Settings there and choose Check approval.',
                  ru: 'Устройство подтверждено. Откройте на нём настройки и нажмите «Проверить подтверждение».',
                )
              : (controller.errorMessage ??
                    _localized(
                      context,
                      en: 'Could not approve this device.',
                      ru: 'Не удалось подтвердить устройство.',
                    )),
        ),
      ),
    );
  }

  Future<void> _checkApproval(BuildContext context) async {
    final provisioned = await controller.collectProvisioning();
    if (provisioned) await onVaultProvisioned();
    if (!context.mounted) return;
    final message = provisioned
        ? _localized(
            context,
            en: 'This device is approved and the vault is unlocked.',
            ru: 'Устройство подтверждено, хранилище разблокировано.',
          )
        : controller.status == DeviceProvisioningStatus.awaitingApproval
        ? _localized(
            context,
            en: 'Waiting for approval from a trusted device.',
            ru: 'Ожидается подтверждение с доверенного устройства.',
          )
        : (controller.errorMessage ??
              _localized(
                context,
                en: 'Could not check device approval.',
                ru: 'Не удалось проверить подтверждение устройства.',
              ));
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
        DeviceProvisioningStatus.loading => _localized(
          context,
          en: 'Exchanging the encrypted vault key…',
          ru: 'Обмен зашифрованным ключом хранилища…',
        ),
        DeviceProvisioningStatus.awaitingApproval => _localized(
          context,
          en: 'Waiting for a trusted device to approve this device.',
          ru: 'Ожидается подтверждение этого устройства с доверенного.',
        ),
        DeviceProvisioningStatus.ready =>
          vaultReady
              ? _localized(
                  context,
                  en: 'This device can approve another signed-in device.',
                  ru: 'Это устройство может подтверждать другие устройства аккаунта.',
                )
              : _localized(
                  context,
                  en: 'Vault key received from a trusted device.',
                  ru: 'Ключ хранилища получен с доверенного устройства.',
                ),
        DeviceProvisioningStatus.failed =>
          controller.errorMessage ??
              _localized(
                context,
                en: 'Provisioning failed.',
                ru: 'Не удалось подключить устройство.',
              ),
        DeviceProvisioningStatus.idle when !signedIn => _localized(
          context,
          en: 'Sign in on both devices before linking them.',
          ru: 'Войдите в аккаунт на обоих устройствах, прежде чем связывать их.',
        ),
        DeviceProvisioningStatus.idle when !deviceReady => _localized(
          context,
          en: 'Prepare this device identity before linking it.',
          ru: 'Подготовьте ключ этого устройства, прежде чем связывать его.',
        ),
        DeviceProvisioningStatus.idle when vaultReady => _localized(
          context,
          en: 'Approve another device that has signed in to this account.',
          ru: 'Подтвердите другое устройство, вошедшее в этот аккаунт.',
        ),
        DeviceProvisioningStatus.idle => _localized(
          context,
          en: 'Sign in on a trusted device, approve this one there, then check here.',
          ru: 'Подтвердите это устройство на доверенном, затем проверьте здесь.',
        ),
      };
      final trailing = controller.busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : canApproveAnother
          ? OutlinedButton(
              onPressed: () => _addDevice(context),
              child: Text(
                _localized(
                  context,
                  en: 'Add device',
                  ru: 'Добавить устройство',
                ),
              ),
            )
          : canCollectApproval
          ? FilledButton(
              onPressed: () => _checkApproval(context),
              child: Text(
                _localized(
                  context,
                  en: 'Check approval',
                  ru: 'Проверить подтверждение',
                ),
              ),
            )
          : null;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: Text(
            _localized(
              context,
              en: 'Trusted devices',
              ru: 'Доверенные устройства',
            ),
          ),
          subtitle: Text(
            deviceCode == null
                ? subtitle
                : _localized(
                    context,
                    en: '$subtitle\nDevice code: $deviceCode',
                    ru: '$subtitle\nКод устройства: $deviceCode',
                  ),
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
        title: Text(
          _localized(
            context,
            en: 'Revoke this device?',
            ru: 'Отозвать это устройство?',
          ),
        ),
        content: Text(
          _localized(
            context,
            en:
                '${device.name} (${_deviceCode(device.id)}) will be signed out '
                'immediately and must be approved again by a trusted device before '
                'it can access the vault. This cannot retract a vault key it has '
                'already received.',
            ru:
                '${device.name} (${_deviceCode(device.id)}) сразу выйдет из аккаунта и '
                'получит доступ к хранилищу только после повторного подтверждения. '
                'Уже полученный устройством ключ отозвать нельзя.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_localized(context, en: 'Revoke', ru: 'Отозвать')),
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
              ? _localized(
                  context,
                  en: '${device.name} has been revoked.',
                  ru: 'Устройство ${device.name} отозвано.',
                )
              : (widget.controller.errorMessage ??
                    _localized(
                      context,
                      en: 'Could not revoke this device.',
                      ru: 'Не удалось отозвать устройство.',
                    )),
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
              title: Text(
                _localized(
                  context,
                  en: 'Account devices',
                  ru: 'Устройства аккаунта',
                ),
              ),
              subtitle: Text(
                _localized(
                  context,
                  en:
                      'Approved devices hold the vault key; pending devices are '
                      'signed in but still waiting for approval.',
                  ru:
                      'У подтверждённых устройств есть ключ хранилища; ожидающие вошли '
                      'в аккаунт, но ещё не подтверждены.',
                ),
              ),
              trailing: IconButton(
                tooltip: _localized(
                  context,
                  en: 'Refresh devices',
                  ru: 'Обновить список',
                ),
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
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _localized(
                      context,
                      en: 'No other device is signed in yet.',
                      ru: 'Других устройств в аккаунте пока нет.',
                    ),
                  ),
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
                    '${device.id == currentDeviceId ? _localized(context, en: ' · this device', ru: ' · это устройство') : ''}',
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
                                    ? _localized(
                                        context,
                                        en: 'Approved · Last sync: ${_formatLocalDateTime(device.lastSyncAt!)}',
                                        ru: 'Подтверждено · синхронизация: ${_formatLocalDateTime(device.lastSyncAt!)}',
                                      )
                                    : _localized(
                                        context,
                                        en: 'Approved',
                                        ru: 'Подтверждено',
                                      ))
                              : _localized(
                                  context,
                                  en: 'Pending approval',
                                  ru: 'Ожидает подтверждения',
                                ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  trailing: device.id == currentDeviceId
                      ? null
                      : IconButton(
                          tooltip: _localized(
                            context,
                            en: 'Revoke device',
                            ru: 'Отозвать устройство',
                          ),
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
      title: Text(
        _localized(
          context,
          en: 'Start HomeBox with Windows',
          ru: 'Запускать HomeBox вместе с Windows',
        ),
      ),
      subtitle: Text(
        _enabled == null
            ? _localized(
                context,
                en: 'Available in the Windows desktop build.',
                ru: 'Доступно в версии для Windows.',
              )
            : _localized(
                context,
                en: 'Uses your current Windows account only.',
                ru: 'Только для текущей учётной записи Windows.',
              ),
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
        title: Text(
          _localized(
            context,
            en: 'Prepare this device?',
            ru: 'Подготовить это устройство?',
          ),
        ),
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
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _localized(context, en: 'Create identity', ru: 'Создать ключ'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.prepareDevice();
  }

  Future<void> _copyFingerprint(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _localized(
            context,
            en: 'Device fingerprint copied.',
            ru: 'Отпечаток устройства скопирован.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final fingerprint = controller.publicKeyFingerprint;
      final subtitle = switch (controller.status) {
        DeviceSetupStatus.checking => _localized(
          context,
          en: 'Checking secure storage…',
          ru: 'Проверка защищённого хранилища…',
        ),
        DeviceSetupStatus.missing => _localized(
          context,
          en: 'No device identity. Create one before requesting provisioning.',
          ru: 'У устройства ещё нет ключа. Создайте его перед подключением.',
        ),
        DeviceSetupStatus.creating => _localized(
          context,
          en: 'Creating this device\'s key…',
          ru: 'Создание ключа устройства…',
        ),
        DeviceSetupStatus.ready => _localized(
          context,
          en: 'Identity ready · Not provisioned\nFingerprint: $fingerprint',
          ru: 'Ключ создан · не подключено\nОтпечаток: $fingerprint',
        ),
        DeviceSetupStatus.failed => _localized(
          context,
          en: 'Secure storage is unavailable or contains invalid data.',
          ru: 'Защищённое хранилище недоступно или содержит некорректные данные.',
        ),
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
          child: Text(
            _localized(context, en: 'Prepare device', ru: 'Подготовить'),
          ),
        ),
        DeviceSetupStatus.ready => IconButton(
          tooltip: _localized(
            context,
            en: 'Copy public-key fingerprint',
            ru: 'Скопировать отпечаток',
          ),
          onPressed: fingerprint == null
              ? null
              : () => _copyFingerprint(context, fingerprint),
          icon: const Icon(Icons.copy_outlined),
        ),
        DeviceSetupStatus.failed => TextButton(
          onPressed: controller.initialize,
          child: Text(_localized(context, en: 'Retry', ru: 'Повторить')),
        ),
      };
      return Card(
        child: ListTile(
          leading: const Icon(Icons.devices_other_outlined),
          title: Text(
            _localized(context, en: 'This device', ru: 'Это устройство'),
          ),
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
        title: Text(
          _localized(
            context,
            en: 'Connect to a HomeBox server',
            ru: 'Подключение к серверу HomeBox',
          ),
        ),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _localized(
              context,
              en: 'Server address',
              ru: 'Адрес сервера',
            ),
            hintText: 'homebox.local:8787',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, urlController.text),
            child: Text(_localized(context, en: 'Continue', ru: 'Продолжить')),
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
        title: Text(
          _localized(
            context,
            en: 'Verify server identity',
            ru: 'Проверьте подлинность сервера',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _localized(
                context,
                en:
                    'Compare this fingerprint with the one printed by "homebox server fingerprint" '
                    'on the server, over a channel you trust, before continuing.',
                ru:
                    'Сравните этот отпечаток с выводом команды «homebox server fingerprint» '
                    'на сервере по надёжному каналу, прежде чем продолжить.',
              ),
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
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _localized(
                context,
                en: 'Trust this server',
                ru: 'Доверять серверу',
              ),
            ),
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
        title: Text(_localized(context, en: 'Sign in', ru: 'Войти')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: _localized(
                  context,
                  en: 'Username',
                  ru: 'Имя пользователя',
                ),
              ),
            ),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _localized(context, en: 'Password', ru: 'Пароль'),
              ),
              onSubmitted: (_) => Navigator.pop(context, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_localized(context, en: 'Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_localized(context, en: 'Sign in', ru: 'Войти')),
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
            title: Text(_localized(context, en: 'Server', ru: 'Сервер')),
            subtitle: Text(
              controller.server?.baseUrl ??
                  _localized(context, en: 'Not connected', ru: 'Не подключено'),
            ),
            trailing: switch (controller.status) {
              ServerConnectionStatus.discovering ||
              ServerConnectionStatus.authenticating => const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              ServerConnectionStatus.disconnected ||
              ServerConnectionStatus.failed => FilledButton(
                onPressed: () => _promptForServer(context),
                child: Text(
                  _localized(context, en: 'Connect', ru: 'Подключить'),
                ),
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
              title: Text(
                _localized(
                  context,
                  en: 'Connection failed',
                  ru: 'Не удалось подключиться',
                ),
              ),
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
                    ? _localized(
                        context,
                        en: 'Signed in as ${session.user.username}',
                        ru: 'Вы вошли как ${session.user.username}',
                      )
                    : _localized(
                        context,
                        en: 'Not signed in',
                        ru: 'Вход не выполнен',
                      ),
              ),
              subtitle: session == null && controller.errorMessage != null
                  ? Text(controller.errorMessage!)
                  : null,
              trailing: session != null
                  ? TextButton(
                      onPressed: () => controller.logout(),
                      child: Text(
                        _localized(context, en: 'Sign out', ru: 'Выйти'),
                      ),
                    )
                  : FilledButton(
                      onPressed: () => _promptForLogin(context),
                      child: Text(
                        _localized(context, en: 'Sign in', ru: 'Войти'),
                      ),
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
        SnackBar(
          content: Text(
            _localized(
              context,
              en: 'Sign in to the server before creating a vault.',
              ru: 'Войдите на сервер, прежде чем создавать хранилище.',
            ),
          ),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _localized(
            context,
            en: 'Create this account\'s vault?',
            ru: 'Создать хранилище этого аккаунта?',
          ),
        ),
        content: Text(
          _localized(
            context,
            en:
                'HomeBox generates the encryption keys that protect your files on this server, plus a Recovery Secret you must save. '
                'If every trusted device and the Recovery Secret are lost, nobody — including HomeBox — can recover your files.',
            ru:
                'HomeBox создаст ключи шифрования, защищающие ваши файлы на сервере, и Recovery Secret, который нужно сохранить. '
                'Если потерять все доверенные устройства и Recovery Secret, восстановить файлы не сможет никто — даже HomeBox.',
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
              _localized(context, en: 'Create vault', ru: 'Создать хранилище'),
            ),
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
              controller.errorMessage ??
                  _localized(
                    context,
                    en: 'Could not create the vault.',
                    ru: 'Не удалось создать хранилище.',
                  ),
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
            _localized(
              context,
              en:
                  'Vault created, but this device could not record its own approval: '
                  '${deviceProvisioningController.errorMessage ?? 'unknown error'}. '
                  'It may show as pending in Account devices until this is retried.',
              ru:
                  'Хранилище создано, но устройство не смогло записать своё подтверждение: '
                  '${deviceProvisioningController.errorMessage ?? 'неизвестная ошибка'}. '
                  'В списке устройств оно может отображаться как ожидающее, пока это не будет повторено.',
            ),
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
        VaultSetupStatus.checking => _localized(
          context,
          en: 'Checking for an existing vault…',
          ru: 'Поиск существующего хранилища…',
        ),
        VaultSetupStatus.locked => _localized(
          context,
          en: 'No vault on this device yet. Create one here, or unlock this device from an existing trusted device / Recovery Secret.',
          ru: 'На этом устройстве ещё нет хранилища. Создайте его или разблокируйте с доверенного устройства либо по Recovery Secret.',
        ),
        VaultSetupStatus.creating => _localized(
          context,
          en: 'Creating vault keys…',
          ru: 'Создание ключей хранилища…',
        ),
        VaultSetupStatus.ready => _localized(
          context,
          en: 'Vault ready on this device.',
          ru: 'Хранилище готово на этом устройстве.',
        ),
        VaultSetupStatus.failed =>
          controller.errorMessage ??
              _localized(
                context,
                en: 'Vault storage is unavailable.',
                ru: 'Хранилище ключей недоступно.',
              ),
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
          child: Text(_localized(context, en: 'Retry', ru: 'Повторить')),
        ),
      };
      return Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.enhanced_encryption_outlined),
              title: Text(
                _localized(
                  context,
                  en: 'Personal vault',
                  ru: 'Личное хранилище',
                ),
              ),
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
                      child: Text(
                        _localized(
                          context,
                          en: 'Create vault',
                          ru: 'Создать хранилище',
                        ),
                      ),
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
            title: Text(
              _localized(
                context,
                en: 'Save your Recovery Secret',
                ru: 'Сохраните Recovery Secret',
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _localized(
                    context,
                    en: 'This is shown only once. Without it — and without another trusted device — your files can never be recovered.',
                    ru: 'Он показывается только один раз. Без него и без другого доверенного устройства восстановить файлы будет невозможно.',
                  ),
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
                  title: Text(
                    _localized(
                      context,
                      en: 'I have saved this Recovery Secret somewhere safe.',
                      ru: 'Я сохранил(а) Recovery Secret в надёжном месте.',
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
                icon: const Icon(Icons.copy_outlined),
                label: Text(_localized(context, en: 'Copy', ru: 'Копировать')),
              ),
              FilledButton(
                onPressed: confirmedSaved ? () => Navigator.pop(context) : null,
                child: Text(_localized(context, en: 'Done', ru: 'Готово')),
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
