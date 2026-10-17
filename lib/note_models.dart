// Shared data models. Pure Dart: no Flutter imports allowed in this file.

/// How a note is persisted on disk.
enum NoteFormat {
  /// A plain `.md` file without front matter. Its title is its first line
  /// when that is a `# heading` (see [Note.titleInHeading]), otherwise its
  /// file name. Plain notes carry no metadata (pin, color, tags).
  plain,

  /// A `.md` file with a YAML front matter block holding the metadata.
  managed,
}

/// Note background colors, modelled after Google Keep's palette.
enum NoteColor {
  none,
  red,
  orange,
  yellow,
  green,
  teal,
  blue,
  darkBlue,
  purple,
  pink,
  brown,
  gray;

  static final _byName = {for (final c in values) c.name.toLowerCase(): c};

  static NoteColor parse(Object? value) =>
      _byName[value.toString().trim().toLowerCase()] ?? NoteColor.none;
}

class Note {
  Note({
    required this.path,
    required this.title,
    required this.body,
    this.format = NoteFormat.managed,
    this.pinned = false,
    this.color = NoteColor.none,
    List<String> tags = const [],
    this.created,
    this.modified,
    this.titleInHeading = false,
    Map<String, Object?> extraFrontMatter = const {},
  }) : tags = List.unmodifiable(tags),
       extraFrontMatter = Map.unmodifiable(extraFrontMatter);

  /// Path relative to the repository root, using `/` separators,
  /// e.g. `work/ideas.md`.
  final String path;
  final String title;
  final String body;
  final NoteFormat format;
  final bool pinned;
  final NoteColor color;
  final List<String> tags;
  final DateTime? created;
  final DateTime? modified;

  /// Plain notes only: the title is stored as the file's first line,
  /// `# <title>`, and [body] is the rest of the file.
  final bool titleInHeading;

  /// Front matter keys GitMarker does not know about. They are preserved
  /// verbatim when the note is written back.
  final Map<String, Object?> extraFrontMatter;

  /// Folder relative to the repository root; `''` for the root folder.
  String get folder {
    final index = path.lastIndexOf('/');
    return index < 0 ? '' : path.substring(0, index);
  }

  /// File name without the `.md` extension.
  String get fileStem {
    final name = path.substring(path.lastIndexOf('/') + 1);
    return name.toLowerCase().endsWith('.md')
        ? name.substring(0, name.length - 3)
        : name;
  }

  /// True when the note carries metadata that only a managed note can store.
  bool get hasMetadata => pinned || color != NoteColor.none || tags.isNotEmpty;

  Note copyWith({
    String? path,
    String? title,
    String? body,
    NoteFormat? format,
    bool? pinned,
    NoteColor? color,
    List<String>? tags,
    DateTime? created,
    DateTime? modified,
    bool? titleInHeading,
    Map<String, Object?>? extraFrontMatter,
  }) {
    return Note(
      path: path ?? this.path,
      title: title ?? this.title,
      body: body ?? this.body,
      format: format ?? this.format,
      pinned: pinned ?? this.pinned,
      color: color ?? this.color,
      tags: tags ?? this.tags,
      created: created ?? this.created,
      modified: modified ?? this.modified,
      titleInHeading: titleInHeading ?? this.titleInHeading,
      extraFrontMatter: extraFrontMatter ?? this.extraFrontMatter,
    );
  }

  /// Equality on content and metadata, ignoring timestamps. Used to decide
  /// whether an edit actually changed anything.
  bool sameContentAs(Note other) =>
      title == other.title &&
      body == other.body &&
      path == other.path &&
      pinned == other.pinned &&
      color == other.color &&
      format == other.format &&
      tags.join('\u0000') == other.tags.join('\u0000');

  @override
  String toString() => 'Note($path, "$title")';
}

/// A Markdown checklist item: `- [ ] text` or `- [x] text` (also `*`, `+`,
/// `[X]`), indented by [indent]. The one definition of the syntax, used to
/// render items and to tick them.
class ChecklistItem {
  const ChecklistItem(this.indent, this.done, this.text);

  final String indent;
  final bool done;
  final String text;

  /// Groups: indent, marker up to `[`, state, `]` and spacing, text.
  static final RegExp _syntax = RegExp(
    r'^(\s*)([-*+]\s+\[)([ xX])(\]\s+)(.*)$',
  );

  /// The item on [line]; null when the line is not a checklist item.
  static ChecklistItem? parse(String line) {
    final m = _syntax.firstMatch(line);
    return m == null ? null : ChecklistItem(m[1]!, m[3] != ' ', m[5]!);
  }

  /// [body] with the item on line [index] ticked or unticked; unchanged
  /// when that line is not a checklist item.
  static String toggle(String body, int index) {
    final lines = body.split('\n');
    final m = index >= 0 && index < lines.length
        ? _syntax.firstMatch(lines[index])
        : null;
    if (m == null) return body;
    lines[index] = '${m[1]}${m[2]}${m[3] == ' ' ? 'x' : ' '}${m[4]}${m[5]}';
    return lines.join('\n');
  }
}

/// A Markdown file that was not loaded as a note, and why.
class SkippedFile {
  const SkippedFile(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => '$path: $reason';
}

/// One commit touching a note, as seen by the history navigator.
class NoteRevision {
  const NoteRevision({
    required this.commit,
    required this.path,
    required this.author,
    required this.date,
    required this.message,
  });

  final String commit;

