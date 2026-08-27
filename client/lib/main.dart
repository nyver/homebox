import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/e2ee/device_identity.dart';
import 'features/device/device_setup_controller.dart';
import 'features/server/server_connection_controller.dart';

void main() => runApp(const HomeBoxApp());

class HomeBoxApp extends StatelessWidget {
  const HomeBoxApp({super.key, this.deviceIdentityStore});

  final DeviceIdentityStore? deviceIdentityStore;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HomeBox',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b87)),
      useMaterial3: true,
    ),
    home: HomeBoxDesktopPage(deviceIdentityStore: deviceIdentityStore),
  );
}

enum AppSection { files, sync, settings }

class HomeBoxDesktopPage extends StatefulWidget {
  const HomeBoxDesktopPage({super.key, this.deviceIdentityStore});

  final DeviceIdentityStore? deviceIdentityStore;

  @override
  State<HomeBoxDesktopPage> createState() => _HomeBoxDesktopPageState();
}

class _HomeBoxDesktopPageState extends State<HomeBoxDesktopPage> {
  late final DeviceIdentityStore _deviceIdentityStore;
  late final DeviceSetupController _deviceSetupController;
  late final ServerConnectionController _serverConnectionController;
  AppSection _section = AppSection.files;
  String? _syncFolder;
  bool _selectingFolder = false;

  @override
  void initState() {
    super.initState();
    _deviceIdentityStore = widget.deviceIdentityStore ?? DeviceIdentityStore.platform();
    _deviceSetupController = DeviceSetupController(_deviceIdentityStore);
    _serverConnectionController = ServerConnectionController(deviceIdentityStore: _deviceIdentityStore);
    unawaited(_deviceSetupController.initialize());
    unawaited(_serverConnectionController.initialize());
  }

  @override
  void dispose() {
    _deviceSetupController.dispose();
    _serverConnectionController.dispose();
    super.dispose();
  }

