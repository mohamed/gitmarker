// UI-independent workflows. Pure Dart: the UI listens to [AppController.changes]
// and calls its methods; nothing here imports Flutter.

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:path/path.dart' as p;

import 'bidi.dart';
import 'git.dart';
import 'note_models.dart';
import 'note_store.dart';

/// Settings that cannot work, rejected before the repository is touched.
class SettingsException implements Exception {
  SettingsException(this.problems);

  final List<String> problems;

  @override
  String toString() => problems.join('\n');
}

class AppController {
  AppController({
    required this.supportDir,
    DateTime Function()? clock,
    this.networkTimeout = GitBackend.defaultNetworkTimeout,
  }) : _clock = clock ?? DateTime.now;

  /// Platform application-support directory.
  final String supportDir;
  final DateTime Function() _clock;

  /// Limit for clone, sync and force push (see [GitBackend.networkTimeout]).
  final Duration networkTimeout;

  static const String dataDirName = 'gitmarker_data';
  static const String settingsFileName = 'gitmarker_settings.json';
  static const String knownHostsFileName = 'gitmarker_known_hosts.json';

  String get dataDir => p.join(supportDir, dataDirName);
  String get settingsPath => p.join(supportDir, settingsFileName);

  GitBackend _gitFor(AppSettings settings) => GitBackend(
    auth: settings.auth,
    authorName: settings.authorName,
    authorEmail: settings.authorEmail,
    knownHostsPath: p.join(supportDir, knownHostsFileName),
    networkTimeout: networkTimeout,
  );

  late GitBackend _git;
  late final NoteStore _store = NoteStore(dataDir);
  late final SettingsFile _settingsFile = SettingsFile(settingsPath);

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever any observable state changes.
  Stream<void> get changes => _changes.stream;

  // ---------------------------------------------------------------------------
  // Observable state

  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;

  List<Note> _notes = const [];
  List<Note> get notes => _notes;

  List<String> _folders = const [];

  /// All folders, including ones that only contain other folders.
  List<String> get folders => _folders;

  bool _ready = false;
  bool get ready => _ready;

  /// Set when initialization failed (e.g. Git missing or clone failed).
  String? _fatalError;
  String? get fatalError => _fatalError;

  /// Transient error from the last operation, for a snackbar.
  String? _lastError;
  String? get lastError => _lastError;
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  bool _syncing = false;
  bool get syncing => _syncing;

  SyncResult? _lastSync;
  SyncResult? get lastSync => _lastSync;

  /// True while a sync is paused on a conflict, until [resolveConflict].
  bool get syncPaused => _lastSync?.outcome == SyncOutcome.conflict;

  String _query = '';
  String get query => _query;
  set query(String value) {
    if (value == _query) return;
    _query = value;
    _notify();
  }

  /// Folder filter: null shows all notes, '' shows only the root folder.
  String? _folderFilter;
  String? get folderFilter => _folderFilter;

  String? _tagFilter;
  String? get tagFilter => _tagFilter;

  void showAll() => _setFilters(null, null);
  void showFolder(String folder) => _setFilters(folder, null);
  void showTag(String tag) => _setFilters(null, tag);

  /// Colour filter, combined with the folder/tag filter and the search;
  /// null shows every colour.
  NoteColor? _colorFilter;
  NoteColor? get colorFilter => _colorFilter;
  set colorFilter(NoteColor? value) {
    if (value == _colorFilter) return;
    _colorFilter = value;
    _notify();
  }