  /// The note's path at this commit (notes can be moved/renamed).
  final String path;
  final String author;
  final DateTime date;
  final String message;

  String get shortCommit => commit.length > 7 ? commit.substring(0, 7) : commit;
}

/// Note content at a given revision. [note] is null when the file was
/// deleted in that commit or cannot be parsed.
class NoteVersion {
  const NoteVersion({required this.revision, required this.note});

  final NoteRevision revision;
  final Note? note;
}

/// How GitMarker authenticates to the remote. Only the selected method's
/// fields are used (and shown in Settings).
enum AuthMethod {
  /// Public remotes and local paths.
  none,

  /// HTTPS with a user name and a personal access token (or password).
  httpsToken,

  /// SSH with a private key file.
  sshKey,

  /// SSH with the keys held by the running SSH agent (desktop).
  sshAgent,
}

/// User name used for HTTPS tokens when none is given. GitHub accepts any
/// name with a token; GitLab requires `oauth2` for OAuth tokens.
const String defaultHttpsUser = 'oauth2';

/// Credentials and transport options for talking to a remote.
class GitAuth {
  const GitAuth({
    this.method = AuthMethod.none,
    this.username,
    this.password,
    this.sshKeyPath,
    this.sshPassphrase,
  });

  final AuthMethod method;

  /// HTTPS user name; [defaultHttpsUser] when empty.
  final String? username;

  /// HTTPS personal access token or password.
  final String? password;

  /// Private key file for [AuthMethod.sshKey].
  final String? sshKeyPath;

  /// Passphrase of [sshKeyPath], if it is encrypted.
  final String? sshPassphrase;

  Map<String, Object?> toJson() => {
    'method': method.name,
    'username': username,
    'password': password,
    'sshKeyPath': sshKeyPath,
    'sshPassphrase': sshPassphrase,
  };

  factory GitAuth.fromJson(Map<String, Object?> json) => GitAuth(
    method: AuthMethod.values.asNameMap()[json['method']] ?? AuthMethod.none,
    username: json['username'] as String?,
    password: json['password'] as String?,
    sshKeyPath: json['sshKeyPath'] as String?,
    sshPassphrase: json['sshPassphrase'] as String?,
  );
}

/// Persistent application settings (stored outside the notes repository).
class AppSettings {
  const AppSettings({
    this.remoteUrl = '',
    this.branch = 'main',
    this.auth = const GitAuth(),
    this.authorName = 'GitMarker',
    this.authorEmail = 'gitmarker@localhost',
  });

  /// Empty when the repository is local-only.
  final String remoteUrl;
  final String branch;
  final GitAuth auth;
  final String authorName;
  final String authorEmail;

  bool get hasRemote => remoteUrl.trim().isNotEmpty;

  AppSettings copyWith({
    String? remoteUrl,
    String? branch,
    GitAuth? auth,
    String? authorName,
    String? authorEmail,
  }) {
    return AppSettings(
      remoteUrl: remoteUrl ?? this.remoteUrl,
      branch: branch ?? this.branch,
      auth: auth ?? this.auth,
      authorName: authorName ?? this.authorName,
      authorEmail: authorEmail ?? this.authorEmail,
    );
  }

  Map<String, Object?> toJson() => {
    'remoteUrl': remoteUrl,
    'branch': branch,
    'auth': auth.toJson(),
    'authorName': authorName,
    'authorEmail': authorEmail,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    const defaults = AppSettings();
    final auth = json['auth'];
    return AppSettings(
      remoteUrl: json['remoteUrl'] as String? ?? defaults.remoteUrl,
      branch: (json['branch'] as String?)?.trim().isNotEmpty == true
          ? (json['branch'] as String).trim()
          : defaults.branch,
      auth: auth is Map ? GitAuth.fromJson(auth.cast()) : const GitAuth(),
      authorName: json['authorName'] as String? ?? defaults.authorName,
      authorEmail: json['authorEmail'] as String? ?? defaults.authorEmail,
    );
  }
}

/// Outcome of a sync attempt.
enum SyncOutcome {
  /// No remote configured; nothing to do.
  noRemote,

  /// Working tree has uncommitted changes; sync refused.
  dirtyTree,
  upToDate,
  fastForwarded,
  pushed,

  /// Local commits were rebased onto the remote and pushed.
  rebased,

  /// Rebase hit a conflict; it was aborted and a resolution is required.
  conflict,
  error,
}

class SyncResult {
  const SyncResult(
    this.outcome, {
    this.message,
    this.conflictedFiles = const [],
  });

  final SyncOutcome outcome;
  final String? message;
  final List<String> conflictedFiles;

  @override
  String toString() =>
      'SyncResult($outcome${message == null ? '' : ': $message'})';
}

/// How to resolve a paused (conflicted) sync.
enum ConflictResolution {
  /// Discard local commits: reset to `origin/<branch>`.
  keepRemote,

  /// Overwrite the remote branch with the local history.
  forcePushLocal,

  /// Leave everything as it is; local and remote stay diverged.
  abort,
}

/// What the user should be warned about before replacing the remote.
class RemoteChangeCheck {
  const RemoteChangeCheck({
    required this.currentUrl,
    required this.hasUncommittedChanges,
    required this.unpushedCommits,
  });

  final String currentUrl;
  final bool hasUncommittedChanges;

  /// Commits not on the configured remote branch. For a local-only
  /// repository, every commit counts as unpushed.
  final int unpushedCommits;

  bool get losesData => hasUncommittedChanges || unpushedCommits > 0;
}
