// Flutter UI, modelled after Google Keep. All workflows go through
// AppController; this file holds no storage or Git logic.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bidi.dart';
import 'controller.dart';
import 'note_models.dart';

TextDirection flutterDirection(TextDir dir) =>
    dir == TextDir.rtl ? TextDirection.rtl : TextDirection.ltr;

TextDirection directionOf(String text) =>
    flutterDirection(detectDirection(text));

// -----------------------------------------------------------------------------
// App shell

class GitMarkerApp extends StatelessWidget {
  const GitMarkerApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFF9BC05),
        brightness: brightness,
      ),
      useMaterial3: true,
    );
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomePage(controller: controller),
    );
  }
}

/// Shortcuts for the current theme.
extension on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
}

/// Opens [page] on top of the current one.
Future<void> push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// Awaits a controller [action] whose failure the controller already
/// reports (`lastError`, shown as a snackbar). Returns its result, or null
/// when it failed.
Future<T?> reported<T>(Future<T> action) async {
  try {
    return await action;
  } catch (_) {
    return null;
  }
}

// -----------------------------------------------------------------------------
// Colors

const Map<NoteColor, (Color, Color)> _palette = {
  NoteColor.red: (Color(0xFFFAAFA8), Color(0xFF77172E)),
  NoteColor.orange: (Color(0xFFF39F76), Color(0xFF692B17)),
  NoteColor.yellow: (Color(0xFFFFF8B8), Color(0xFF7C4A03)),
  NoteColor.green: (Color(0xFFE2F6D3), Color(0xFF264D3B)),
  NoteColor.teal: (Color(0xFFB4DDD3), Color(0xFF0C625D)),
  NoteColor.blue: (Color(0xFFD4E4ED), Color(0xFF256377)),
  NoteColor.darkBlue: (Color(0xFFAECCDC), Color(0xFF284255)),
  NoteColor.purple: (Color(0xFFD3BFDB), Color(0xFF472E5B)),
  NoteColor.pink: (Color(0xFFF6E2DD), Color(0xFF6C394F)),
  NoteColor.brown: (Color(0xFFE9E3D4), Color(0xFF4B443A)),
  NoteColor.gray: (Color(0xFFEFEFF1), Color(0xFF232427)),
};

Color noteBackground(BuildContext context, NoteColor color) {
  final scheme = context.colors;
  final entry = _palette[color];
  if (entry == null) return scheme.surface;
  return scheme.brightness == Brightness.dark ? entry.$2 : entry.$1;
}

const String appDescription =
    'Markdown notes in the style of Google Keep, stored and versioned with '
    'Git. Open source; works offline and syncs with any Git remote.';

const String appName = 'GitMarker';
const String appLegalese =
    '© 2026 Mohamed A. Bamakhrama\nReleased under the BSD 3-Clause licence.';

/// The logo (`docs/logo.svg`, rendered to `assets/icon/icon.png`).
Widget appLogo(double size) => Image.asset(
  'assets/icon/icon.png',
  width: size,
  height: size,
  filterQuality: FilterQuality.medium,
  semanticLabel: '$appName logo',
);

