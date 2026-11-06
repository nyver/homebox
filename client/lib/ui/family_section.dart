part of '../main.dart';

/// Family Vault (spec §28): this account's identity for family members,
/// folders shared with it, folders it shares, and an opened shared folder.
final class _FamilySection extends StatefulWidget {
  const _FamilySection({
    required this.controller,
    required this.androidFileSaver,
  });

  final FamilyVaultController? controller;
  final AndroidFileSaver? androidFileSaver;

  @override
  State<_FamilySection> createState() => _FamilySectionState();
}

final class _FamilySectionState extends State<_FamilySection> {
  SharedFolderBrowser? _browser;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller?.refresh());
  }

  @override
  void didUpdateWidget(covariant _FamilySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _closeBrowser();
      unawaited(widget.controller?.refresh());
    }
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
        child: const _FilesMessageState(
          icon: Icons.cloud_off_outlined,
          message: 'Connect to a server, sign in, and set up the vault in Settings to share folders with your family.',
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
              _IdentityCard(controller: controller),
              const SizedBox(height: 24),
              _SectionHeading(
                _localized(context, en: 'Shared with me', ru: 'Доступно мне'),
              ),
              if (controller.incoming.isEmpty)
                const ListTile(
                  leading: Icon(Icons.folder_off_outlined),
                  title: Text('Nothing has been shared with you yet.'),
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
                const ListTile(
                  leading: Icon(Icons.folder_shared_outlined),
                  title: Text(
                    'To share a folder, open its menu in Files and choose "Share with family…".',
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
        tooltip: 'Dismiss',
        icon: const Icon(Icons.close),
        onPressed: onDismiss,
      ),
    ),
  );
}

/// This account's ID (what a family member enters to share with it) and
/// identity fingerprint (what both sides compare out of band).
final class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.controller});

  final FamilyVaultController controller;

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
            const Text(
              'Give your account ID to the family member who wants to share a folder with you. '
              'Before either of you trusts the other, compare the fingerprints in person or over a call.',
            ),
            const SizedBox(height: 12),
            _CopyableValue(label: 'Account ID', value: accountId),
            const SizedBox(height: 8),
            _CopyableValue(label: 'Account fingerprint', value: fingerprint),
          ],
        ),
      ),
    );
  }
}

final class _CopyableValue extends StatelessWidget {
  const _CopyableValue({required this.label, required this.value});