  void _setFilters(String? folder, String? tag) {
    _folderFilter = folder;
    _tagFilter = tag;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() => _changes.close();

  // ---------------------------------------------------------------------------
  // Derived views

  List<String> get tags {
    final all = <String>{for (final n in _notes) ...n.tags}.toList();
    all.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return all;
  }

  /// Notes matching the active folder, tag and search filters, most
  /// recently modified first.
  List<Note> get visibleNotes {
    final terms = normalizeForSearch(_query)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final result = _notes.where((note) {
      if (_folderFilter != null) {
        final f = _folderFilter!;
        if (!(note.folder == f ||
            (f.isNotEmpty && note.folder.startsWith('$f/')))) {
          return false;
        }
      }
      if (_tagFilter != null && !note.tags.contains(_tagFilter)) return false;
      if (_colorFilter != null && note.color != _colorFilter) return false;
      if (terms.isEmpty) return true;
      final haystack = normalizeForSearch(
        '${note.title}\n${note.body}\n${note.tags.join(' ')}\n${note.path}',
      );
      return terms.every(haystack.contains);
    }).toList();
    result.sort((a, b) {
      final am = a.modified ?? a.created;
      final bm = b.modified ?? b.created;
      if (am != null && bm != null) return bm.compareTo(am);
      if (am != null) return -1;
      if (bm != null) return 1;
      return a.path.compareTo(b.path);
    });
    return result;
  }

  List<Note> get pinnedNotes => visibleNotes.where((n) => n.pinned).toList();
  List<Note> get otherNotes => visibleNotes.where((n) => !n.pinned).toList();

  // ---------------------------------------------------------------------------
  // Serialization of Git/file operations

  Future<void> _tail = Future.value();

  /// Runs [action] after all previously queued operations, so Git commands
  /// never overlap.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<T> _guarded<T>(Future<T> Function() action) {
    return _serialized(() async {
      try {
        return await action();
      } catch (e) {
        _lastError = describeError(e);
        _notify();
        rethrow;
      }
    });
  }

  /// A user-facing message for an error from any operation.
  static String describeError(Object e) => switch (e) {
    GitException() => 'Git ${e.operation} failed: ${e.message}',
    SettingsException() => e.problems.join('\n'),
    NoteStoreException() => e.message,
    FileSystemException() =>
      '${e.message}${e.path == null ? '' : ': ${e.path}'}',
    _ => e.toString(),
  };

  // ---------------------------------------------------------------------------
  // Startup

  /// Loads settings and opens (or creates/clones) the notes repository.
  Future<void> init() => _serialized(() async {
    try {
      await NoteStore.createPrivateDirectory(supportDir);
      _settings = await _settingsFile.load();
      _git = _gitFor(_settings);
      await _openRepository();
      await _reload();
      _ready = true;
      _fatalError = null;
    } catch (e) {
      _fatalError = describeError(e);
    }
    _notify();
  });

  Future<void> _openRepository() async {
    if (await _git.isRepository(dataDir)) {
      final current = await _git.remoteUrl(dataDir) ?? '';
      if (current != _settings.remoteUrl.trim()) {
        await _git.setRemoteUrl(dataDir, _settings.remoteUrl);
      }
      return;
    }
    final hasFiles = await _store.hasFiles();
    if (_settings.hasRemote && !hasFiles) {
      await _git.clone(_settings.remoteUrl, dataDir, branch: _settings.branch);
    } else {
      // Empty directory, or existing Markdown files not yet under Git.
      await _git.init(dataDir, branch: _settings.branch);
      if (_settings.hasRemote) {
        await _git.setRemoteUrl(dataDir, _settings.remoteUrl);
      }
      if (hasFiles) await _git.commit(dataDir, 'Import existing notes');
    }
  }

  /// Reloads notes and folders. The store reuses files it already parsed;
  /// [rescan] drops that cache, for when Git or the user changed the
  /// working tree behind its back.
  Future<void> _reload({bool rescan = false}) async {
    if (rescan) _store.clearCache();
    _notes = await _store.loadAll();
    _folders = _store.folders;
  }

  /// Markdown files skipped by the last reload because their front matter
  /// is malformed (or they cannot be read), with the reason for each.
  List<SkippedFile> get skippedFiles => _ready ? _store.skipped : const [];

  /// Re-reads notes from disk (e.g. after external edits). Without
  /// [rescan], only files whose modification time or size changed are
  /// parsed again, which makes it cheap enough to run on every app resume.
  Future<void> refresh({bool rescan = true}) => _guarded(() async {
    await _reload(rescan: rescan);
    _notify();
  });

  // ---------------------------------------------------------------------------
  // Note operations. Each one commits its change.

  Future<Note> createNote({
    String title = '',
    String body = '',
    String? folder,
    bool pinned = false,
    NoteColor color = NoteColor.none,
    List<String> tags = const [],
  }) => _change(
    () => _store.create(
      title: title,
      body: body,
      folder: folder ?? _folderFilter ?? '',
      pinned: pinned,
      color: color,
      tags: tags.isEmpty && _tagFilter != null ? [_tagFilter!] : tags,
      now: _clock(),
    ),
    (note) => 'Create note: ${_label(note!)}',
  ).then((note) => note!);