/// The About window: the logo on top, then the name, what the app is, and
/// the licence, with the open-source licences one tap away.
void showGitMarkerAbout(BuildContext context) => unawaited(
  showDialog<void>(
    context: context,
    builder: (context) {
      final theme = context.theme;
      return AlertDialog(
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              appLogo(112),
              const SizedBox(height: 16),
              Text(appName, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(appDescription, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Text(
                appLegalese,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationIcon: Padding(
                padding: const EdgeInsets.all(8),
                child: appLogo(64),
              ),
              applicationLegalese: appLegalese,
            ),
            child: const Text('Licences'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  ),
);

String authMethodLabel(AuthMethod method) => switch (method) {
  AuthMethod.none => 'None (public or local)',
  AuthMethod.httpsToken => 'HTTPS access token',
  AuthMethod.sshKey => 'SSH key file',
  AuthMethod.sshAgent => 'SSH agent',
};

String colorLabel(NoteColor color) => switch (color) {
  NoteColor.none => 'Default',
  NoteColor.darkBlue => 'Dark blue',
  _ => color.name[0].toUpperCase() + color.name.substring(1),
};

// -----------------------------------------------------------------------------
// Home: note grid

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppController get c => widget.controller;
  final _search = TextEditingController();
  bool _grid = true;
  bool _initialSyncDone = false;
  StreamSubscription<void>? _subscription;

  /// Skipped files the user dismissed; the banner returns if the set
  /// changes.
  String? _dismissedSkipped;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Pick up notes edited outside GitMarker when the app (or, on desktop,
    // its window) comes back to the front.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (c.ready) c.refresh(rescan: false).ignore();
      },
    );
    _subscription = c.changes.listen((_) {
      final error = c.lastError;
      // Pages in front (editor, settings) report their own errors.
      if (error != null &&
          mounted &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        c.clearError();
        _snack(error);
      }
      _syncOnStart();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOnStart());
  }

  /// Syncs once, as soon as the repository is open.
  void _syncOnStart() {
    if (!c.ready || _initialSyncDone) return;
    _initialSyncDone = true;
    // _sync reports its own outcome, failures included.
    if (c.settings.hasRemote) unawaited(_sync(quiet: true));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_subscription?.cancel());
    _search.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sync({bool quiet = false}) async {
    final result = await c.sync();
    if (!mounted) return;
    switch (result.outcome) {
      case SyncOutcome.noRemote:
        if (!quiet) _snack('No remote configured. Add one in Settings.');
      case SyncOutcome.upToDate:
        if (!quiet) _snack('Already up to date');
      case SyncOutcome.fastForwarded:
        _snack('Pulled remote changes');
      case SyncOutcome.pushed:
        _snack('Pushed local changes');
      case SyncOutcome.rebased:
        _snack('Merged local and remote changes');
      case SyncOutcome.dirtyTree:
        await _askCommitPending();
      case SyncOutcome.conflict:
        await _resolveConflict(result);
      case SyncOutcome.error:
        _snack('Sync failed: ${result.message}');
    }
  }

  Future<void> _askCommitPending() async {
    final commit = await confirm(
      context,
      title: 'Uncommitted changes',
      content: const Text(
        'The notes folder has changes that are not committed (for example, '
        'files edited outside GitMarker). Sync needs a clean working tree.',
      ),
      action: 'Commit and sync',
    );
    if (commit) {
      await c.commitPendingChanges();
      await _sync();
    }
  }

  Future<void> _resolveConflict(SyncResult result) async {
    final choice = await showDialog<ConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConflictDialog(result: result),
    );
    if (choice == null || !mounted) return;
    final message = (await reported(c.resolveConflict(choice)))?.message;
    if (mounted && message != null) _snack(message);
  }

  Future<void> _openNote(Note? note) =>
      push(context, NoteEditorPage(controller: c, note: note));

  /// Tells the user which Markdown files were not loaded, instead of
  /// skipping them silently.
  Widget? _skippedBanner() {
    final skipped = c.skippedFiles;
    final key = skipped.map((f) => f.path).join('\n');
    if (skipped.isEmpty || key == _dismissedSkipped) return null;
    final count = skipped.length;
    return MaterialBanner(
      leading: const Icon(Icons.warning_amber),
      content: Text(
        count == 1
            ? '${skipped.single.path} was skipped: ${skipped.single.reason}.'
            : '$count Markdown files were skipped because their front '
                  'matter is malformed.',
      ),
      actions: [
        if (count > 1)
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Skipped files'),
                content: SingleChildScrollView(
                  child: SelectableText(
                    skipped
                        .map((f) => '${f.path}\n    ${f.reason}')
                        .join('\n\n'),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            child: const Text('Details'),
          ),
        TextButton(
          onPressed: () => setState(() => _dismissedSkipped = key),
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: c.changes,
      builder: (context, _) {
        if (c.fatalError != null) return _FatalErrorPage(controller: c);
        if (!c.ready) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: _SearchField(
              controller: _search,
              onChanged: (v) => c.query = v,
            ),
            actions: [
              _ColorFilterButton(controller: c),
              IconButton(
                tooltip: _grid ? 'List view' : 'Grid view',
                icon: Icon(
                  _grid ? Icons.view_agenda_outlined : Icons.grid_view,
                ),
                onPressed: () => setState(() => _grid = !_grid),
              ),
              _SyncButton(controller: c, onPressed: () => _sync()),
            ],
          ),
          drawer: _NavigationDrawer(controller: c),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Take a note',
            onPressed: () => _openNote(null),
            child: const Icon(Icons.add),
          ),
          body: Column(
            children: [
              ?_skippedBanner(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => c.settings.hasRemote ? _sync() : c.refresh(),
                  child: _NoteGrid(
                    controller: c,
                    grid: _grid,
                    onOpen: _openNote,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Keep's "search by colour": narrows the visible notes to one colour.
class _ColorFilterButton extends StatelessWidget {
  const _ColorFilterButton({required this.controller});

  final AppController controller;

  static const Object _any = 'any';

  @override
  Widget build(BuildContext context) {
    final active = controller.colorFilter;
    return PopupMenuButton<Object>(
      tooltip: active == null
          ? 'Filter by colour'
          : 'Showing ${colorLabel(active).toLowerCase()} notes',
      icon: active == null
          ? const Icon(Icons.palette_outlined)
          : Icon(
              Icons.palette,
              color: active == NoteColor.none
                  ? null
                  : noteBackground(context, active),
              shadows: const [Shadow(blurRadius: 1)],
            ),
      onSelected: (value) =>
          controller.colorFilter = value is NoteColor ? value : null,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<Object>(
          value: _any,
          checked: active == null,
          child: const Text('Any colour'),
        ),
        for (final color in NoteColor.values)
          CheckedPopupMenuItem<Object>(
            value: color,
            checked: active == color,
            child: Row(
              spacing: 12,
              children: [_ColorDot(color, size: 18), Text(colorLabel(color))],
            ),
          ),
      ],
    );
  }
}

/// A note colour as a circle; [selected] gets a thick primary ring.
class _ColorDot extends StatelessWidget {
  const _ColorDot(this.color, {required this.size, this.selected = false});

  final NoteColor color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: noteBackground(context, color),
      shape: BoxShape.circle,
      border: Border.all(
        color: selected
            ? context.colors.primary
            : context.colors.outlineVariant,
        width: selected ? 3 : 1,
      ),
    ),
    child: color == NoteColor.none && size >= 32
        ? Icon(Icons.format_color_reset, size: size / 2)
        : null,
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, value, _) => TextField(
          controller: controller,
          onChanged: onChanged,
          textDirection: directionOf(value.text),
          decoration: InputDecoration(
            hintText: 'Search',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            filled: true,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.controller, required this.onPressed});

  final AppController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (controller.syncing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final hasRemote = controller.settings.hasRemote;
    final (icon, tooltip, problem) = switch (controller.lastSync?.outcome) {
      SyncOutcome.conflict => (
        Icons.sync_problem,
        'Sync paused: conflict',
        true,
      ),
      SyncOutcome.error => (
        Icons.cloud_off,
        'Last sync failed. Tap to retry',
        true,
      ),
      _ => (
        hasRemote ? Icons.sync : Icons.cloud_off_outlined,
        hasRemote ? 'Sync' : 'No remote configured',
        false,
      ),
    };
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: problem ? context.colors.error : null),
      onPressed: onPressed,
    );
  }
}

class _NavigationDrawer extends StatelessWidget {
  const _NavigationDrawer({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    void select(VoidCallback action) {
      action();
      Navigator.pop(context);
    }

    final allSelected = c.folderFilter == null && c.tagFilter == null;
    return Drawer(
      child: StreamBuilder<void>(
        stream: c.changes,
        builder: (context, _) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 24, 8),
              child: Row(
                children: [
                  appLogo(36),
                  const SizedBox(width: 12),
                  Text(appName, style: context.theme.textTheme.titleLarge),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.lightbulb_outline),
              title: const Text('Notes'),
              selected: allSelected,
              onTap: () => select(c.showAll),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Top level'),
              selected: c.folderFilter == '',
              onTap: () => select(() => c.showFolder('')),
            ),
            const Divider(),
            _SectionHeader(
              'Folders',
              trailing: IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () async {
                  final name = await promptText(
                    context,
                    title: 'New folder',
                    label: 'Folder name',
                  );
                  if (name != null && name.trim().isNotEmpty) {
                    await reported(c.createFolder(name));
                  }
                },
              ),
            ),
            for (final folder in c.folders)
              ListTile(
                contentPadding: EdgeInsetsDirectional.only(
                  start: 16.0 + 16 * (folder.split('/').length - 1),
                  end: 16,
                ),
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  folder.split('/').last,
                  textDirection: directionOf(folder.split('/').last),
                ),
                selected: c.folderFilter == folder,
                onTap: () => select(() => c.showFolder(folder)),
              ),
            if (c.tags.isNotEmpty) ...[
              const Divider(),
              const _SectionHeader('Tags'),
              for (final tag in c.tags)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: Text(tag, textDirection: directionOf(tag)),
                  selected: c.tagFilter == tag,
                  onTap: () => select(() => c.showTag(tag)),
                ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                unawaited(push(context, SettingsPage(controller: c)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                Navigator.pop(context);
                showGitMarkerAbout(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 24, end: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: context.theme.textTheme.labelMedium?.copyWith(
                letterSpacing: 1.2,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _NoteGrid extends StatelessWidget {
  const _NoteGrid({
    required this.controller,
    required this.grid,
    required this.onOpen,
  });

  final AppController controller;
  final bool grid;
  final ValueChanged<Note> onOpen;

  @override
  Widget build(BuildContext context) {
    final pinned = controller.pinnedNotes;
    final others = controller.otherNotes;
    if (pinned.isEmpty && others.isEmpty) {
      final searching = controller.query.trim().isNotEmpty;
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            searching ? Icons.search_off : Icons.lightbulb_outline,
            size: 96,
            color: context.colors.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            searching ? 'No matching notes' : 'Notes you add appear here',
            textAlign: TextAlign.center,
            style: context.theme.textTheme.titleMedium,
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = grid
            ? (constraints.maxWidth / 240).floor().clamp(2, 6)
            : 1;
        // List view: one centred column at most 640 wide.
        final side = grid
            ? 0.0
            : ((constraints.maxWidth - 640) / 2).clamp(0.0, double.infinity);
        List<Widget> section(String? label, List<Note> notes) => [
          if (label != null)
            SliverPadding(
              padding: EdgeInsetsDirectional.fromSTEB(
                16 + side,
                16,
                16 + side,
                4,
              ),
              sliver: SliverToBoxAdapter(
                child: Text(label, style: context.theme.textTheme.labelMedium),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: 4 + side),
            sliver: _MasonrySliver(
              columns: columns,
              count: notes.length,
              itemBuilder: (context, index) => NoteCard(
                key: ValueKey(notes[index].path),
                controller: controller,
                note: notes[index],
                onTap: () => onOpen(notes[index]),
              ),
            ),
          ),
        ];
        return CustomScrollView(
          // Pull-to-refresh needs a scrollable even when the notes fit.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (pinned.isNotEmpty) ...section('PINNED', pinned),
            if (others.isNotEmpty)
              ...section(pinned.isEmpty ? null : 'OTHERS', others),
            const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
          ],
        );
      },
    );
  }
}

/// Masonry layout in lanes: item i goes to lane i % columns, which keeps
/// reading order left to right, top to bottom. Each lane is a lazily built
/// list, so only the cards on screen exist, even with thousands of notes.
class _MasonrySliver extends StatelessWidget {
  const _MasonrySliver({
    required this.columns,
    required this.count,
    required this.itemBuilder,
  });

  final int columns;
  final int count;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverCrossAxisGroup(
      slivers: [
        for (var lane = 0; lane < columns; lane++)
          SliverCrossAxisExpanded(
            flex: 1,
            sliver: SliverList.builder(
              itemCount: count <= lane
                  ? 0
                  : (count - lane + columns - 1) ~/ columns,
              itemBuilder: (context, i) =>
                  itemBuilder(context, lane + i * columns),
            ),
          ),
      ],
    );
  }
}

/// Actions in a card's long-press menu.
enum _CardAction { pin, move, delete }

class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.controller,
    required this.note,
    required this.onTap,
  });

  final AppController controller;
  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final background = noteBackground(context, note.color);
    final preview = note.body;
    return Card(
      margin: const EdgeInsets.all(4),
      color: background,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: note.color == NoteColor.none
            ? BorderSide(color: theme.colorScheme.outlineVariant)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: note.title.trim().isEmpty
                        ? const SizedBox.shrink()
                        : Text(
                            note.title,
                            textDirection: directionOf(note.title),
                            style: theme.textTheme.titleMedium,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  if (note.pinned)
                    Icon(
                      Icons.push_pin,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
              if (preview.trim().isNotEmpty) ...[
                if (note.title.trim().isNotEmpty) const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ClipRect(
                      child: MarkdownView(
                        text: preview,
                        compact: true,
                        onToggle: _toggle,
                      ),
                    ),
                  ),
                ),
              ],
              if (note.tags.isNotEmpty || note.folder.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    if (note.folder.isNotEmpty)
                      _Pill(icon: Icons.folder_outlined, label: note.folder),
                    for (final tag in note.tags) _Pill(label: tag),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Ticks or unticks the checklist item on [line] and saves the note.
  Future<void> _toggle(int line) => reported(
    controller.saveNote(
      note.copyWith(body: ChecklistItem.toggle(note.body, line)),
      original: note,
    ),
  );

  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<_CardAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (action, icon, label) in [
              (
                _CardAction.pin,
                note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                note.pinned ? 'Unpin' : 'Pin',
              ),
              (
                _CardAction.move,
                Icons.drive_file_move_outlined,
                'Move to folder',
              ),
              (_CardAction.delete, Icons.delete_outline, 'Delete'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _CardAction.pin:
        await reported(
          controller.saveNote(
            note.copyWith(pinned: !note.pinned),
            original: note,
          ),
        );
      case _CardAction.move:
        final folder = await pickFolder(
          context,
          controller,
          current: note.folder,
        );
        if (folder != null) await reported(controller.moveNote(note, folder));
      case _CardAction.delete:
        await deleteWithUndo(context, controller, note);
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              textDirection: directionOf(label),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _FatalErrorPage extends StatelessWidget {
  const _FatalErrorPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final message = controller.fatalError ?? '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 16,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: context.colors.error,
                ),
                Text(
                  'Could not open the notes repository',
                  style: context.theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                SelectableText(message, textAlign: TextAlign.center),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: controller.init,
                      child: const Text('Retry'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          push(context, SettingsPage(controller: controller)),
                      child: const Text('Settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Shared dialogs

/// A dialog with Cancel and [action] buttons; true when [action] is chosen.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required Widget content,
  required String action,
  IconData? icon,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: icon == null ? null : Icon(icon),
        title: Text(title),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) {
  final text = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: text,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(text.dispose);
}

/// Deletes [note] (a commit) and offers Keep's "Undo", which writes it
/// back as it was. Returns false when the delete failed (the controller
/// reports why).
Future<bool> deleteWithUndo(
  BuildContext context,
  AppController controller,
  Note note,
) async {
  // Look up the messenger first: the caller may be closing its page.
  final messenger = ScaffoldMessenger.of(context);
  if (await reported(controller.deleteNote(note).then((_) => true)) == null) {
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const Text('Note deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => controller.restoreNote(note).ignore(),
        ),
      ),
    );
  return true;
}

/// Returns the chosen folder ('' for top level), or null when cancelled.
Future<String?> pickFolder(
  BuildContext context,
  AppController controller, {
  required String current,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Move to folder'),
      children: [
        for (final folder in ['', ...controller.folders])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, folder),
            child: Row(
              spacing: 12,
              children: [
                Icon(
                  folder == current ? Icons.folder : Icons.folder_outlined,
                  size: 20,
                ),
                Expanded(child: Text(folder.isEmpty ? 'Top level' : folder)),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () async {
            final name = await promptText(
              context,
              title: 'New folder',
              label: 'Folder name',
            );
            if (context.mounted && name != null && name.trim().isNotEmpty) {
              Navigator.pop(context, name.trim());
            }
          },
          child: const Row(
            spacing: 12,
            children: [
              Icon(Icons.create_new_folder_outlined, size: 20),
              Text('New folder…'),
            ],
          ),
        ),
      ],
    ),
  );
}

class ConflictDialog extends StatelessWidget {
  const ConflictDialog({super.key, required this.result});

  final SyncResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.sync_problem),
      title: const Text('Sync paused'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            const Text(
              'Local and remote changes conflict, so the rebase was aborted and '
              'your notes were left untouched. Choose how to continue:',
            ),
            for (final file in result.conflictedFiles)
              Text('• $file', textDirection: directionOf(file)),
            const Text(
              'Keep remote: discard local commits and use the remote version.\n'
              'Force push: overwrite the remote with this device\'s notes.\n'
              'Abort: change nothing; sync stays diverged.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, ConflictResolution.abort),
          child: const Text('Abort'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, ConflictResolution.forcePushLocal),
          child: const Text('Force push'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, ConflictResolution.keepRemote),
          child: const Text('Keep remote'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Markdown view (read-only, selectable, per-line direction)

class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.text,
    this.compact = false,
    this.onToggle,
  });

  final String text;

  /// Card preview: smaller text, first lines only; links are not tappable
  /// (a tap opens the note).
  final bool compact;

  /// Called with the line index of a checklist item whose box is tapped;
  /// null makes the boxes read-only.
  final ValueChanged<int>? onToggle;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  static const int _previewLines = 10;

  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final RegExp _numbered = RegExp(r'^(\s*)(\d+[.)])\s+(.*)$');
  static final RegExp _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

  /// Opening or closing code fence (three or more backticks or tildes) and
  /// its info string (` ```math ` is a formula).
  static final RegExp _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*(\S*)');

  /// Inline markup, earliest match wins:
  /// 1 escaped punctuation; 2–3 `code`; 4 $math$ (a `$` followed by a
  /// space, or a closing one followed by a digit, is a dollar sign);
  /// 5–6 `[text](url)`; 7 `<url>`; 8–9 *, ** and *** emphasis; 10–11 the same
  /// with underscores, which do not work inside words (snake_case).
  static final RegExp _inline = RegExp(
    r'\\([\\`*_\[\]()$#+\-.!>~|{}])'
    r'|(`+)(.+?)\2'
    r'|(?<![\\$])\$(?=[^\s$])((?:\\.|[^$\\])*?[^\s\\])\$(?![\d$])'
    r'|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)'
    r'|<((?:https?|mailto):[^>\s]+)>'
    r'|(\*\*\*|\*\*|\*)(?=\S)(.+?)(?<=\S)\8'
    r'|(?<![\p{L}\p{N}_])(___|__|_)(?=\S)(.+?)(?<=\S)\10(?![\p{L}\p{N}_])',
    unicode: true,
  );

  /// Monospace on every platform: the first installed of the usual system
  /// fonts (macOS/iOS, Windows, Linux), then the `monospace` alias
  /// (Android, other Linux). The alias alone is not enough: it does not
  /// exist on Apple platforms or Windows, and on Linux it can resolve to a
  /// CJK font that draws `\` as `¥`.
  static const TextStyle _mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: [
      'Consolas',
      'DejaVu Sans Mono',
      'Liberation Mono',
      'Noto Sans Mono',
      'Courier New',
      'monospace',
    ],
  );

  /// Longer lines are shown without inline markup: matching it takes time
  /// that grows with the square of the line length (2.5 s for 20,000
  /// hostile characters), and a note from a shared repository must not
  /// freeze the app.
  static const int _maxMarkupLine = 2000;

  /// Longer formulas are shown as their TeX source.
  static const int _maxTex = 1000;

  /// Tap handlers of the links built last; replaced on every build.
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  /// Opens web and mail links in the system's app; other schemes are not
  /// opened.
  static Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !{'http', 'https', 'mailto'}.contains(uri.scheme)) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final compact = widget.compact;
    final onToggle = widget.onToggle;
    final theme = context.theme;
    final base = (compact
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodyLarge)!;
    final codeBackground = theme.colorScheme.onSurface.withValues(alpha: 0.06);
    final children = <Widget>[];
    // Indexed lines, so a tapped checkbox can name its line in [text].
    var lines = directionalLines(widget.text).indexed.toList();
    if (compact) {
      // The first lines, without blank ones around them.
      bool blank((int, (String, TextDir)) l) => l.$2.$1.trim().isEmpty;
      lines = lines.skipWhile(blank).take(_previewLines).toList();
      while (lines.isNotEmpty && blank(lines.last)) {
        lines.removeLast();
      }
    }

    /// TeX source that does not parse is shown as it was written.
    Widget texError(String source, TextStyle style) => Text(
      source,
      textDirection: TextDirection.ltr,
      style: style.merge(_mono).copyWith(color: theme.colorScheme.error),
    );

    /// [line]'s inline markup as spans in [style]; [tap] makes every piece
    /// part of one link.
    List<InlineSpan> spans(
      String line,
      TextStyle style, [
      GestureRecognizer? tap,
    ]) {
      final out = <InlineSpan>[];
      var last = 0;
      void plain(String text) {
        if (text.isNotEmpty) {
          out.add(TextSpan(text: text, style: style, recognizer: tap));
        }
      }

      for (final m in _inline.allMatches(line)) {
        plain(line.substring(last, m.start));
        last = m.end;
        if (m.group(1) != null) {
          plain(m.group(1)!);
        } else if (m.group(3) != null) {
          out.add(
            TextSpan(
              text: m.group(3),
              style: style
                  .merge(_mono)
                  .copyWith(backgroundColor: codeBackground),
              recognizer: tap,
            ),
          );
        } else if (m.group(4) != null && m.group(4)!.length > _maxTex) {
          plain(m.group(0)!);
        } else if (m.group(4) != null) {
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Math.tex(
                  m.group(4)!,
                  mathStyle: MathStyle.text,
                  textStyle: style,
                  onErrorFallback: (_) => texError(m.group(0)!, style),
                ),
              ),
            ),
          );
        } else if (m.group(5) != null || m.group(7) != null) {
          final url = m.group(6) ?? m.group(7)!;
          TapGestureRecognizer? recognizer;
          if (!compact && tap == null) {
            recognizer = TapGestureRecognizer()..onTap = () => _open(url);
            _recognizers.add(recognizer);
          }
          out.addAll(
            spans(
              m.group(5) ?? url,
              style.copyWith(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: theme.colorScheme.primary,
              ),
              recognizer ?? tap,
            ),
          );
        } else {
          final marker = m.group(8) ?? m.group(10)!;
          final content = m.group(9) ?? m.group(11)!;
          out.addAll(
            spans(
              content,
              style.copyWith(
                fontWeight: marker.length >= 2 ? FontWeight.bold : null,
                fontStyle: marker.length != 2 ? FontStyle.italic : null,
              ),
              tap,
            ),
          );
        }
      }
      plain(line.substring(last));
      return out;
    }

    /// [line] with its inline markup rendered.
    Widget inline(String line, TextStyle style, TextDirection direction) {
      if (line.length > _maxMarkupLine || !_inline.hasMatch(line)) {
        return Text(line, textDirection: direction, style: style);
      }
      return Text.rich(
        TextSpan(children: spans(line, style)),
        textDirection: direction,
      );
    }

    // Lines of the code or formula block being collected, the fence that
    // opened it (null for an indented code block), and whether it is a
    // formula (```math or $$).
    List<String>? code;
    String? fence;
    var math = false;
    void endCode() {
      if (code == null) return;
      // Trailing blank lines belong to an indented block's surroundings.
      while (fence == null && code!.isNotEmpty && code!.last.isEmpty) {
        code!.removeLast();
      }
      final source = code!.join('\n');
      final Widget content;
      if (math && source.length > _maxTex) {
        content = texError(source, base);
      } else if (math) {
        final formula = Directionality(
          textDirection: TextDirection.ltr,
          child: Math.tex(
            source,
            mathStyle: MathStyle.display,
            textStyle: base,
            onErrorFallback: (_) => texError(source, base),
          ),
        );
        // Wide formulas scroll sideways; cards shrink them to fit.
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: compact
                ? FittedBox(fit: BoxFit.scaleDown, child: formula)
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: formula,
                  ),
          ),
        );
      } else {
        final block = Text(
          source,
          textDirection: TextDirection.ltr,
          softWrap: false,
          overflow: compact ? TextOverflow.clip : null,
          style: base.merge(_mono),
        );
        content = Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: codeBackground,
            borderRadius: BorderRadius.circular(4),
          ),
          // Long lines scroll sideways instead of wrapping; cards clip.
          child: compact
              ? block
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: block,
                ),
        );
      }
      children.add(content);
      code = null;
      fence = null;
      math = false;
    }

    var previousBlank = true;
    for (final (index, (line, dir)) in lines) {
      final trimmed = line.trim();
      if (fence == r'$$') {
        // Inside a $$ formula: the line ending in $$ closes it.
        if (trimmed.endsWith(r'$$')) {
          code!.add(trimmed.substring(0, trimmed.length - 2));
          endCode();
        } else {
          code!.add(line);
        }
        continue;
      }
      if (fence != null) {
        // Inside a fenced block: only a fence of the same kind, at least
        // as long, closes it.
        if (trimmed.startsWith(fence!) &&
            trimmed.replaceAll(fence![0], '').isEmpty) {
          endCode();
        } else {
          code!.add(line);
        }
        continue;
      }
      final opening = _fence.firstMatch(line);
      if (opening != null) {
        endCode();
        code = [];
        fence = opening.group(1);
        math = opening.group(2) == 'math';
        continue;
      }
      if (trimmed.startsWith(r'$$')) {
        endCode();
        math = true;
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          // $$ formula $$ on one line.
          code = [trimmed.substring(2, trimmed.length - 2)];
          endCode();
        } else {
          code = [if (trimmed.length > 2) trimmed.substring(2)];
          fence = r'$$';
        }
        previousBlank = false;
        continue;
      }
      // Indented code: four spaces (or a tab) after a blank line or more
      // indented code; list items keep their indentation as nesting.
      final indented = line.startsWith('    ') || line.startsWith('\t');
      if (indented &&
          (code != null || previousBlank) &&
          ChecklistItem.parse(line) == null &&
          !_bullet.hasMatch(line) &&
          !_numbered.hasMatch(line)) {
        (code ??= []).add(
          line.startsWith('\t') ? line.substring(1) : line.substring(4),
        );
        continue;
      }
      if (code != null && trimmed.isEmpty) {
        // A blank line may continue an indented block.
        code!.add('');
        continue;
      }
      endCode();
      previousBlank = trimmed.isEmpty;
      final direction = flutterDirection(dir);
      Widget row;
      final heading = _heading.firstMatch(line);
      final task = ChecklistItem.parse(line);
      final bullet = _bullet.firstMatch(line);
      final numbered = _numbered.firstMatch(line);
      if (_rule.hasMatch(line)) {
        row = const Divider();
      } else if (heading != null) {
        final level = heading.group(1)!.length;
        final style = switch (level) {
          _ when compact => theme.textTheme.titleSmall,
          1 => theme.textTheme.headlineSmall,
          2 => theme.textTheme.titleLarge,
          _ => theme.textTheme.titleMedium,
        };
        row = Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: inline(heading.group(2)!, style!, direction),
        );
      } else if (task != null) {
        // One semantics node: checkbox state, text and tap action.
        row = MergeSemantics(
          child: _prefixed(
            direction,
            task.indent,
            Checkbox(
              value: task.done,
              onChanged: onToggle == null ? null : (_) => onToggle(index),
            ),
            inline(
              task.text,
              task.done
                  ? base.copyWith(decoration: TextDecoration.lineThrough)
                  : base,
              direction,
            ),
            centred: true,
          ),
        );
      } else if (bullet != null) {
        row = _prefixed(
          direction,
          bullet.group(1)!,
          Text('•', style: base),
          inline(bullet.group(2)!, base, direction),
        );
      } else if (numbered != null) {
        row = _prefixed(
          direction,
          numbered.group(1)!,
          Text(numbered.group(2)!, style: base),
          inline(numbered.group(3)!, base, direction),
        );
      } else if (line.startsWith('>')) {
        row = Container(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: theme.colorScheme.outline, width: 3),
            ),
          ),
          padding: const EdgeInsetsDirectional.only(start: 12),
          child: inline(
            line.replaceFirst(RegExp(r'^>\s?'), ''),
            base.copyWith(fontStyle: FontStyle.italic),
            direction,
          ),
        );
      } else {
        row = inline(line, base, direction);
      }
      children.add(
        Directionality(
          textDirection: direction,
          child: Align(alignment: AlignmentDirectional.centerStart, child: row),
        ),
      );
    }
    // An unclosed fence runs to the end of the note, as in CommonMark.
    endCode();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// [marker] (bullet, number, checkbox) before [content], indented by
  /// [indent]. A [centred] marker (the checkbox, a full-size touch target)
  /// sits in the middle of the text instead of on its first line.
  Widget _prefixed(
    TextDirection direction,
    String indent,
    Widget marker,
    Widget content, {
    bool centred = false,
  }) => Padding(
    padding: EdgeInsetsDirectional.only(start: 12.0 * (indent.length ~/ 2)),
    child: Row(
      textDirection: direction,
      crossAxisAlignment: centred
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.only(
            end: centred ? 4 : 8,
            top: centred ? 0 : 2,
          ),
          child: marker,
        ),
        Expanded(child: content),
      ],
    ),
  );
}

