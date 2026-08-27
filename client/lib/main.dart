import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

void main() => runApp(const HomeBoxApp());

class HomeBoxApp extends StatelessWidget {
  const HomeBoxApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HomeBox',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b87)),
      useMaterial3: true,
    ),
    home: const HomeBoxDesktopPage(),
  );
}

enum AppSection { files, sync, settings }

class HomeBoxDesktopPage extends StatefulWidget {
  const HomeBoxDesktopPage({super.key});

  @override
  State<HomeBoxDesktopPage> createState() => _HomeBoxDesktopPageState();
}

class _HomeBoxDesktopPageState extends State<HomeBoxDesktopPage> {
  AppSection _section = AppSection.files;
  String? _syncFolder;
  bool _selectingFolder = false;

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
  });

  final AppSection section;
  final String? syncFolder;
  final bool selectingFolder;
  final Future<void> Function() onSelectSyncFolder;

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
    AppSection.settings => const _SettingsSection(),
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
  const _SettingsSection();
  @override
  Widget build(BuildContext context) => _PageFrame(
    title: 'Settings',
    subtitle: 'Connection and device security.',
    child: ListView(
      children: const [
        Card(
          child: ListTile(
            leading: Icon(Icons.dns_outlined),
            title: Text('Server'),
            subtitle: Text('Not connected'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(Icons.fingerprint),
            title: Text('Server fingerprint'),
            subtitle: Text('Required before the first secure connection'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(Icons.devices_other_outlined),
            title: Text('This device'),
            subtitle: Text('Not provisioned for E2EE'),
          ),
        ),
        Card(
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
