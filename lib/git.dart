// GitMarker's Git layer: the app's Git rules (remote URLs, branch names,
// settings validation, credentials, SSH host keys) and its workflows
// (sync, conflict resolution, note history), each built from git commands
// provided by dargit. dargit implements Git itself in pure Dart (no
// libgit2, no `git` executable) and runs every command on a background
// isolate.

import 'dart:convert';
import 'dart:io';

import 'package:dargit/dargit.dart' as dargit;
import 'package:path/path.dart' as p;

import 'note_models.dart';

export 'package:dargit/dargit.dart' show GitException;

// -----------------------------------------------------------------------------
// Remote URLs and settings rules

enum RemoteKind { none, local, https, http, ssh, other }

/// Adds the conventional `git@` user to an SSH URL that names none
/// (`ssh://host/repo` → `ssh://git@host/repo`, `host:repo` →
/// `git@host:repo`). libgit2 asks for a user name before any key when the
/// URL has none, which GitMarker cannot answer. Other URLs are returned
/// trimmed.
String withSshUser(String url) {
  final value = url.trim();
  if (remoteKind(value) != RemoteKind.ssh) return value;
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*://)(.*)$')
      .firstMatch(value);
  if (scheme != null) {
    final rest = scheme.group(2)!;
    final authority = rest.split('/').first;
    return authority.contains('@') ? value : '${scheme.group(1)}git@$rest';
  }
  return value.split(':').first.contains('@') ? value : 'git@$value';
}

/// Classifies a remote URL: `https://…`, `http://…`, SSH (`ssh://…` or the
/// scp-like `user@host:path`), a local path (`/srv/notes.git`,
/// `C:\\notes`, `file://…`), or something else.
RemoteKind remoteKind(String url) {
  final value = url.trim();
  if (value.isEmpty) return RemoteKind.none;
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://').firstMatch(value);
  if (scheme != null) {
    return switch (scheme.group(1)!.toLowerCase()) {
      'https' => RemoteKind.https,
      'http' => RemoteKind.http,
      'ssh' || 'git+ssh' || 'ssh+git' => RemoteKind.ssh,
      'file' => RemoteKind.local,
      _ => RemoteKind.other,
    };
  }
  final scp = RegExp(r'^([^@/:\s]+@)?([^@/:\s]+):').firstMatch(value);
  // `C:\notes` is a Windows drive, not host `C`; `git@h:notes` is a host.
  if (scp != null && (scp.group(1) != null || scp.group(2)!.length > 1)) {
    return RemoteKind.ssh;
  }
  return RemoteKind.local;
}

/// Everything wrong with [settings], in plain words; empty when they can be
/// applied. Checked before cloning or changing `origin`, so the user sees
/// "the SSH key file does not exist" rather than a libgit2 error.
List<String> validateGitSettings(AppSettings settings) {
  final problems = <String>[];
  final branch = settings.branch.trim();
  if (!isValidBranchName(branch)) {
    problems.add("'$branch' is not a valid branch name.");
  }
  final url = settings.remoteUrl.trim();
  final kind = remoteKind(url);
  final auth = settings.auth;
  if (kind == RemoteKind.none) return problems; // Local only: no auth.

  final insecure = insecureRemoteProblem(url);
  if (insecure != null) problems.add(insecure);

  final uri = Uri.tryParse(url);
  final userInfo = uri != null && uri.hasScheme ? uri.userInfo : '';
  if ((kind == RemoteKind.https || kind == RemoteKind.http) &&
      userInfo.isNotEmpty) {
    problems.add(
      'Remove the user name or token from the URL and use the HTTPS token '
      'fields; credentials in the URL would be stored in plain text in '
      '.git/config.',
    );
  }
  if (kind == RemoteKind.ssh && userInfo.contains(':')) {
    problems.add('Remove the password from the SSH URL.');
  }
  if (kind == RemoteKind.local) {
    final path = url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
    if (!Directory(path).existsSync()) {
      problems.add('The folder $path does not exist.');
    } else if (!Directory(p.join(path, '.git')).existsSync() &&
        !(File(p.join(path, 'HEAD')).existsSync() &&
            Directory(p.join(path, 'objects')).existsSync())) {
      problems.add('$path is not a Git repository.');
    }
  }

  switch (auth.method) {
    case AuthMethod.none:
      if (kind == RemoteKind.ssh) {
        problems.add('SSH remotes need SSH key or SSH agent authentication.');
      }
    case AuthMethod.httpsToken:
      if (kind != RemoteKind.https) {
        problems.add('An HTTPS token needs an https:// remote URL.');
      }
      if ((auth.password ?? '').isEmpty) {
        problems.add('Enter the HTTPS token.');
      }
    case AuthMethod.sshKey || AuthMethod.sshAgent:
      if (kind != RemoteKind.ssh) {
        problems.add(
          'SSH authentication needs an SSH URL, such as '
          'git@github.com:user/notes.git.',
        );
      }
      if (auth.method == AuthMethod.sshKey) {
        final key = GitBackend.expandHome((auth.sshKeyPath ?? '').trim());
        if (key.isEmpty) {
          problems.add('Enter the path of the SSH private key.');
        } else if (key.endsWith('.pub')) {
          problems.add(
            'Choose the private key, not the public key ($key ends in .pub).',
          );
        } else if (!File(key).existsSync()) {
          problems.add('The SSH key file $key does not exist.');
        }
      }
  }
  return problems;
}