// -----------------------------------------------------------------------------
// Note editor

/// Actions in the editor's overflow menu.
enum _EditorAction {
  move('Move to folder'),
  copy('Copy text'),
  delete('Delete');

  const _EditorAction(this.label);
  final String label;
}

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({super.key, required this.controller, this.note});

  final AppController controller;

  /// The note to edit; null for a new note (created on first save).
  final Note? note;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  AppController get c => widget.controller;
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final AppLifecycleListener _lifecycle;

  /// Last stored version; null until a new note is first saved.
  Note? _stored;
  late Note _draft;
  bool _viewing = false;
  bool _closing = false;
  Future<bool>? _saving;

  /// Why the last save failed; the editor stays open until it succeeds or
  /// the user discards the changes.
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _stored = widget.note;
    _draft = widget.note ?? Note(path: '', title: '', body: '');
    _title = TextEditingController(text: _draft.title)..addListener(_onText);
    _body = TextEditingController(text: _draft.body)..addListener(_onText);
    _viewing = widget.note != null && widget.note!.body.trim().isNotEmpty;
    // Persist the draft when the app is backgrounded or closed.
    _lifecycle = AppLifecycleListener(onHide: _save, onDetach: _save);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _onText() => setState(() {
    _draft = _draft.copyWith(title: _title.text, body: _body.text);
  });

  bool get _isEmpty =>
      _draft.title.trim().isEmpty && _draft.body.trim().isEmpty;

  /// Saves the draft if it changed. Calls are chained so a save never races
  /// another one.
  /// Saves the draft if it changed; true when it is stored (or there was
  /// nothing to store). Calls are chained so a save never races another.
  Future<bool> _save() {
    final previous = _saving ?? Future.value(true);
    final next = previous.then((_) async {
      final stored = _stored;
      try {
        if (stored == null) {
          if (_isEmpty) return true;
          _stored = await c.createNote(
            title: _draft.title,
            body: _draft.body,
            pinned: _draft.pinned,
            color: _draft.color,
            tags: _draft.tags,
          );
        } else {
          final draft = _draft.copyWith(path: stored.path);
          if (draft.sameContentAs(stored)) return true;
          _stored = await c.saveNote(draft, original: stored);
        }
        _draft = _draft.copyWith(
          path: _stored!.path,
          title: _stored!.title,
          format: _stored!.format,
          titleInHeading: _stored!.titleInHeading,
        );
        if (_saveError != null && mounted) setState(() => _saveError = null);
        return true;
      } catch (e) {
        c.clearError(); // Shown here, not as a snackbar on the home page.
        if (mounted) {
          setState(() => _saveError = AppController.describeError(e));
        }
        return false;
      }
    });
    _saving = next;
    return next;
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final saved = await _save();
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      _closing = false; // Stay open: the text is not stored yet.
    }
  }

  void _discard() {
    _closing = true;
    Navigator.of(context).pop();
  }

  void _update(Note Function(Note) change) =>
      setState(() => _draft = change(_draft));

  Future<void> _pickColor() async {
    final color = await showModalBottomSheet<NoteColor>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in NoteColor.values)
                Tooltip(
                  message: colorLabel(color),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => Navigator.pop(context, color),
                    child: _ColorDot(
                      color,
                      size: 40,
                      selected: color == _draft.color,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (color != null) _update((n) => n.copyWith(color: color));
  }

  Future<void> _editTags() async {
    final tags = await showDialog<List<String>>(
      context: context,
      builder: (context) => _TagDialog(initial: _draft.tags, known: c.tags),
    );
    if (tags != null) _update((n) => n.copyWith(tags: tags));
  }

  Future<void> _move() async {
    await _save();
    final stored = _stored;
    if (stored == null || !mounted) return;
    final folder = await pickFolder(context, c, current: stored.folder);
    if (folder == null) return;
    final moved = await reported(c.moveNote(stored, folder));
    if (moved == null || !mounted) return;
    setState(() {
      _stored = moved;
      _draft = _draft.copyWith(path: moved.path, title: moved.title);
      _title.value = _title.value.copyWith(text: moved.title);
    });
  }

  Future<void> _delete() async {
    final stored = _stored;
    if (stored == null) {
      _closing = true;
      Navigator.of(context).pop();
      return;
    }
    // The draft's latest text is what Undo brings back.
    final deleted = await deleteWithUndo(
      context,
      c,
      _draft.copyWith(path: stored.path, format: stored.format),
    );
    if (!deleted || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  Future<void> _history() async {
    await _save();
    final stored = _stored;
    if (stored == null || !mounted) return;
    await push(context, HistoryPage(controller: c, note: stored));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final background = noteBackground(context, _draft.color);
    final titleDirection = directionOf(_draft.title);
    final bodyDirection = directionOf(_draft.body);
    final modified = _stored?.modified;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // _close keeps the editor open, with the error shown, if saving fails.
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          backgroundColor: background,
          leading: BackButton(onPressed: _close),
          actions: [
            IconButton(
              tooltip: _viewing ? 'Edit' : 'Preview',
              icon: Icon(
                _viewing ? Icons.edit_outlined : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() => _viewing = !_viewing),
            ),
            IconButton(
              tooltip: _draft.pinned ? 'Unpin' : 'Pin',
              icon: Icon(
                _draft.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              onPressed: () => _update((n) => n.copyWith(pinned: !n.pinned)),
            ),
            IconButton(
              tooltip: 'History',
              icon: const Icon(Icons.history),
              onPressed: _stored == null ? null : _history,
            ),
            PopupMenuButton<_EditorAction>(
              onSelected: (action) => switch (action) {
                _EditorAction.move => _move(),
                _EditorAction.delete => _delete(),
                _EditorAction.copy => Clipboard.setData(
                  ClipboardData(text: _draft.body),
                ),
              },
              itemBuilder: (context) => [
                for (final action in _EditorAction.values)
                  PopupMenuItem(value: action, child: Text(action.label)),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_saveError != null)
                MaterialBanner(
                  leading: Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.error,
                  ),
                  content: Text(
                    'Not saved: $_saveError\nYour text is still here.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: _discard,
                      child: const Text('Discard changes'),
                    ),
                    TextButton(onPressed: _close, child: const Text('Retry')),
                  ],
                ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: _viewing
                        ? _NoteView(
                            title: _draft.title,
                            body: _draft.body,
                            onDoubleTap: () => setState(() => _viewing = false),
                            onToggle: (line) => _body.text =
                                ChecklistItem.toggle(_body.text, line),
                          )
                        : _buildEditor(theme, titleDirection, bodyDirection),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: BottomAppBar(
          color: background,
          height: 56,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Background',
                icon: const Icon(Icons.palette_outlined),
                onPressed: _pickColor,
              ),
              IconButton(
                tooltip: 'Tags',
                icon: const Icon(Icons.label_outline),
                onPressed: _editTags,
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tag in _draft.tags)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _Pill(label: tag),
                        ),
                    ],
                  ),
                ),
              ),
              if (modified != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Edited ${formatDate(modified)}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(
    ThemeData theme,
    TextDirection titleDirection,
    TextDirection bodyDirection,
  ) {
    const noBorder = InputDecoration(
      border: InputBorder.none,
      focusedBorder: InputBorder.none,
      enabledBorder: InputBorder.none,
      filled: false,
    );
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        TextField(
          controller: _title,
          textDirection: titleDirection,
          style: theme.textTheme.titleLarge,
          maxLines: null,
          textInputAction: TextInputAction.next,
          decoration: noBorder.copyWith(
            hintText: 'Title',
            hintTextDirection: titleDirection,
          ),
        ),
        TextField(
          controller: _body,
          autofocus: widget.note == null,
          textDirection: bodyDirection,
          style: theme.textTheme.bodyLarge,
          maxLines: null,
          minLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: noBorder.copyWith(
            hintText: 'Note',
            hintTextDirection: bodyDirection,
          ),
        ),
        if (_stored != null && _stored!.folder.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _Pill(icon: Icons.folder_outlined, label: _stored!.folder),
            ),
          ),
      ],
    );
  }
}

