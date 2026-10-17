// Markdown + YAML front matter persistence. Pure Dart (dart:io), no Flutter.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'note_models.dart';

class NoteStoreException implements Exception {
  NoteStoreException(this.message);
  final String message;
  @override
  String toString() => 'NoteStoreException: $message';
}

/// Changes written to disk by a store operation, relative to the root.
/// The controller commits exactly these paths.
class StoreChange {
  const StoreChange(this.note, this.paths);
  final Note? note;
  final List<String> paths;
}

/// The application settings file (JSON), written atomically.
class SettingsFile {
  SettingsFile(this.path);

  final String path;

  /// The stored settings; the defaults when the file is missing or is not
  /// valid JSON.
  Future<AppSettings> load() async {
    final file = File(path);
    if (!await file.exists()) return const AppSettings();
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map) return AppSettings.fromJson(json.cast());
    } on FormatException {
      // Corrupt settings: fall back to defaults.
    }
    return const AppSettings();
  }

  /// Holds the HTTPS token and SSH passphrase, so on Linux and macOS it is
  /// readable by its owner only (`chmod 600`), set before anything is
  /// written to it. Windows, Android and iOS keep app data per user.
  Future<void> save(AppSettings settings) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString('');
    await NoteStore.restrictToOwner(tmp.path);
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await tmp.rename(path);
  }
}

class NoteStore {
  NoteStore(this.root);

  /// Absolute path of the notes repository working tree.
  final String root;

  /// Directory names never scanned for notes.
  static const Set<String> excludedDirs = {'.git', '.gitmarker'};

  /// True for `.git` / `.gitmarker` in any letter case: on case-insensitive
  /// file systems (macOS, Windows) `.GIT` *is* the `.git` directory.
  static bool isReservedName(String name) =>
      excludedDirs.contains(name.toLowerCase());

  /// Longest file name stem in UTF-8 bytes. Most file systems allow 255
  /// bytes per name; this leaves room for ` (99)` and `.md`.
  static const int maxStemBytes = 120;

  static const String folderKeepFile = '.gitkeep';

  /// Larger `.md` files are listed as skipped instead of being loaded: a
  /// notes app has no use for them, and reading them would cost the memory.
  static const int maxNoteBytes = 10 * 1024 * 1024;

  /// Most values (list items, map entries) front matter may expand to.
  /// YAML aliases let a few lines stand for millions of values ("billion
  /// laughs"), which would exhaust memory when copied out.
  static const int _maxFrontMatterValues = 10000;

  /// Limits checked before the YAML parser sees front matter: it recurses
  /// per nesting level, and 100,000 nested `[` take minutes to overflow
  /// its stack.
  static const int _maxFrontMatterBytes = 64 * 1024;
  static const int _maxFrontMatterDepth = 100;

  /// Deepest `[`/`{` nesting in [yaml] (brackets inside quotes count too,
  /// which only matters for absurd values).
  static int _flowDepth(String yaml) {
    var depth = 0, deepest = 0;
    for (final c in yaml.codeUnits) {
      if (c == 0x5B || c == 0x7B) {
        if (++depth > deepest) deepest = depth;
      } else if ((c == 0x5D || c == 0x7D) && depth > 0) {
        depth--;
      }
    }
    return deepest;
  }

  static const Set<String> _knownKeys = {
    'title',
    'pinned',
    'color',
    'tags',
    'created',
    'modified',
  };

  // ---------------------------------------------------------------------------
  // Parsing and serialization

  /// Parses a note file. Returns null when the front matter is malformed
  /// (unterminated, invalid YAML, or not a mapping); such files are skipped.
  static Note? parse(String path, String content) {
    try {
      return parseOrThrow(path, content);
    } on FormatException {
      return null;
    }
  }