  Future<void> _selectSyncFolder() async {
    setState(() => _selectingFolder = true);
    try {
      final folder = await getDirectoryPath(
        confirmButtonText: 'Use as HomeBox folder',
      );
      if (!mounted || folder == null) return;
      setState(() => _syncFolder = folder);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('HomeBox could not open the folder picker.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingFolder = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wideLayout = MediaQuery.sizeOf(context).width >= 720;
    final content = _SectionContent(
      section: _section,
      syncFolder: _syncFolder,
      selectingFolder: _selectingFolder,
      onSelectSyncFolder: _selectSyncFolder,
      deviceSetupController: _deviceSetupController,
      serverConnectionController: _serverConnectionController,
    );
    if (!wideLayout) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('HomeBox'),
          actions: const [_VaultStateChip()],
        ),
        body: content,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _section.index,
          onDestinationSelected: (index) =>
              setState(() => _section = AppSection.values[index]),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Files',
            ),
            NavigationDestination(
              icon: Icon(Icons.sync_outlined),
              selectedIcon: Icon(Icons.sync),
              label: 'Sync',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _section.index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (index) =>
                  setState(() => _section = AppSection.values[index]),
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Icon(Icons.inventory_2_outlined, size: 32),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: Text('Files'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.sync_outlined),
                  selectedIcon: Icon(Icons.sync),
                  label: Text('Sync'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('Settings'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
                    child: Row(
                      children: [
                        Text(
                          'HomeBox',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const Spacer(),
                        const _VaultStateChip(),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VaultStateChip extends StatelessWidget {
  const _VaultStateChip();

  @override
  Widget build(BuildContext context) => const Tooltip(
    message:
        'A trusted device or Recovery Secret is required to unlock E2EE data.',
    child: Chip(
      avatar: Icon(Icons.lock_outline, size: 18),
      label: Text('Vault locked'),
    ),
  );
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({
    required this.section,
    required this.syncFolder,
    required this.selectingFolder,
    required this.onSelectSyncFolder,
    required this.deviceSetupController,
    required this.serverConnectionController,
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;
  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;

  @override
  Widget build(BuildContext context) => switch (section) {
    AppSection.files => _FilesSection(
      syncFolder: syncFolder,
      selectingFolder: selectingFolder,
      onSelectSyncFolder: onSelectSyncFolder,
    ),
    AppSection.sync => _SyncSection(
      syncFolder: syncFolder,
      onSelectSyncFolder: onSelectSyncFolder,
    ),
    AppSection.settings => _SettingsSection(
      deviceSetupController: deviceSetupController,
      serverConnectionController: serverConnectionController,
    ),
  };
}

class _FilesSection extends StatelessWidget {
  const _FilesSection({
    required this.syncFolder,
    required this.selectingFolder,
    required this.onSelectSyncFolder,
  });

  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Files',
    subtitle: syncFolder == null
        ? 'Choose a local folder before syncing files.'
        : syncFolder!,
    child: syncFolder == null
        ? _EmptyFolderState(
            selectingFolder: selectingFolder,
            onSelectSyncFolder: onSelectSyncFolder,
          )
        : const _LockedFilesState(),
  );
}

class _EmptyFolderState extends StatelessWidget {
  const _EmptyFolderState({
    required this.selectingFolder,
    required this.onSelectSyncFolder,
  });
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_copy_outlined, size: 72),
          const SizedBox(height: 16),
          Text(
            'Choose your HomeBox folder',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Files in this folder will be encrypted on this computer before any upload.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: selectingFolder ? null : onSelectSyncFolder,
            icon: selectingFolder
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open),
            label: const Text('Choose folder'),
          ),
        ],
      ),
    ),
  );
}

class _LockedFilesState extends StatelessWidget {
  const _LockedFilesState();
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 72),
          SizedBox(height: 16),
          Text(
            'Unlock your E2EE vault to browse files',
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          Text(
            'HomeBox will not show encrypted filenames until this device is provisioned.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _SyncSection extends StatelessWidget {
  const _SyncSection({
    required this.syncFolder,
    required this.onSelectSyncFolder,
  });
  final String? syncFolder;
  final Future<void> Function() onSelectSyncFolder;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Sync',
    subtitle: 'Sync is paused while the E2EE vault is locked.',
    child: ListView(
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.pause_circle_outline),
            title: const Text('Sync paused'),
            subtitle: const Text(
              'Provision this device with a trusted device or Recovery Secret.',
            ),
            trailing: const Chip(label: Text('Locked')),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Local sync folder'),
            subtitle: Text(syncFolder ?? 'Not selected'),
            trailing: TextButton(
              onPressed: onSelectSyncFolder,
              child: Text(syncFolder == null ? 'Choose' : 'Change'),
            ),
          ),
        ),
        const Card(
          child: ListTile(
            leading: Icon(Icons.history),
            title: Text('No pending operations'),
            subtitle: Text(
              'The durable sync outbox will appear here after vault unlock.',
            ),
          ),
        ),
      ],
    ),
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.deviceSetupController,
    required this.serverConnectionController,
  });

  final DeviceSetupController deviceSetupController;
  final ServerConnectionController serverConnectionController;

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Settings',
    subtitle: 'Connection and device security.',
    child: ListView(
      children: [
        _ServerConnectionCard(controller: serverConnectionController),
        _DeviceIdentityCard(controller: deviceSetupController),
        const Card(
          child: ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Vault access'),
            subtitle: Text(
              'Locked until a trusted device or Recovery Secret provisions this Windows client',
            ),
            trailing: Chip(label: Text('Locked')),
          ),
        ),
        const Card(
          child: ListTile(
            leading: Icon(Icons.key_outlined),
            title: Text('Recovery Secret'),
            subtitle: Text('Required if all trusted devices are lost'),
          ),
        ),
      ],
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
        title: const Text('Prepare this Windows device?'),
        content: const Text(
          'HomeBox will create an X25519 private key protected by Windows secure storage. '
          'This does not unlock the vault until a trusted device or Recovery Secret approves it.',
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
        DeviceSetupStatus.checking => 'Checking Windows secure storage…',
        DeviceSetupStatus.missing =>
          'No device identity. Create one before requesting provisioning.',
        DeviceSetupStatus.creating =>
          'Creating a device-bound X25519 identity…',
        DeviceSetupStatus.ready =>
          'Identity ready · Not provisioned\nFingerprint: $fingerprint',
        DeviceSetupStatus.failed =>
          'Windows secure storage is unavailable or contains invalid data.',
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
          title: const Text('This Windows device'),
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
  }

  Future<void> _confirmFingerprint(BuildContext context, String fingerprint) async {
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
            SelectableText(fingerprint, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
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
                onPressed: () => controller.forgetServer(),
                child: const Text('Forget'),
              ),
            },
          ),
        ),
      ];

      if (controller.status == ServerConnectionStatus.failed && controller.errorMessage != null) {
        cards.add(Card(
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Connection failed'),
            subtitle: Text(controller.errorMessage!),
          ),
        ));
      }

      if (controller.status == ServerConnectionStatus.awaitingTrust && controller.discoveredFingerprint != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) _confirmFingerprint(context, controller.discoveredFingerprint!);
        });
      }

      if (controller.status == ServerConnectionStatus.connectedLoggedOut ||
          controller.status == ServerConnectionStatus.authenticated) {
        final session = controller.session;
        cards.add(Card(
          child: ListTile(
            leading: Icon(session != null ? Icons.verified_user_outlined : Icons.person_outline),
            title: Text(session != null ? 'Signed in as ${session.user.username}' : 'Not signed in'),
            subtitle: session == null && controller.errorMessage != null ? Text(controller.errorMessage!) : null,
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
        ));
      }

      return Column(children: cards);
    },
  );
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 24),
        Expanded(child: child),
      ],
    ),
  );
}