  /// Saves [edited] over [original]. Returns the stored note (its path can
  /// change when a plain note is renamed). Unchanged notes are not written.
  Future<Note> saveNote(Note edited, {required Note original}) async {
    if (edited.sameContentAs(original)) return original;
    final note = await _change(
      () => _store.save(edited, original: original, now: _clock()),
      (note) => 'Update note: ${_label(note!)}',
    );
    return note!;
  }

  Future<void> deleteNote(Note note) =>
      _change(() => _store.delete(note), (_) => 'Delete note: ${_label(note)}');

  /// Undoes [deleteNote]: writes [note] back as it was and commits it.
  Future<Note> restoreNote(Note note) => _change(
    () => _store.restore(note),
    (restored) => 'Restore note: ${_label(restored!)}',
  ).then((note) => note!);

  Future<Note> moveNote(Note note, String folder) => _change(
    () => _store.move(note, folder),
    (moved) =>
        'Move note: ${_label(note)} to '
        '${moved!.folder.isEmpty ? '/' : moved.folder}',
  ).then((note) => note!);

  Future<void> createFolder(String folder) => _change(
    () => _store.createFolder(folder),
    (_) => 'Create folder: ${NoteStore.normalizeFolder(folder)}',
  );

  /// Commits everything in the working tree (external edits included).
  Future<bool> commitPendingChanges() => _guarded(() async {
    final committed = await _git.commit(dataDir, 'Commit pending changes');
    await _reload();
    _notify();
    return committed;
  });

  /// Runs a store operation, commits the paths it wrote with the message
  /// [describe] gives for its note, and reloads.
  Future<Note?> _change(
    Future<StoreChange> Function() write,
    String Function(Note? note) describe,
  ) => _guarded(() async {
    final change = await write();
    if (change.paths.isNotEmpty) {
      await _git.commit(dataDir, describe(change.note), paths: change.paths);
    }
    await _reload();
    _notify();
    return change.note;
  });

  static String _label(Note note) {
    final title = note.title.trim();
    return title.isEmpty ? note.path : title.split('\n').first;
  }

  // ---------------------------------------------------------------------------
  // Synchronization

  /// Fetches the configured branch and integrates it (see
  /// [GitBackend.sync]). A conflict pauses sync ([syncPaused]) until
  /// [resolveConflict] is called.
  Future<SyncResult> sync() => _serialized(() async {
    if (syncPaused) return _lastSync!;
    if (!_settings.hasRemote) {
      return _finishSync(const SyncResult(SyncOutcome.noRemote));
    }
    _syncing = true;
    _notify();
    try {
      final result = await _git.sync(dataDir, _settings.branch);
      await _reload(rescan: true);
      return _finishSync(result);
    } catch (e) {
      return _finishSync(
        SyncResult(SyncOutcome.error, message: describeError(e)),
      );
    }
  });

  SyncResult _finishSync(SyncResult result) {
    _lastSync = result;
    _syncing = false;
    _notify();
    return result;
  }

  /// Resolves a paused sync.
  Future<SyncResult> resolveConflict(ConflictResolution resolution) =>
      _serialized(() async {
        if (!syncPaused) {
          return _lastSync ?? const SyncResult(SyncOutcome.upToDate);
        }
        try {
          final result = await _git.resolve(
            dataDir,
            _settings.branch,
            resolution,
          );
          await _reload(rescan: true);
          return _finishSync(result);
        } catch (e) {
          // Stay paused so the user can pick another resolution.
          _lastError = describeError(e);
          _notify();
          rethrow;
        }
      });

  // ---------------------------------------------------------------------------
  // Settings and remote replacement

  /// Everything wrong with [next] (see [validateGitSettings]), checked the
  /// way [applySettings] will apply it.
  List<String> validate(AppSettings next) =>
      validateGitSettings(_normalized(next));

  /// [next] as it is stored: SSH URLs get their default user, the branch
  /// is trimmed.
  static AppSettings _normalized(AppSettings next) => next.copyWith(
    remoteUrl: withSshUser(next.remoteUrl),
    branch: next.branch.trim(),
  );

  /// True when applying [next] replaces the repository (clone) rather than
  /// just updating settings.
  bool replacesRepository(AppSettings next) {
    if (!_settings.hasRemote || !next.hasRemote) return false;
    return next.remoteUrl.trim() != _settings.remoteUrl.trim() ||
        next.branch != _settings.branch;
  }

  /// What would be lost by replacing the repository, for the confirmation
  /// dialog.
  Future<RemoteChangeCheck> checkRemoteChange() => _serialized(() async {
    final status = await _git.status(dataDir, _settings.branch);
    return RemoteChangeCheck(
      currentUrl: _settings.remoteUrl,
      hasUncommittedChanges: !status.clean,
      unpushedCommits: status.unpushed,
    );
  });