/// A note's title and Markdown body, read-only and selectable.
class _NoteView extends StatelessWidget {
  const _NoteView({
    required this.title,
    required this.body,
    this.onToggle,
    this.onDoubleTap,
  });

  final String title;
  final String body;
  final ValueChanged<int>? onToggle;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (title.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              title,
              textDirection: directionOf(title),
              style: context.theme.textTheme.titleLarge,
            ),
          ),
        GestureDetector(
          onDoubleTap: onDoubleTap,
          child: MarkdownView(text: body, onToggle: onToggle),
        ),
      ],
    ),
  );
}

String formatDate(DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return time;
  }
  return '${local.year}-${two(local.month)}-${two(local.day)} $time';
}

class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.initial, required this.known});

  final List<String> initial;
  final List<String> known;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final List<String> _tags = [...widget.initial];
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add(String raw) {
    for (final tag in raw.split(',').map((t) => t.trim())) {
      if (tag.isNotEmpty && !_tags.contains(tag)) _tags.add(tag);
    }
    _input.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.known.where((t) => !_tags.contains(t)).toList();
    return AlertDialog(
      title: const Text('Tags'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in _tags)
                  InputChip(
                    label: Text(tag, textDirection: directionOf(tag)),
                    onDeleted: () => setState(() => _tags.remove(tag)),
                  ),
              ],
            ),
            TextField(
              controller: _input,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Add tag'),
              onSubmitted: _add,
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in suggestions)
                    ActionChip(
                      label: Text(tag, textDirection: directionOf(tag)),
                      onPressed: () => _add(tag),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_input.text.trim().isNotEmpty) _add(_input.text);
            Navigator.pop(context, _tags);
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// History (read-only)

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.controller, required this.note});

  final AppController controller;
  final Note note;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  NoteHistory? _history;
  StreamSubscription<void>? _subscription;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open()); // Shows its own error.
  }

  Future<void> _open() async {
    try {
      final history = await widget.controller.openHistory(widget.note);
      _subscription = history.changes.listen((_) {
        if (mounted) setState(() {});
      });
      await history.load();
      if (mounted) setState(() => _history = history);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_history?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final history = _history;
    final version = history?.current;
    final shown = version?.note;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (shown != null)
            IconButton(
              tooltip: 'Copy this version',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: shown.body));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
            ),
        ],
      ),
      body: switch ((_error, history)) {
        (final String error, _) => Center(child: Text(error)),
        (_, null) => const Center(child: CircularProgressIndicator()),
        (_, NoteHistory(isEmpty: true)) => const Center(
          child: Text('This note has no committed history yet.'),
        ),
        (_, final NoteHistory history) => Column(
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              child: ListTile(
                leading: Icon(
                  history.isLatest ? Icons.check_circle_outline : Icons.history,
                ),
                title: Text(
                  version!.revision.message,
                  textDirection: directionOf(version.revision.message),
                ),
                subtitle: Text(
                  '${formatDate(version.revision.date)} · ${version.revision.author} · '
                  '${version.revision.shortCommit} · '
                  '${history.revisions.length - history.index} of ${history.revisions.length}',
                ),
              ),
            ),
            Expanded(
              child: Container(
                color: shown == null
                    ? null
                    : noteBackground(context, shown.color),
                width: double.infinity,
                child: shown == null
                    ? const Center(
                        child: Text(
                          'The note does not exist in this version (deleted).',
                        ),
                      )
                    : _NoteView(title: shown.title, body: shown.body),
              ),
            ),
          ],
        ),
      },
      bottomNavigationBar: history == null || history.isEmpty
          ? null
          : BottomAppBar(
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: history.canGoBack ? history.back : null,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Older'),
                  ),
                  TextButton.icon(
                    onPressed: history.canGoForward ? history.forward : null,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Newer'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: history.isLatest ? null : history.latest,
                    icon: const Icon(Icons.vertical_align_top),
                    label: const Text('Go to latest'),
                  ),
                ],
              ),
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// Settings

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get c => widget.controller;
  late final _remote = _field(c.settings.remoteUrl);
  late final _branch = _field(c.settings.branch);
  late final _username = _field(c.settings.auth.username);
  late final _password = _field(c.settings.auth.password);
  late final _sshKey = _field(c.settings.auth.sshKeyPath);
  late final _sshPassphrase = _field(c.settings.auth.sshPassphrase);
  late final _authorName = _field(c.settings.authorName);
  late final _authorEmail = _field(c.settings.authorEmail);
  final _fields = <TextEditingController>[];

  /// A text field controller, disposed with the page.
  TextEditingController _field(String? text) {
    final field = TextEditingController(text: text ?? '');
    _fields.add(field);
    return field;
  }

  late AuthMethod _method = c.settings.auth.method;
  bool _busy = false;
  bool _showPassword = false;

  /// Why the settings cannot be applied, shown above the Save button.
  List<String> _problems = const [];

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  String? _nonEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  AppSettings get _next => AppSettings(
    remoteUrl: _remote.text.trim(),
    branch: _nonEmpty(_branch.text) ?? _defaults.branch,
    // Only the selected method's fields are kept, so switching from a
    // token to SSH does not leave the token stored.
    auth: switch (_method) {
      AuthMethod.none => const GitAuth(),
      AuthMethod.sshAgent => const GitAuth(method: AuthMethod.sshAgent),
      AuthMethod.httpsToken => GitAuth(
        method: AuthMethod.httpsToken,
        username: _nonEmpty(_username.text) ?? defaultHttpsUser,
        password: _password.text.isEmpty ? null : _password.text,
      ),
      AuthMethod.sshKey => GitAuth(
        method: AuthMethod.sshKey,
        sshKeyPath: _nonEmpty(_sshKey.text),
        sshPassphrase: _sshPassphrase.text.isEmpty ? null : _sshPassphrase.text,
      ),
    },
    authorName: _nonEmpty(_authorName.text) ?? _defaults.authorName,
    authorEmail: _nonEmpty(_authorEmail.text) ?? _defaults.authorEmail,
  );

  static const _defaults = AppSettings();

  Future<void> _apply() async {
    final next = _next;
    final problems = c.validate(next);
    setState(() => _problems = problems);
    if (problems.isNotEmpty) return;
    var keepBackup = true;
    if (c.ready && c.replacesRepository(next)) {
      final check = await c.checkRemoteChange();
      if (!mounted) return;
      final confirmed = await confirm(
        context,
        icon: Icons.warning_amber,
        title: 'Replace repository?',
        action: 'Replace',
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                'Notes will be replaced by a fresh clone of\n'
                '${next.remoteUrl} (${next.branch}).\n',
              ),
              if (check.hasUncommittedChanges)
                const Text(
                  '• The current notes folder has uncommitted changes.',
                ),
              if (check.unpushedCommits > 0)
                Text(
                  '• ${check.unpushedCommits} local commit(s) have not been '
                  'pushed to ${check.currentUrl}.',
                ),
              if (!check.losesData)
                const Text('Everything has been pushed; nothing will be lost.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: keepBackup,
                onChanged: (v) => setDialogState(() => keepBackup = v ?? true),
                title: const Text('Keep a backup of the current notes folder'),
              ),
            ],
          ),
        ),
      );
      if (!confirmed) return;
    }
    setState(() => _busy = true);
    try {
      final backup = await c.applySettings(next, keepBackup: keepBackup);
      if (!c.ready) await c.init();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            backup == null
                ? 'Settings saved'
                : 'Settings saved. Backup: $backup',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      // Keep the form open and say why, e.g. a refused clone.
      if (mounted) {
        setState(() => _problems = [c.lastError ?? 'Could not apply settings']);
        c.clearError();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(
      TextEditingController controller,
      String label, {
      String? hint,
      bool obscure = false,
      Widget? suffix,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            border: const OutlineInputBorder(),
            suffixIcon: suffix,
          ),
        ),
      );
    }

    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: context.theme.textTheme.titleSmall),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              heading('Repository'),
              field(
                _remote,
                'Remote URL',
                hint: 'Empty for local only. Local path, https://… or git@host:repo.git',
              ),
              field(_branch, 'Branch'),
              heading('Authentication'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<AuthMethod>(
                  key: const ValueKey('auth-method'),
                  initialValue: _method,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final method in AuthMethod.values)
                      DropdownMenuItem(
                        value: method,
                        child: Text(authMethodLabel(method)),
                      ),
                  ],
                  onChanged: (method) => setState(() {
                    _method = method ?? AuthMethod.none;
                    if (_method == AuthMethod.httpsToken &&
                        _username.text.trim().isEmpty) {
                      _username.text = defaultHttpsUser;
                    }
                  }),
                ),
              ),
              if (_method == AuthMethod.httpsToken) ...[
                field(
                  _username,
                  'User name',
                  hint: '$defaultHttpsUser works for GitHub, GitLab and others',
                ),
                field(
                  _password,
                  'Access token',
                  obscure: !_showPassword,
                  suffix: IconButton(
                    tooltip: _showPassword ? 'Hide' : 'Show',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ],
              if (_method == AuthMethod.sshKey) ...[
                field(
                  _sshKey,
                  'Private key path',
                  hint: 'For example ~/.ssh/id_ed25519 (not the .pub file)',
                ),
                field(_sshPassphrase, 'Key passphrase', obscure: true),
              ],
              if (_method == AuthMethod.sshKey ||
                  _method == AuthMethod.sshAgent)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'The URL names the SSH user, e.g. git@github.com:me/notes.git.',
                    style: context.theme.textTheme.bodySmall,
                  ),
                ),
              heading('Commit author'),
              field(_authorName, 'Name'),
              field(_authorEmail, 'Email'),
              const SizedBox(height: 8),
              SelectableText(
                'Notes folder: ${c.dataDir}',
                style: context.theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              for (final problem in _problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    problem,
                    style: TextStyle(color: context.colors.error),
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  onPressed: _busy ? null : _apply,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