/// Why GitMarker refuses to connect to [url], or null when it may.
/// `http://` (and any other unencrypted or unknown scheme, such as
/// `git://`) would send the notes, and any token, in clear text.
String? insecureRemoteProblem(String url) => switch (remoteKind(url)) {
  RemoteKind.http =>
    'http:// sends your notes and credentials unencrypted. Use an '
        'https:// or SSH URL.',
  RemoteKind.other =>
    'Unsupported remote URL. Use https://, SSH (git@host:path) or a local '
        'folder.',
  _ => null,
};

/// Git's branch name rules (`git check-ref-format --branch`), simplified.
bool isValidBranchName(String name) =>
    name.isNotEmpty &&
    !name.startsWith('-') &&
    !name.startsWith('/') &&
    !name.endsWith('/') &&
    !name.endsWith('.') &&
    !name.endsWith('.lock') &&
    !name.startsWith('refs/') &&
    !name.contains('..') &&
    !name.contains('//') &&
    !name.contains('@{') &&
    name != '@' &&
    !name.split('/').any((part) => part.startsWith('.')) &&
    !RegExp(r'[\x00-\x20\x7F~^:?*\[\\]').hasMatch(name);

/// The Git operations GitMarker needs. All paths are repository working
/// trees; `origin` is the only remote GitMarker manages.
class GitBackend {
  GitBackend({
    this.auth = const GitAuth(),
    this.authorName = 'GitMarker',
    this.authorEmail = 'gitmarker@localhost',
    this.knownHostsPath,
    this.networkTimeout = defaultNetworkTimeout,
  });

  static const Duration defaultNetworkTimeout = Duration(minutes: 2);

  final GitAuth auth;
  final String authorName;
  final String authorEmail;

  /// JSON file of SSH host key fingerprints accepted on first use (see
  /// [trustOnFirstUse]). Without it, SSH remotes are refused.
  final String? knownHostsPath;

  /// How long a network operation may wait for the remote before it fails
  /// with a [dargit.GitException].
  final Duration networkTimeout;

  static const String _remote = 'origin';

  late final dargit.Git _git = dargit.Git(
    credentials: credentialsFor(auth),
    verifyHostKey: knownHostsPath == null ? null : _pinnedIn(knownHostsPath!),
    authorName: authorName,
    authorEmail: authorEmail,
    networkTimeout: networkTimeout,
  );

  /// dargit credentials for the configured [GitAuth.method]; the settings
  /// page validates that the method suits the URL.
  static dargit.Credentials credentialsFor(GitAuth auth) =>
      switch (auth.method) {
        AuthMethod.none => const dargit.NoCredentials(),
        AuthMethod.httpsToken => dargit.UserPassword(
          (auth.username ?? '').trim().isEmpty
              ? defaultHttpsUser
              : auth.username!.trim(),
          auth.password ?? '',
        ),
        AuthMethod.sshKey => dargit.SshKey(
          expandHome((auth.sshKeyPath ?? '').trim()),
          passphrase: auth.sshPassphrase,
        ),
        AuthMethod.sshAgent => const dargit.SshAgent(),
      };

  // ---------------------------------------------------------------------------
  // Repository setup

  Future<bool> isRepository(String dir) => _git.isRepository(dir);

  Future<void> init(String dir, {required String branch}) =>
      _git.init(dir, initialBranch: branch);