  final String label;
  final String? value;

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
              SelectableText(
                text ?? '…',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Copy $label',
          icon: const Icon(Icons.copy_outlined),
          onPressed: text == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('$label copied.')));
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
        ? 'a family member'
        : view.share.ownerUsername;
    final permission = _permissionLabel(context, view.share.permission);
    final (icon, subtitle, action) = switch (view.state) {
      IncomingShareState.ready => (
        Icons.folder_shared,
        'From $owner • $permission',
        null,
      ),
      IncomingShareState.unverified => (
        Icons.gpp_maybe_outlined,
        'From $owner • Verify the owner\'s fingerprint before opening it.',
        TextButton(
          onPressed: () => _verifyOwner(context),
          child: const Text('Verify'),
        ),
      ),
      IncomingShareState.identityChanged => (
        Icons.gpp_bad_outlined,
        'From $owner • The owner\'s identity changed. Do not open this folder until you have compared fingerprints again.',
        TextButton(
          onPressed: () => _verifyOwner(context),
          child: const Text('Compare again'),
        ),
      ),
      IncomingShareState.waitingForKey => (
        Icons.hourglass_empty,
        'From $owner • Waiting for $owner to give this device access. '
            'It happens the next time $owner opens HomeBox.',
        null,
      ),
      IncomingShareState.invalid => (
        Icons.error_outline,
        'From $owner • This share could not be verified and was not opened.',
        null,
      ),
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(view.folderName ?? 'Shared folder'),
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
      title: 'Verify ${view.share.ownerUsername}',
      explanation:
          'Ask ${view.share.ownerUsername} to open Family in HomeBox and read out their account fingerprint. '
          'It must match this one exactly.',
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
      '${view.recipientTrusted ? '' : ' • Not verified on this device'}',
    ),
    trailing: PopupMenuButton<String>(
      tooltip: 'More actions',
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
                ? 'Give access to new devices'
                : 'Verify and give access to new devices…',
          ),
        ),
        const PopupMenuItem(value: 'revoke', child: Text('Remove access…')),
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
        title: 'Verify ${view.share.targetUsername}',
        explanation:
            'Ask ${view.share.targetUsername} to read out the account fingerprint shown in Family on their device.',
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
      title: Text('Remove ${view.share.targetUsername}?'),
      content: const Text(
        'They lose access to this folder immediately and HomeBox switches the folder to a new key, '
        'so they cannot read anything added from now on. Files they already opened or downloaded '
        'cannot be taken back.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove access'),
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
            SelectableText(
              fingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: compared,
              onChanged: (value) => setState(() => compared = value ?? false),
              title: const Text('Every group matches'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: compared ? () => Navigator.pop(context, true) : null,
            child: const Text('Trust'),
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
            });
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
            title: Text('Share "$folderName"'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Everything in this folder is encrypted with its own key, '
                      'which only the members you add receive. The server never sees it.',
                    ),
                    const SizedBox(height: 16),
                    if (members.isNotEmpty) ...[
                      Text(
                        'Members',
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
                            tooltip: 'Remove access',
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
                      decoration: const InputDecoration(
                        labelText: 'Family member\'s account ID',
                        helperText:
                            'They find it under Family → Your family identity.',
                      ),
                      onSubmitted: (_) => find(),
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
                      const Text(
                        'Ask the family member to read out the account fingerprint shown in Family on their device. '
                        'It must match exactly; otherwise someone could be intercepting the share.',
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        candidate!.fingerprint,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: compared,
                        onChanged: working
                            ? null
                            : (value) =>
                                  setState(() => compared = value ?? false),
                        title: const Text('Every group matches'),
                      ),
                    ],
                    if (candidate != null && candidate!.alreadyTrusted)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'You verified this family member on this device before.',
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
                child: const Text('Close'),
              ),
              if (candidate == null)
                FilledButton(
                  onPressed: working ? null : find,
                  child: const Text('Find'),
                )
              else
                FilledButton(
                  onPressed: working || !compared ? null : share,
                  child: const Text('Share'),
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
          subtitle:
              'Shared by ${browser.share.ownerUsername} • ${_permissionLabel(context, browser.share.permission)}',
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
                      label: const Text('Close'),
                    ),
                    if (browser.canGoUp)
                      OutlinedButton.icon(
                        onPressed: browser.goUp,
                        icon: const Icon(Icons.arrow_upward),
                        label: const Text('Up'),
                      ),
                    if (browser.canWrite) ...[
                      FilledButton.icon(
                        onPressed: browser.busy ? null : () => _upload(context),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Upload files'),
                      ),
                      OutlinedButton.icon(
                        onPressed: browser.busy
                            ? null
                            : () => _createFolder(context),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('New folder'),
                      ),
                    ],
                    if (browser.entries.isNotEmpty)
                      IconButton(
                        tooltip: 'Select',
                        onPressed: browser.startSelection,
                        icon: const Icon(Icons.checklist),
                      ),
                    IconButton(
                      tooltip: 'Refresh',
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
                    ? const _FilesMessageState(
                        icon: Icons.folder_open_outlined,
                        message: 'This folder is empty.',
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
                                ? _folderListIcon
                                : _defaultFileListIcon,
                            title: Text(entry.name),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(
                                    _formatFileSize(
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
                                    tooltip: 'More actions',
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
                                        const PopupMenuItem(
                                          value: 'save_as',
                                          child: Text('Save as…'),
                                        ),
                                      if (browser.canWrite &&
                                          !entry.isDirectory)
                                        const PopupMenuItem(
                                          value: 'replace',
                                          child: Text('Replace content…'),
                                        ),
                                      if (browser.canWrite)
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Rename'),
                                        ),
                                      if (browser.canWrite)
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Move to trash'),
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
          ? 'Move "${entries.single.name}" to…'
          : 'Move ${entries.length} items to…',
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
    if (context.mounted) _reportBulk(context, moved, entries.length, 'Moved');
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
              ? 'Move "${entries.single.name}" to trash?'
              : 'Move ${entries.length} items to trash?',
        ),
        content: Text(
          'They move to ${browser.share.ownerUsername}\'s Trash, where they can restore them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final deleted = await browser.deleteEntries(entries);
    if (context.mounted) {
      _reportBulk(context, deleted, entries.length, 'Moved to trash');
    }
  }

  void _reportBulk(BuildContext context, int done, int total, String verb) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done == total
              ? '$verb ${done == 1 ? '1 item' : '$done items'}.'
              : '$verb $done of $total items. ${browser.errorMessage ?? ''}'
                    .trim(),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved ${entry.name}.')));
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
    final name = await _askName(context, title: 'New folder', initial: '');
    if (name != null) await browser.createFolder(name);
  }

  Future<void> _rename(BuildContext context, SharedEntry entry) async {
    final name = await _askName(context, title: 'Rename', initial: entry.name);
    if (name != null && name != entry.name) await browser.rename(entry, name);
  }

  Future<void> _delete(BuildContext context, SharedEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move "${entry.name}" to trash?'),
        content: Text(
          'It moves to ${browser.share.ownerUsername}\'s Trash, where they can restore it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    if (confirmed == true) await browser.delete(entry);
  }
}

Future<String?> _askName(
  BuildContext context, {
  required String title,
  required String initial,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result == null || result.isEmpty ? null : result;
}

/// The selection toolbar of an opened shared folder. Moving and trashing
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
          semanticLabel: 'Select all',
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