  /// Applies new settings.
  ///
  /// * Same remote and branch: settings (credentials, author) are saved.
  /// * Local-only → remote: `origin` is added; the next sync merges or pushes.
  /// * Remote → none: `origin` is removed, notes stay.
  /// * Remote → another remote or branch: the new remote is cloned and
  ///   replaces the data directory. The previous directory is moved to a
  ///   backup when [keepBackup] is true and deleted otherwise. The UI must
  ///   confirm this first (see [checkRemoteChange]).
  ///
  /// Returns the backup directory, if one was made.
  Future<String?> applySettings(AppSettings next, {bool keepBackup = true}) =>
      _guarded(() async {
        final normalized = _normalized(next);
        final problems = validateGitSettings(normalized);
        if (problems.isNotEmpty) throw SettingsException(problems);
        if (!_ready) {
          // Startup failed (e.g. the clone was refused): store the settings;
          // the caller retries with init().
          await _settingsFile.save(normalized);
          _settings = normalized;
          _notify();
          return null;
        }
        final replace = replacesRepository(normalized);
        final git = _gitFor(normalized);
        String? backup;
        if (replace) {
          backup = await _replaceRepository(
            git,
            normalized,
            keepBackup: keepBackup,
          );
        } else {
          await git.setRemoteUrl(dataDir, normalized.remoteUrl);
        }
        await _settingsFile.save(normalized);
        _settings = normalized;
        _git = git;
        _lastSync = null;
        await _reload(rescan: true);
        _notify();
        return backup;
      });

  Future<String?> _replaceRepository(
    GitBackend git,
    AppSettings next, {
    required bool keepBackup,
  }) async {
    // Clone next to the data directory first, so a failed clone (bad URL,
    // credentials) leaves the current notes untouched.
    final incoming = p.join(supportDir, '$dataDirName.incoming');
    await NoteStore.deleteDirectory(incoming);
    try {
      await git.clone(next.remoteUrl, incoming, branch: next.branch);
    } catch (_) {
      await NoteStore.deleteDirectory(incoming);
      rethrow;
    }
    return _store.replaceWith(incoming, backupAt: keepBackup ? _clock() : null);
  }

  // ---------------------------------------------------------------------------
  // History

  /// Opens a read-only history navigator for [note], positioned on the
  /// latest revision.
  Future<NoteHistory> openHistory(Note note) => _guarded(() async {
    final revisions = await _git.fileHistory(dataDir, note.path);
    return NoteHistory._(this, note, revisions);
  });

  Future<NoteVersion> _loadVersion(NoteRevision revision) async {
    final content = await _serialized(
      () => _git.showFile(dataDir, revision.commit, revision.path),
    );
    return NoteVersion(
      revision: revision,
      note: content == null ? null : NoteStore.parse(revision.path, content),
    );
  }
}

/// Read-only navigation through a note's Git history. Index 0 is the latest
/// revision; [back] moves to older revisions, [forward] to newer ones.
class NoteHistory {
  NoteHistory._(this._controller, this.note, this.revisions);

  final AppController _controller;

  /// The note as currently stored (the "latest" state).
  final Note note;

  /// Revisions touching the note, newest first. Empty for a note that was
  /// never committed.
  final List<NoteRevision> revisions;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  final Map<String, NoteVersion> _cache = {};

  int _index = 0;
  int get index => _index;

  NoteVersion? _current;

  /// The version being shown; null until [load] completes.
  NoteVersion? get current => _current;

  bool get isEmpty => revisions.isEmpty;
  bool get isLatest => _index == 0;
  bool get canGoBack => _index < revisions.length - 1;
  bool get canGoForward => _index > 0;

  /// Loads the version at the current index.
  Future<void> load() => _goTo(_index);

  Future<void> back() => canGoBack ? _goTo(_index + 1) : Future.value();
  Future<void> forward() => canGoForward ? _goTo(_index - 1) : Future.value();
  Future<void> latest() => _goTo(0);

  Future<void> _goTo(int index) async {
    if (revisions.isEmpty) return;
    _index = index;
    final revision = revisions[index];
    final version = _cache[revision.commit] ??= await _controller._loadVersion(
      revision,
    );
    if (_index == index) {
      _current = version;
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  Future<void> dispose() => _changes.close();
}