  /// Clones [url] into [dir] and checks out [branch]. An empty remote is
  /// fine (the branch stays unborn until the first commit). A remote that
  /// has branches but not [branch] is an error, so a typo does not create
  /// (and later push) a new branch; [dir] is not created then.
  ///
  /// `git clone -b` fails on an empty remote, so the remote is listed first
  /// (`git ls-remote`) and an empty one becomes `git init` + `remote add`.
  Future<void> clone(String url, String dir, {required String branch}) async {
    _requireSecure('clone', url);
    final branches = [
      for (final ref in (await _git.lsRemote(url)).keys)
        if (ref.startsWith('refs/heads/')) ref.substring('refs/heads/'.length),
    ];
    if (branches.isEmpty) {
      await _git.init(dir, initialBranch: branch);
      await _git.remoteAdd(dir, url);
      return;
    }
    if (!branches.contains(branch)) {
      throw dargit.GitException(
        'clone',
        'Remote branch $branch not found in upstream origin '
            '(branches: ${(branches..sort()).join(', ')})',
      );
    }
    await _git.clone(url, dir, branch: branch);
  }

  Future<String?> remoteUrl(String dir) => _git.remoteGetUrl(dir);

  /// Sets `origin` to [url], or removes it when [url] is empty.
  Future<void> setRemoteUrl(String dir, String url) async {
    final target = url.trim();
    final exists = await _git.remoteGetUrl(dir) != null;
    if (target.isEmpty) {
      if (exists) await _git.remoteRemove(dir);
    } else if (exists) {
      await _git.remoteSetUrl(dir, target);
    } else {
      await _git.remoteAdd(dir, target);
    }
  }

  // ---------------------------------------------------------------------------
  // Local state

  /// Whether nothing is modified, staged or untracked (ignored files do not
  /// count), and how many commits of HEAD are not on `origin/<branch>` (all
  /// of them when that does not exist).
  Future<({bool clean, int unpushed})> status(String dir, String branch) async {
    final clean = (await _git.status(dir)).isEmpty;
    return (clean: clean, unpushed: (await _aheadBehind(dir, branch)).$1);
  }

  /// Commits [paths] as they are on disk (a missing file is a deletion),
  /// or every change when [paths] is null (`git add -A && git commit`).
  /// Returns false when there was nothing to commit.
  ///
  /// With [paths] this is `git commit --only`: the commit is HEAD's tree
  /// with only those paths replaced, so anything staged outside GitMarker
  /// (`git add` in a terminal) is neither committed nor unstaged.
  Future<bool> commit(String dir, String message, {List<String>? paths}) async {
    if (paths == null) await _git.add(dir, const ['.']);
    return await _git.commit(dir, message, only: paths) != null;
  }

  // ---------------------------------------------------------------------------
  // Synchronization

  /// Fetches `origin` and integrates `origin/<branch>` into HEAD:
  /// fast-forward when only behind (`git reset --hard origin/<branch>`),
  /// push when only ahead (`git push origin HEAD:<branch>`), rebase local
  /// commits onto the remote and push when diverged. A conflicting rebase is aborted, leaving the
  /// branch and working tree as they were. Refuses a dirty working tree.
  Future<SyncResult> sync(String dir, String branch) async {
    if ((await _git.status(dir)).isNotEmpty) {
      return const SyncResult(
        SyncOutcome.dirtyTree,
        message: 'The notes folder has uncommitted changes.',
      );
    }
    _requireSecure('fetch', await _git.remoteGetUrl(dir) ?? '');
    await _git.fetch(dir, prune: true);
    final (ahead, behind) = await _aheadBehind(dir, branch);
    if (ahead == 0 && behind == 0) {
      return const SyncResult(SyncOutcome.upToDate);
    }
    if (ahead == 0) {
      await _git.resetHard(dir, _tracking(branch));
      return const SyncResult(SyncOutcome.fastForwarded);
    }
    if (behind == 0) {
      await _git.push(dir, 'HEAD:$branch');
      return const SyncResult(SyncOutcome.pushed);
    }
    final rebase = await _git.rebase(dir, _tracking(branch));
    if (!rebase.ok) {
      return SyncResult(
        SyncOutcome.conflict,
        message: 'Local and remote changes conflict.',
        conflictedFiles: rebase.conflicts,
      );
    }
    await _git.push(dir, 'HEAD:$branch');
    return const SyncResult(SyncOutcome.rebased);
  }

