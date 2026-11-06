part of '../main.dart';

/// Whether this device still needs first-time setup: no verified server,
/// no saved sign-in, or no vault key on this device. A returning user who
/// is merely offline or still restoring a session is not sent back here.
bool _needsSetup(
  ServerConnectionController server,
  VaultSetupController vault,
) =>
    server.server == null ||
    server.status == ServerConnectionStatus.connectedLoggedOut ||
    vault.status == VaultSetupStatus.locked;

/// Shows [child] once setup is complete, and the [_SetupGuide] until then.
final class _SetupGate extends StatelessWidget {
  const _SetupGate({
    required this.server,
    required this.vault,
    required this.guide,
    required this.child,
  });

  final ServerConnectionController server;
  final VaultSetupController vault;
  final Widget guide;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([server, vault]),
    builder: (context, _) => _needsSetup(server, vault) ? guide : child,
  );
}

enum _StepState { done, current, upcoming }

/// The first-run guide: connect to the server, sign in, then unlock files
/// on this device — by creating the vault, approving this device from
/// another one, or restoring with the Recovery Secret. Each step reuses the
/// same dialogs as Settings.
final class _SetupGuide extends StatelessWidget {
  const _SetupGuide({
    required this.server,
    required this.deviceSetup,
    required this.provisioning,
    required this.vault,
    required this.recovery,
    required this.onVaultProvisioned,
    required this.onOpenSettings,
  });

