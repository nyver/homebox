part of '../main.dart';

/// Full-screen, in-app viewer for the images of one folder: swipe or use
/// ←/→ to page, pinch or scroll to zoom, Esc to close. Images are decrypted
/// in memory (bounded by [FilesController.canShowImagePreview]) and never
/// written to disk; anything else opens with another app as before.
final class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({
    required this.controller,
    required this.images,
    required this.initialIndex,
    required this.onSaveAs,
    required this.onOpenExternally,
    required this.onShare,
  });

  final FilesController controller;
  final List<FileEntry> images;
  final int initialIndex;
  final Future<void> Function(FileEntry image) onSaveAs;
  final Future<void> Function(FileEntry image) onOpenExternally;

  /// Null where the system share sheet is unavailable.
  final Future<void> Function(FileEntry image)? onShare;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

final class _ImageViewerPageState extends State<_ImageViewerPage> {
  late final PageController _pages;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= widget.images.length) return;
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[_index];
    final total = widget.images.length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(image.name, overflow: TextOverflow.ellipsis),
                if (total > 1)
                  Text(
                    '${_index + 1} / $total',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.white70),
                  ),
              ],
            ),
            actions: [
              if (widget.onShare != null)
                IconButton(
                  onPressed: () => widget.onShare!(image),
                  icon: const Icon(Icons.share_outlined),
                  tooltip: _localized(context, en: 'Share', ru: 'Поделиться'),
                ),
              IconButton(
                onPressed: () => widget.onSaveAs(image),
                icon: const Icon(Icons.download_outlined),
                tooltip: _localized(
                  context,
                  en: 'Save as…',
                  ru: 'Сохранить как…',
                ),
              ),
              IconButton(
                onPressed: () => widget.onOpenExternally(image),
                icon: const Icon(Icons.open_in_new),
                tooltip: _localized(
                  context,
                  en: 'Open in another app',
                  ru: 'Открыть в другом приложении',
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                itemCount: total,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) => _ViewerImage(
                  key: ValueKey(widget.images[index].node.id),
                  controller: widget.controller,
                  image: widget.images[index],
                  onOpenExternally: widget.onOpenExternally,
                ),
              ),
              // Mouse users get visible arrows; touch users swipe.
              if (_index > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ViewerArrow(
                    icon: Icons.chevron_left,
                    tooltip: _localized(
                      context,
                      en: 'Previous',
                      ru: 'Предыдущее',
                    ),
                    onPressed: () => _go(-1),
                  ),
                ),
              if (_index < total - 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: _ViewerArrow(
                    icon: Icons.chevron_right,
                    tooltip: _localized(context, en: 'Next', ru: 'Следующее'),
                    onPressed: () => _go(1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ViewerArrow extends StatelessWidget {
  const _ViewerArrow({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: IconButton.filledTonal(
      onPressed: onPressed,
      icon: Icon(icon),
      tooltip: tooltip,
    ),
  );
}

/// One page of the viewer. Keeps its decoded bytes only while it is shown.
final class _ViewerImage extends StatefulWidget {
  const _ViewerImage({
    super.key,
    required this.controller,
    required this.image,
    required this.onOpenExternally,
  });

  final FilesController controller;
  final FileEntry image;
  final Future<void> Function(FileEntry image) onOpenExternally;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

final class _ViewerImageState extends State<_ViewerImage> {
  late final Future<Uint8List?> _bytes = widget.controller.fullImage(
    widget.image,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
      final bytes = snapshot.data;
      final failed = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 64,
            ),
            const SizedBox(height: 12),
            Text(
              _localized(
                context,
                en: 'This image cannot be shown here.',
                ru: 'Это изображение нельзя показать здесь.',
              ),
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => widget.onOpenExternally(widget.image),
              child: Text(
                _localized(
                  context,
                  en: 'Open in another app',
                  ru: 'Открыть в другом приложении',
                ),
              ),
            ),
          ],
        ),
      );
      if (bytes == null) return failed;
      return InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: widget.image.name,
            errorBuilder: (context, error, stackTrace) => failed,
          ),
        ),
      );
    },
  );
}