  /// Resolves a sync that stopped on a conflict.
  Future<SyncResult> resolve(
    String dir,
    String branch,
    ConflictResolution resolution,
  ) async {
    switch (resolution) {
      case ConflictResolution.keepRemote:
        await _git.resetHard(dir, _tracking(branch));
        return const SyncResult(
          SyncOutcome.fastForwarded,
          message: 'Kept the remote version.',
        );
      case ConflictResolution.forcePushLocal:
        _requireSecure('push', await _git.remoteGetUrl(dir) ?? '');
        try {
          await _git.push(dir, 'HEAD:$branch', forceWithLease: true);
        } on dargit.GitException catch (e) {
          if (!e.message.contains('(stale info)')) rethrow;
          throw dargit.GitException(
            'push',
            '$_remote/$branch changed since the last fetch; sync again first.',
          );
        }
        return const SyncResult(
          SyncOutcome.pushed,
          message: 'Force pushed the local notes.',
        );
      case ConflictResolution.abort:
        return const SyncResult(
          SyncOutcome.upToDate,
          message: 'Sync aborted; local and remote remain diverged.',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // History

  /// Commits that changed [path], newest first. Renames are followed: each
  /// revision carries the note's path at that commit (`git log
  /// --first-parent --follow`).
  Future<List<NoteRevision>> fileHistory(String dir, String path) async => [
    for (final e in await _git.log(dir, path: path, follow: true))
      NoteRevision(
        commit: e.commit,
        path: e.path!,
        author: e.authorName,
        date: e.date,
        message: e.subject,
      ),
  ];

  /// File content at [commit], or null if it does not exist there.
  Future<String?> showFile(String dir, String commit, String path) async {
    final bytes = await _git.show(dir, commit, path);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  // ---------------------------------------------------------------------------
  // Helpers

  static String _tracking(String branch) => '$_remote/$branch';

  /// Refuses to talk to [url] over an unencrypted transport, also for
  /// settings saved before this rule existed.
  static void _requireSecure(String operation, String url) {
    final problem = insecureRemoteProblem(url);
    if (problem != null) throw dargit.GitException(operation, problem);
  }

  /// Commits on HEAD but not on `origin/<branch>`, and vice versa
  /// (`git rev-list --count`).
  Future<(int, int)> _aheadBehind(String dir, String branch) async {
    final local = await _git.revParse(dir, 'HEAD');
    final remote = await _git.revParse(dir, 'refs/remotes/$_remote/$branch');
    if (local == null) {
      return (0, remote == null ? 0 : await _git.revListCount(dir, remote));
    }
    if (remote == null) return (await _git.revListCount(dir, local), 0);
    return (
      await _git.revListCount(dir, local, exclude: remote),
      await _git.revListCount(dir, remote, exclude: local),
    );
  }

  /// Expands a leading `~` (as in `~/.ssh/id_ed25519`) to the home folder.
  static String expandHome(String path) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || !(path == '~' || path.startsWith('~/'))) return path;
    return home + path.substring(1);
  }

  /// Trust-on-first-use for SSH host keys: the first [fingerprint]
  /// (`SHA256:...`) seen for [host] is recorded in [hostsFile]; a
  /// different one later is refused.
  ///
  /// Only a missing file starts an empty list. A file that cannot be read
  /// or parsed refuses every host rather than forgetting the pins, and the
  /// file is replaced atomically so an interrupted write cannot damage it.
  static bool trustOnFirstUse(
    String hostsFile,
    String host,
    String fingerprint,
  ) {
    final file = File(hostsFile);
    var known = <String, Object?>{};
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map) return false;
        known = decoded.cast<String, Object?>();
      } on Object {
        return false;
      }
    }
    final stored = known[host];
    if (stored == null) {
      known[host] = fingerprint;
      final tmp = File('$hostsFile.$pid.tmp')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(known),
          flush: true,
        );
      tmp.renameSync(hostsFile);
      return true;
    }
    return stored == fingerprint;
  }
}

/// A host key check against [hostsFile]. Top-level so that the closure only
/// captures the path: dargit sends it to its background isolates.
dargit.HostKeyVerifier _pinnedIn(String hostsFile) =>
    (host, fingerprint) =>
        GitBackend.trustOnFirstUse(hostsFile, host, fingerprint);