  final ServerConnectionController server;
  final DeviceSetupController deviceSetup;
  final DeviceProvisioningController provisioning;
  final VaultSetupController vault;
  final RecoveryController recovery;
  final Future<void> Function() onVaultProvisioned;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      server,
      deviceSetup,
      provisioning,
      vault,
      recovery,
    ]),
    builder: (context, _) {
      final connected = server.server != null;
      final signedIn = server.status == ServerConnectionStatus.authenticated;
      final unlocked = vault.status == VaultSetupStatus.ready;
      _StepState state(bool done, bool reachable) => done
          ? _StepState.done
          : reachable
          ? _StepState.current
          : _StepState.upcoming;
      return _PageFrame(
        title: _localized(
          context,
          en: 'Welcome to HomeBox',
          ru: 'Добро пожаловать в HomeBox',
        ),
        subtitle: _localized(
          context,
          en: 'Three steps to your end-to-end encrypted files on this device.',
          ru: 'Три шага до ваших зашифрованных файлов на этом устройстве.',
        ),
        child: ListView(
          children: [
            _SetupStep(
              number: 1,
              state: state(connected, true),
              title: _localized(
                context,
                en: 'Connect to your server',
                ru: 'Подключитесь к серверу',
              ),
              description: connected
                  ? server.server!.baseUrl
                  : _localized(
                      context,
                      en: 'Enter your HomeBox server\'s address, then compare its fingerprint with the one its administrator gave you.',
                      ru: 'Введите адрес сервера HomeBox и сверьте его отпечаток с тем, что дал администратор.',
                    ),
              error:
                  !connected && server.status == ServerConnectionStatus.failed
                  ? server.errorMessage
                  : null,
              busy: server.status == ServerConnectionStatus.discovering,
              action: FilledButton(
                key: const ValueKey('setup-connect'),
                onPressed: () => _connectToServerFlow(context, server),
                child: Text(
                  _localized(context, en: 'Connect', ru: 'Подключить'),
                ),
              ),
            ),
            _SetupStep(
              number: 2,
              state: state(signedIn, connected),
              title: _localized(context, en: 'Sign in', ru: 'Войдите'),
              description: signedIn
                  ? _localized(
                      context,
                      en: 'Signed in as ${server.session!.user.username}',
                      ru: 'Вы вошли как ${server.session!.user.username}',
                    )
                  : _localized(
                      context,
                      en: 'Use the account your server administrator created for you.',
                      ru: 'Используйте аккаунт, созданный администратором сервера.',
                    ),
              error: connected && !signedIn ? server.errorMessage : null,
              busy: server.status == ServerConnectionStatus.authenticating,
              action: FilledButton(
                key: const ValueKey('setup-sign-in'),
                onPressed: () => _signInFlow(context, server),
                child: Text(_localized(context, en: 'Sign in', ru: 'Войти')),
              ),
            ),
            _SetupStep(
              number: 3,
              state: state(unlocked, signedIn),
              title: _localized(
                context,
                en: 'Unlock your files on this device',
                ru: 'Откройте доступ к файлам на этом устройстве',
              ),
              description: _localized(
                context,
                en: 'Your files are encrypted with keys only your devices hold. Choose how this device gets them.',
                ru: 'Файлы зашифрованы ключами, которые есть только на ваших устройствах. Выберите, как это устройство их получит.',
              ),
              busy:
                  vault.status == VaultSetupStatus.creating ||
                  provisioning.busy ||
                  recovery.busy,
              expanded: _UnlockChoices(
                server: server,
                deviceSetup: deviceSetup,
                provisioning: provisioning,
                vault: vault,
                recovery: recovery,
                onVaultProvisioned: onVaultProvisioned,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
                label: Text(
                  _localized(
                    context,
                    en: 'All options are also in Settings',
                    ru: 'Все параметры есть и в настройках',
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

final class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.state,
    required this.title,
    required this.description,
    this.error,
    this.busy = false,
    this.action,
    this.expanded,
  });

  final int number;
  final _StepState state;
  final String title;
  final String description;
  final String? error;
  final bool busy;

  /// The step's button, shown while it is the current step.
  final Widget? action;

  /// Content shown below the description while this is the current step.
  final Widget? expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = state == _StepState.current;
    final badge = CircleAvatar(
      radius: 16,
      backgroundColor: switch (state) {
        _StepState.done => _successColor(context),
        _StepState.current => scheme.primary,
        _StepState.upcoming => scheme.surfaceContainerHighest,
      },
      foregroundColor: switch (state) {
        _StepState.upcoming => scheme.onSurfaceVariant,
        _ => scheme.onPrimary,
      },
      child: state == _StepState.done
          ? const Icon(Icons.check, size: 18)
          : Text('$number'),
    );
    return Card(
      elevation: current ? 2 : 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: state == _StepState.upcoming
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(description),
                  if (error != null && current) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: TextStyle(color: scheme.error)),
                  ],
                  if (current && busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (current && expanded != null) ...[
                    const SizedBox(height: 12),
                    expanded!,
                  ],
                  if (current && action != null && !busy) ...[
                    const SizedBox(height: 12),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 3's choices: a brand-new vault, approval from a device that already
/// has it, or the Recovery Secret.
final class _UnlockChoices extends StatelessWidget {
  const _UnlockChoices({
    required this.server,
    required this.deviceSetup,
    required this.provisioning,
    required this.vault,
    required this.recovery,
    required this.onVaultProvisioned,
  });

  final ServerConnectionController server;
  final DeviceSetupController deviceSetup;
  final DeviceProvisioningController provisioning;
  final VaultSetupController vault;
  final RecoveryController recovery;
  final Future<void> Function() onVaultProvisioned;

  @override
  Widget build(BuildContext context) {
    final busy =
        vault.status != VaultSetupStatus.locked ||
        provisioning.busy ||
        recovery.busy;
    final session = server.session;
    final fingerprint = deviceSetup.publicKeyFingerprint;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChoiceCard(
          icon: Icons.add_moderator_outlined,
          title: _localized(
            context,
            en: 'This is my first HomeBox device',
            ru: 'Это моё первое устройство с HomeBox',
          ),
          description: _localized(
            context,
            en: 'Create the encryption keys for your account. You will get a Recovery Secret to keep somewhere safe.',
            ru: 'Создать ключи шифрования для аккаунта. Вы получите Recovery Secret, который нужно надёжно сохранить.',
          ),
          action: FilledButton(
            key: const ValueKey('setup-create-vault'),
            onPressed: busy
                ? null
                : () => _createVaultFlow(
                    context,
                    controller: vault,
                    serverConnectionController: server,
                    deviceProvisioningController: provisioning,
                  ),
            child: Text(
              _localized(context, en: 'Create vault', ru: 'Создать хранилище'),
            ),
          ),
        ),
        _ChoiceCard(
          icon: Icons.devices_outlined,
          title: _localized(
            context,
            en: 'I already use HomeBox on another device',
            ru: 'Я уже пользуюсь HomeBox на другом устройстве',
          ),
          description: _localized(
            context,
            en:
                'On that device open Settings → Trusted devices → Add device and choose this one'
                '${session == null ? '' : ' (code ${_deviceCode(session.device.id)})'}. '
                'Check that the fingerprint shown there matches this one, then come back here.',
            ru:
                'На том устройстве откройте «Настройки → Доверенные устройства → Добавить устройство» и выберите это'
                '${session == null ? '' : ' (код ${_deviceCode(session.device.id)})'}. '
                'Убедитесь, что отпечаток там совпадает с этим, и вернитесь сюда.',
          ),
          extra: fingerprint == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _FingerprintText(fingerprint),
                ),
          action: FilledButton.tonal(
            key: const ValueKey('setup-check-approval'),
            onPressed: busy
                ? null
                : () => _checkApprovalFlow(
                    context,
                    controller: provisioning,
                    onVaultProvisioned: onVaultProvisioned,
                  ),
            child: Text(
              _localized(
                context,
                en: 'Check approval',
                ru: 'Проверить подтверждение',
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy
                  ? null
                  : () => _restoreVaultFlow(
                      context,
                      serverConnectionController: server,
                      recoveryController: recovery,
                      deviceProvisioningController: provisioning,
                      onVaultProvisioned: onVaultProvisioned,
                    ),
              icon: const Icon(Icons.key_outlined),
              label: Text(
                _localized(
                  context,
                  en: 'Lost every device? Restore with your Recovery Secret',
                  ru: 'Нет доступа к устройствам? Восстановите по Recovery Secret',
                ),
                style: textTheme.labelLarge,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    this.extra,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget action;
  final Widget? extra;

  @override
  Widget build(BuildContext context) => Card.outlined(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(description),
                ?extra,
                const SizedBox(height: 8),
                action,
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// A key fingerprint laid out for comparing by eye: monospace, eight bytes
/// per line, the same on every device. Selecting copies the plain value.
final class _FingerprintText extends StatelessWidget {
  const _FingerprintText(this.fingerprint);

  final String fingerprint;

  @override
  Widget build(BuildContext context) => SelectableText(
    _formatFingerprint(fingerprint),
    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Courier New', 'monospace'],
      height: 1.5,
      letterSpacing: 0.5,
    ),
  );
}

/// Splits a colon-separated hex fingerprint into lines of eight bytes, or
/// any other fingerprint into lines of four four-character groups.
String _formatFingerprint(String fingerprint) {
  final value = fingerprint.trim();
  if (value.contains(':')) {
    final bytes = value.split(':');
    return [
      for (var i = 0; i < bytes.length; i += 8)
        bytes.sublist(i, (i + 8).clamp(0, bytes.length)).join(':'),
    ].join('\n');
  }
  final compact = value.replaceAll(RegExp(r'\s'), '');
  final groups = [
    for (var i = 0; i < compact.length; i += 4)
      compact.substring(i, (i + 4).clamp(0, compact.length)),
  ];
  return [
    for (var i = 0; i < groups.length; i += 4)
      groups.sublist(i, (i + 4).clamp(0, groups.length)).join(' '),
  ].join('\n');
}