  /// Like [parse], but throws a [FormatException] saying why the file is
  /// not a note.
  static Note parseOrThrow(String path, String content) {
    var text = content.startsWith('\uFEFF') ? content.substring(1) : content;
    text = text.replaceAll('\r\n', '\n');
    final stem = p.posix.basenameWithoutExtension(path);

    if (!(text == '---' || text.startsWith('---\n'))) {
      return _parsePlain(path, stem, text);
    }

    final lines = text.split('\n');
    var close = -1;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line == '---' || line == '...') {
        close = i;
        break;
      }
    }
    if (close < 0) {
      throw const FormatException('front matter is not closed with ---');
    }

    final yamlText = lines.sublist(1, close).join('\n');
    if (yamlText.length > _maxFrontMatterBytes) {
      throw const FormatException('front matter is larger than 64 KB');
    }
    if (_flowDepth(yamlText) > _maxFrontMatterDepth) {
      throw const FormatException('front matter is nested too deeply');
    }
    Map<String, Object?> meta;
    try {
      final doc = yamlText.trim().isEmpty ? null : loadYaml(yamlText);
      if (doc == null) {
        meta = {};
      } else if (doc is YamlMap) {
        final budget = [_maxFrontMatterValues];
        meta = {
          for (final e in doc.entries)
            e.key.toString(): _plain(e.value, budget),
        };
      } else {
        throw const FormatException('front matter is not a list of key: value');
      }
    } on YamlException catch (e) {
      final detail = e.message.trim().replaceFirst(RegExp(r'\.+$'), '');
      throw FormatException('front matter is not valid YAML ($detail)');
    } on StackOverflowError {
      throw const FormatException('front matter is nested too deeply');
    }

    var body = lines.sublist(close + 1).join('\n');
    // serialize() puts one blank line between front matter and body.
    if (body.startsWith('\n')) body = body.substring(1);

    final title = meta['title'];
    return Note(
      path: path,
      title: title == null ? stem : title.toString(),
      body: body,
      format: NoteFormat.managed,
      pinned: meta['pinned'] == true,
      color: NoteColor.parse(meta['color']),
      tags: _parseTags(meta['tags']),
      created: _parseDate(meta['created']),
      modified: _parseDate(meta['modified']),
      extraFrontMatter: {
        for (final e in meta.entries)
          if (!_knownKeys.contains(e.key)) e.key: e.value,
      },
    );
  }

  static final RegExp _titleHeading = RegExp(r'^#[ \t]+(.*?)[ \t]*#*[ \t]*$');

  /// A plain note whose first non-blank line is a level-1 heading takes it
  /// as its title; the body is what follows. Otherwise the file name is the
  /// title and the whole file is the body.
  static Note _parsePlain(String path, String stem, String text) {
    final lines = text.split('\n');
    final first = lines.indexWhere((l) => l.trim().isNotEmpty);
    final heading = first < 0 ? null : _titleHeading.firstMatch(lines[first]);
    if (heading == null || heading.group(1)!.trim().isEmpty) {
      return Note(
        path: path,
        title: stem,
        body: text,
        format: NoteFormat.plain,
      );
    }
    var rest = lines.sublist(first + 1);
    final start = rest.indexWhere((l) => l.trim().isNotEmpty);
    rest = start < 0 ? const [] : rest.sublist(start);
    return Note(
      path: path,
      title: heading.group(1)!.trim(),
      body: rest.join('\n'),
      format: NoteFormat.plain,
      titleInHeading: true,
    );
  }

  /// Renders a note to file content. Plain notes are written as their body,
  /// preceded by `# <title>` when the title lives in a heading.
  static String serialize(Note note) {
    if (note.format == NoteFormat.plain) {
      final title = note.title.trim();
      if (!note.titleInHeading || title.isEmpty) return note.body;
      return note.body.isEmpty ? '# $title\n' : '# $title\n\n${note.body}';
    }
    final out = StringBuffer('---\n');
    out.writeln('title: ${_yamlScalar(note.title)}');
    if (note.tags.isNotEmpty) {
      out.writeln('tags: [${note.tags.map(_yamlScalar).join(', ')}]');
    }
    if (note.pinned) out.writeln('pinned: true');
    if (note.color != NoteColor.none) out.writeln('color: ${note.color.name}');
    if (note.created != null) {
      out.writeln('created: ${note.created!.toUtc().toIso8601String()}');
    }
    if (note.modified != null) {
      out.writeln('modified: ${note.modified!.toUtc().toIso8601String()}');
    }
    for (final e in note.extraFrontMatter.entries) {
      out.writeln('${_yamlKey(e.key)}: ${_yamlValue(e.value)}');
    }
    out.write('---\n\n');
    out.write(note.body);
    return out.toString();
  }

  /// [value] as plain Dart maps and lists, spending one unit of [budget]
  /// (a single-element list, shared by the whole front matter) per value.
  static Object? _plain(Object? value, List<int> budget) {
    if (--budget[0] < 0) {
      throw const FormatException('front matter is too large');
    }
    if (value is YamlMap) {
      return {
        for (final e in value.entries)
          e.key.toString(): _plain(e.value, budget),
      };
    }
    if (value is YamlList) return [for (final v in value) _plain(v, budget)];
    return value;
  }

  static List<String> _parseTags(Object? value) {
    Iterable<String> raw;
    if (value is List) {
      raw = value.where((v) => v != null).map((v) => v.toString());
    } else if (value is String) {
      raw = value.split(',');
    } else {
      return const [];
    }
    final seen = <String>{};
    return [
      for (final tag in raw.map((t) => t.trim()))
        if (tag.isNotEmpty && seen.add(tag)) tag,
    ];
  }

  static DateTime? _parseDate(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  static final RegExp _plainSafe = RegExp(
    r'^[\p{L}\p{N}][\p{L}\p{N}\p{M} _.\-/]*$',
    unicode: true,
  );
  static final RegExp _looksSpecial = RegExp(
    r'^(true|false|yes|no|on|off|null|~|[-+]?(\d[\d_]*)?(\.\d+)?([eE][-+]?\d+)?|0x[0-9a-fA-F]+|\d{4}-\d\d-\d\d.*)$',
    caseSensitive: false,
  );

  static String _yamlScalar(String value) {
    if (value.isNotEmpty &&
        value.trim() == value &&
        _plainSafe.hasMatch(value) &&
        !_looksSpecial.hasMatch(value)) {
      return value;
    }
    // JSON strings are valid YAML double-quoted scalars.
    return jsonEncode(value);
  }

  static String _yamlKey(String key) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_\-]*$').hasMatch(key)
      ? key
      : jsonEncode(key);

  /// Unknown front matter values: emitted as JSON, which YAML accepts as
  /// flow style.
  static String _yamlValue(Object? value) {
    if (value is String) return _yamlScalar(value);
    try {
      return jsonEncode(value, toEncodable: (v) => v.toString());
    } on JsonUnsupportedObjectError {
      return jsonEncode(value.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Paths

  String absolute(String relative) => p.joinAll([root, ...relative.split('/')]);

  /// Refuses [relative] when any part of it is a symbolic link. A cloned
  /// repository can contain links (`Work -> /home/me`); writing, moving or
  /// deleting a note through one would touch files outside the notes
  /// folder. The scan already ignores links.
  void _checkNoLinks(String relative) {
    var current = root;
    for (final part in relative.split('/')) {
      current = p.join(current, part);
      if (FileSystemEntity.isLinkSync(current)) {
        throw NoteStoreException(
          '"$relative" goes through a symbolic link; GitMarker only '
          'writes inside the notes folder.',
        );
      }
    }
  }

  String relative(String absolutePath) =>
      p.split(p.relative(absolutePath, from: root)).join('/');

  /// Validates a folder path relative to the root ('' is the root folder).
  static String normalizeFolder(String folder) {
    final parts = folder
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (final part in parts) {
      if (part == '.' || part == '..' || isReservedName(part)) {
        throw NoteStoreException('Invalid folder name "$part"');
      }
      if (_invalidFileChars.hasMatch(part)) {
        throw NoteStoreException(
          'Folder name "$part" contains invalid characters',
        );
      }
    }
    return parts.join('/');
  }

  static final RegExp _invalidFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

  /// Device names Windows reserves, with or without an extension
  /// (`CON.md` and `con.backup.md` are both unusable).
  static final RegExp _windowsDeviceName = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
    caseSensitive: false,
  );

  /// A file-system-safe name stem derived from a note title: Unicode
  /// letters (Arabic included) are kept, characters invalid on Windows,
  /// macOS or Linux are replaced, and the result fits in [maxStemBytes]
  /// UTF-8 bytes.
  static String fileNameFor(String title) {
    String tidy(String value) => value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    var name = tidy(title.split('\n').first.replaceAll(_invalidFileChars, '_'));
    if (utf8.encode(name).length > maxStemBytes) {
      final runes = name.runes.toList();
      var keep = runes.length;
      while (keep > 0 &&
          utf8.encode(String.fromCharCodes(runes.take(keep))).length >
              maxStemBytes) {
        keep--;
      }
      name = tidy(String.fromCharCodes(runes.take(keep)));
    }
    if (name.isEmpty) return 'Untitled';
    // CON → CON-note, con.backup → con-note.backup.
    return name.replaceFirstMapped(
      _windowsDeviceName,
      (m) => '${m[1]}-note${m[2]}',
    );
  }

  /// First free `<folder>/<name>.md` path. [except] is treated as free (the
  /// note's own current path when renaming).
  String uniquePath(String folder, String title, {String? except}) {
    final base = fileNameFor(title);
    final prefix = folder.isEmpty ? '' : '$folder/';
    for (var i = 1; ; i++) {
      final candidate = '$prefix${i == 1 ? base : '$base ($i)'}.md';
      if (candidate == except) return candidate;
      if (!_existsCaseInsensitive(candidate)) return candidate;
    }
  }

  /// Case-insensitive file systems (macOS, Windows) treat `A.md` and `a.md`
  /// as the same file, so uniqueness is checked case-insensitively.
  bool _existsCaseInsensitive(String relativePath) {
    final file = File(absolute(relativePath));
    if (file.existsSync()) return true;
    final dir = file.parent;
    if (!dir.existsSync()) return false;
    final name = p.basename(file.path).toLowerCase();
    return dir
        .listSync(followLinks: false)
        .any((e) => p.basename(e.path).toLowerCase() == name);
  }

  // ---------------------------------------------------------------------------
  // Reading

  /// Files skipped by the last [loadAll], with the reason.
  List<SkippedFile> get skipped => List.unmodifiable(_skipped);
  List<SkippedFile> _skipped = const [];

  /// Parsed files by path, reused while a file's modification time and size
  /// are unchanged.
  final Map<String, _CachedFile> _cache = {};

  /// Forgets every parsed file, e.g. after Git rewrote the working tree.
  void clearCache() => _cache.clear();

  /// Files the last [loadAll] actually read and parsed (the rest came from
  /// the cache).
  int get lastReadCount => _lastReadCount;
  int _lastReadCount = 0;

  /// Folders found by the last [loadAll], including empty ones.
  List<String> get folders => List.unmodifiable(_folders);
  List<String> _folders = const [];

  /// Recursively loads all `*.md` notes, skipping excluded directories and
  /// files with malformed front matter (listed in [skipped]). Files that did
  /// not change since the previous call are not re-read.
  ///
  /// The scan runs on a background isolate with synchronous file calls:
  /// for thousands of notes that is over ten times faster than Dart's
  /// asynchronous file API, and the UI never waits on it.
  Future<List<Note>> loadAll() async {
    final root = this.root;
    final previous = Map.of(_cache);
    final scan = await Isolate.run(() => _scan(root, previous));
    _cache
      ..clear()
      ..addAll(scan.cache);
    _skipped = scan.skipped;
    _folders = scan.folders;
    _lastReadCount = scan.readCount;
    return scan.notes;
  }

  static _Scan _scan(String root, Map<String, _CachedFile> previous) {
    final cache = <String, _CachedFile>{};
    final folders = <String>[];
    final dir = Directory(root);
    if (dir.existsSync()) _walk(dir, root, previous, cache, folders);
    final notes = <Note>[];
    final skipped = <SkippedFile>[];
    var read = 0;
    for (final entry in cache.entries) {
      if (!identical(entry.value, previous[entry.key])) read++;
      if (entry.value.note != null) notes.add(entry.value.note!);
      if (entry.value.error != null) {
        skipped.add(SkippedFile(entry.key, entry.value.error!));
      }
    }
    notes.sort((a, b) => a.path.compareTo(b.path));
    skipped.sort((a, b) => a.path.compareTo(b.path));
    folders.sort();
    return _Scan(notes, skipped, folders, cache, read);
  }

  static void _walk(
    Directory dir,
    String root,
    Map<String, _CachedFile> previous,
    Map<String, _CachedFile> cache,
    List<String> folders,
  ) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final path = p.split(p.relative(entity.path, from: root)).join('/');
      if (entity is Directory) {
        if (isReservedName(name)) continue;
        folders.add(path);
        _walk(entity, root, previous, cache, folders);
      } else if (entity is File && name.toLowerCase().endsWith('.md')) {
        cache[path] = _cachedSync(path, entity, previous[path]);
      }
    }
  }

  static _CachedFile _cachedSync(String path, File file, _CachedFile? hit) {
    final FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException catch (e) {
      return _CachedFile.failed('cannot be read (${e.message})');
    }
    if (hit != null && hit.matches(stat)) return hit;
    if (stat.size > maxNoteBytes) {
      return _CachedFile(
        stat,
        error: 'is larger than ${maxNoteBytes ~/ (1024 * 1024)} MB',
      );
    }
    try {
      final content = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
      final note = parseOrThrow(path, content);
      // Plain notes have no timestamps of their own: sort them by the
      // file's modification time.
      return _CachedFile(
        stat,
        note: note.format == NoteFormat.plain
            ? note.copyWith(modified: stat.modified)
            : note,
      );
    } on FormatException catch (e) {
      return _CachedFile(stat, error: e.message);
    } on FileSystemException catch (e) {
      return _CachedFile(stat, error: 'cannot be read (${e.message})');
    } on Object catch (e) {
      // Whatever goes wrong with one file must not stop the others from
      // loading.
      return _CachedFile(stat, error: 'cannot be parsed ($e)');
    }
  }

  // ---------------------------------------------------------------------------
  // Directories

  /// True when the root exists and contains anything.
  Future<bool> hasFiles() async {
    final dir = Directory(root);
    return await dir.exists() && !await dir.list().isEmpty;
  }

  /// Creates [path] (and its parents) if it does not exist.
  static Future<void> createDirectory(String path) =>
      Directory(path).create(recursive: true);

  /// Creates [path] if needed and makes it accessible to its owner only,
  /// so other accounts on a shared computer cannot read the notes or the
  /// settings in it.
  static Future<void> createPrivateDirectory(String path) async {
    await createDirectory(path);
    await restrictToOwner(path, directory: true);
  }

  /// `chmod 600` (`700` for a [directory]) on Linux and macOS; elsewhere
  /// app data is already per user. Best effort: a missing `chmod` (or a
  /// sandbox that refuses it) leaves the default permissions.
  static Future<void> restrictToOwner(
    String path, {
    bool directory = false,
  }) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    try {
      await Process.run('chmod', [directory ? '700' : '600', path]);
    } on ProcessException {
      // No chmod available.
    }
  }

  /// Deletes [path] and everything below it, if it exists.
  static Future<void> deleteDirectory(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Puts the directory [incoming] in place of the root. The previous root
  /// is moved to `<root>_backup_<backupAt>` when [backupAt] is given and
  /// deleted otherwise. Returns the backup path, if one was made.
  Future<String?> replaceWith(String incoming, {DateTime? backupAt}) async {
    _cache.clear();
    String? backup;
    final current = Directory(root);
    if (await current.exists()) {
      if (backupAt != null) {
        backup = '${p.normalize(root)}_backup_${_stamp(backupAt)}';
        await current.rename(backup);
      } else {
        await current.delete(recursive: true);
      }
    }
    await Directory(incoming).rename(root);
    return backup;
  }

  /// `20260101-093000`: sorts by time and is valid in file names.
  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  // ---------------------------------------------------------------------------
  // Writing

  /// Writes a new note into [folder]. Notes are created managed so they can
  /// hold metadata.
  Future<StoreChange> create({
    required String title,
    required String body,
    String folder = '',
    bool pinned = false,
    NoteColor color = NoteColor.none,
    List<String> tags = const [],
    DateTime? now,
  }) async {
    final normalized = normalizeFolder(folder);
    final timestamp = now ?? DateTime.now();
    final nameSource = title.trim().isNotEmpty ? title : body.trim();
    final note = Note(
      path: uniquePath(normalized, nameSource),
      title: title,
      body: body,
      format: NoteFormat.managed,
      pinned: pinned,
      color: color,
      tags: tags,
      created: timestamp,
      modified: timestamp,
    );
    await _write(note);
    return StoreChange(note, [note.path]);
  }

  /// Saves an edited note over [original]. A plain note that gains metadata
  /// becomes managed. A plain note whose title changes is renamed after the
  /// new title, which is then kept as its `# heading`.
  Future<StoreChange> save(
    Note edited, {
    required Note original,
    DateTime? now,
  }) async {
    var note = edited.copyWith(path: original.path);
    if (note.format == NoteFormat.plain && note.hasMetadata) {
      note = note.copyWith(format: NoteFormat.managed);
    }
    if (note.format == NoteFormat.plain && note.title != original.title) {
      final title = note.title.trim();
      if (title.isEmpty) {
        // No title left to keep: the file name is the title again.
        note = note.copyWith(title: note.fileStem, titleInHeading: false);
      } else {
        final newPath = uniquePath(note.folder, title, except: original.path);
        note = note.copyWith(path: newPath, title: title, titleInHeading: true);
      }
    }
    if (note.format == NoteFormat.managed) {
      note = note.copyWith(modified: now ?? DateTime.now());
    }
    await _write(note);
    final paths = [note.path];
    if (note.path != original.path) {
      await _deleteFile(original.path);
      paths.add(original.path);
    }
    return StoreChange(note, paths);
  }

  /// Moves a note into another folder, keeping its file name when free.
  Future<StoreChange> move(Note note, String folder) async {
    final target = normalizeFolder(folder);
    if (target == note.folder) return StoreChange(note, const []);
    final newPath = uniquePath(target, note.fileStem);
    _checkNoLinks(note.path);
    _checkNoLinks(newPath);
    final source = File(absolute(note.path));
    final dest = File(absolute(newPath));
    await dest.parent.create(recursive: true);
    await source.rename(dest.path);
    _cache.remove(note.path);
    await _removeEmptyParents(source.parent);
    return StoreChange(_atPath(note, newPath), [note.path, newPath]);
  }

  /// Writes a deleted [note] back exactly as it was, at its old path when
  /// that is still free (otherwise at the next free name in its folder).
  Future<StoreChange> restore(Note note) async {
    final restored = _existsCaseInsensitive(note.path)
        ? _atPath(note, uniquePath(note.folder, note.fileStem))
        : note;
    await _write(restored);
    return StoreChange(restored, [restored.path]);
  }

  /// [note] at [path]. A plain note without a `# heading` is titled by its
  /// file name, so its title follows the file.
  static Note _atPath(Note note, String path) {
    final moved = note.copyWith(path: path);
    return moved.format == NoteFormat.plain && !moved.titleInHeading
        ? moved.copyWith(title: moved.fileStem)
        : moved;
  }

  Future<StoreChange> delete(Note note) async {
    await _deleteFile(note.path);
    return StoreChange(null, [note.path]);
  }

  /// Creates a folder with a `.gitkeep` file so Git tracks it while empty.
  Future<StoreChange> createFolder(String folder) async {
    final normalized = normalizeFolder(folder);
    if (normalized.isEmpty) throw NoteStoreException('Folder name is empty');
    _checkNoLinks('$normalized/$folderKeepFile');
    final dir = Directory(absolute(normalized));
    await dir.create(recursive: true);
    final keep = File(p.join(dir.path, folderKeepFile));
    if (!await keep.exists()) await keep.writeAsString('');
    return StoreChange(null, ['$normalized/$folderKeepFile']);
  }

  Future<void> _write(Note note) async {
    _checkNoLinks(note.path);
    _cache.remove(note.path);
    final file = File(absolute(note.path));
    await file.parent.create(recursive: true);
    // The temp name does not grow with the note's name, so a name at the
    // length limit still fits.
    final tmp = File(
      p.join(
        file.parent.path,
        '.gitmarker-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await tmp.writeAsString(serialize(note), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _deleteFile(String relativePath) async {
    _checkNoLinks(relativePath);
    _cache.remove(relativePath);
    final file = File(absolute(relativePath));
    if (await file.exists()) await file.delete();
    await _removeEmptyParents(file.parent);
  }

  /// Removes directories left empty by a move or delete, matching what a
  /// fresh clone would show (Git does not track empty directories). Folders
  /// made with [createFolder] keep their `.gitkeep` and survive.
  Future<void> _removeEmptyParents(Directory dir) async {
    var current = dir;
    final rootDir = p.normalize(root);
    while (p.isWithin(rootDir, current.path)) {
      if (!await current.exists()) {
        current = current.parent;
        continue;
      }
      if (await current.list().isEmpty) {
        await current.delete();
        current = current.parent;
      } else {
        break;
      }
    }
  }
}

class _CachedFile {
  _CachedFile(FileStat stat, {this.note, this.error})
    : modified = stat.modified,
      size = stat.size;

  _CachedFile.failed(this.error) : note = null, modified = null, size = -1;

  final Note? note;
  final String? error;
  final DateTime? modified;
  final int size;

  bool matches(FileStat stat) =>
      modified != null && stat.modified == modified && stat.size == size;
}

class _Scan {
  _Scan(this.notes, this.skipped, this.folders, this.cache, this.readCount);

  final int readCount;

  final List<Note> notes;
  final List<SkippedFile> skipped;
  final List<String> folders;
  final Map<String, _CachedFile> cache;
}
