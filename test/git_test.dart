// GitBackend against local repositories (dargit).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dargit/dargit.dart' show Git;
import 'package:gitmarker/git.dart';
import 'package:gitmarker/note_models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  final git = GitBackend(authorName: 'Test', authorEmail: 'test@example.com');

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('gitmarker_git_');
  });
  tearDown(() => sandbox.delete(recursive: true));

  String path(String name) => p.join(sandbox.path, name);

  Future<String> bare(String name) async {
    await Git().init(path(name), initialBranch: 'main', bare: true);
    return path(name);
  }

  Future<void> write(String repo, String file, String content) async {
    final f = File(p.join(repo, file));
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  Future<bool> clean(String dir) async => (await git.status(dir, 'main')).clean;
  Future<int> unpushed(String dir, String branch) async =>
      (await git.status(dir, branch)).unpushed;
  Future<SyncOutcome> sync(String dir, [String branch = 'main']) async =>
      (await git.sync(dir, branch)).outcome;

  Future<String> cloneWithCommit(
    String remote,
    String name,
    String file,
    String content,
  ) async {
    final dir = path(name);
    await git.clone(remote, dir, branch: 'main');
    await write(dir, file, content);
    await git.commit(dir, 'add $file', paths: [file]);
    return dir;
  }

  test('init, commit only the given paths, detect a clean tree', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    expect(await git.isRepository(dir), isTrue);
    expect(await git.isRepository(sandbox.path), isFalse);
    expect(await unpushed(dir, 'main'), 0, reason: 'no commits yet');
    expect(await clean(dir), isTrue);

    await write(dir, 'a.md', 'a');
    await write(dir, 'b.md', 'b');
    expect(await clean(dir), isFalse);
    expect(await git.commit(dir, 'add a', paths: ['a.md']), isTrue);
    expect(await clean(dir), isFalse, reason: 'b.md is still untracked');
    expect(await git.commit(dir, 'nothing', paths: ['a.md']), isFalse);
    expect(await git.commit(dir, 'rest'), isTrue);
    expect(await clean(dir), isTrue);

    await File(p.join(dir, 'a.md')).delete();
    expect(await git.commit(dir, 'delete a', paths: ['a.md']), isTrue);
    expect(
      await git.showFile(
        dir,
        (await git.fileHistory(dir, 'b.md')).single.commit,
        'b.md',
      ),
      'b',
    );
  });

  test('committing note paths leaves outside staging alone', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    await write(dir, 'note.md', 'v1');
    await git.commit(dir, 'first', paths: ['note.md']);

    // Someone runs `git add manual.md` in a terminal.
    await write(dir, 'manual.md', 'staged elsewhere');
    await Git().add(dir, ['manual.md']);

    await write(dir, 'note.md', 'v2');
    expect(await git.commit(dir, 'update', paths: ['note.md']), isTrue);
    final head = (await git.fileHistory(dir, 'note.md')).first.commit;
    expect(await git.showFile(dir, head, 'note.md'), 'v2');
    expect(await git.showFile(dir, head, 'manual.md'), isNull);
    // ...and manual.md is still staged, not lost.
    expect((await Git().status(dir)).map((e) => '$e'), ['A  manual.md']);
    expect(await clean(dir), isFalse);
  });

  test('committing note paths handles new folders and deletions', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    await write(dir, 'a/b/deep.md', 'deep');
    expect(await git.commit(dir, 'add deep', paths: ['a/b/deep.md']), isTrue);
    await File(p.join(dir, 'a/b/deep.md')).delete();
    expect(
      await git.commit(dir, 'delete deep', paths: ['a/b/deep.md']),
      isTrue,
    );
    expect(await clean(dir), isTrue);
    // A path that never existed is not a change.
    expect(await git.commit(dir, 'noop', paths: ['ghost.md']), isFalse);
  });

  test('ignored files do not make the tree dirty', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    await write(dir, '.gitignore', '*.tmp\n');
    await git.commit(dir, 'ignore');
    await write(dir, 'x.tmp', 'scratch');
    expect(await clean(dir), isTrue);
  });

  test('Arabic and special-character paths are committed literally', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    const names = ['ملاحظة جديدة.md', 'star*[x].md', 'عربي/مجلد.md'];
    for (final name in names) {
      await write(dir, name, name);
    }
    expect(await git.commit(dir, 'unicode', paths: names), isTrue);
    expect(await clean(dir), isTrue);
    final head = (await git.fileHistory(dir, names[0])).single.commit;
    for (final name in names) {
      expect(await git.showFile(dir, head, name), name);
    }
  });

  test('history follows renames and stops at creation', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    await write(dir, 'old.md', 'line one\nline two\nline three\n');
    await git.commit(dir, 'create');
    await write(dir, 'unrelated.md', 'x');
    await git.commit(dir, 'unrelated');
    await File(p.join(dir, 'old.md')).rename(p.join(dir, 'new.md'));
    await git.commit(dir, 'rename');
    await write(dir, 'new.md', 'line one\nline two\nline three\nfour\n');
    await git.commit(dir, 'edit');

    final history = await git.fileHistory(dir, 'new.md');
    expect(history.map((r) => (r.message, r.path)), [
      ('edit', 'new.md'),
      ('rename', 'new.md'),
      ('create', 'old.md'),
    ]);
    expect(
      await git.showFile(dir, history.last.commit, 'old.md'),
      startsWith('line one'),
    );
    expect(await git.showFile(dir, history.last.commit, 'new.md'), isNull);
  });

  test('sync pushes, fast-forwards and reports up to date', () async {
    final remote = await bare('origin.git');
    final a = await cloneWithCommit(remote, 'a', 'a.md', 'a');
    expect(await unpushed(a, 'main'), 1);
    expect(await sync(a), SyncOutcome.pushed);
    expect(await unpushed(a, 'main'), 0);

    final b = path('b');
    await git.clone(remote, b, branch: 'main');
    expect(File(p.join(b, 'a.md')).readAsStringSync(), 'a');

    await write(a, 'a.md', 'a2');
    await git.commit(a, 'edit');
    expect(await sync(a), SyncOutcome.pushed);
    expect(await sync(b), SyncOutcome.fastForwarded);
    expect(File(p.join(b, 'a.md')).readAsStringSync(), 'a2');
    expect(await clean(b), isTrue);
    expect(await sync(b), SyncOutcome.upToDate);
  });

  test('sync refuses a dirty working tree', () async {
    final remote = await bare('origin.git');
    final a = await cloneWithCommit(remote, 'a', 'a.md', 'a');
    await write(a, 'untracked.md', 'x');
    expect(await sync(a), SyncOutcome.dirtyTree);
    expect(await unpushed(a, 'main'), 1);
  });

  test('sync rebases, skipping commits already upstream', () async {
    final remote = await bare('origin.git');
    final a = await cloneWithCommit(remote, 'a', 'shared.md', 'base\n');
    await sync(a);
    final b = path('b');
    await git.clone(remote, b, branch: 'main');

    // Same change on both sides: B's commit becomes empty and is dropped.
    await write(a, 'shared.md', 'same\n');
    await git.commit(a, 'a same');
    await sync(a);
    await write(b, 'shared.md', 'same\n');
    await git.commit(b, 'b same');
    await write(b, 'b.md', 'b');
    await git.commit(b, 'b only');
    expect(await sync(b), SyncOutcome.rebased);
    final subjects = (await git.fileHistory(b, 'b.md')).map((r) => r.message);
    expect(subjects, ['b only']);
    expect(await unpushed(b, 'main'), 0);
    expect(await sync(a), SyncOutcome.fastForwarded);
    expect(File(p.join(a, 'b.md')).readAsStringSync(), 'b');
  });

  group('conflicts', () {
    late String a;
    late String b;

    /// A and B both change shared.md; B's sync stops on the conflict.
    Future<void> diverge(String fromA, String fromB) async {
      await write(a, 'shared.md', fromA);
      await git.commit(a, 'a edit');
      expect(await sync(a), SyncOutcome.pushed);
      await write(b, 'shared.md', fromB);
      await git.commit(b, 'b edit');
      final result = await git.sync(b, 'main');
      expect(result.outcome, SyncOutcome.conflict);
      expect(result.conflictedFiles, ['shared.md']);
      // The rebase was aborted: B is untouched.
      expect(File(p.join(b, 'shared.md')).readAsStringSync(), fromB);
      expect(await clean(b), isTrue);
      expect(
        Directory(p.join(b, '.git', 'rebase-merge')).existsSync(),
        isFalse,
      );
    }

    setUp(() async {
      final remote = await bare('origin.git');
      a = await cloneWithCommit(remote, 'a', 'shared.md', 'base\n');
      await sync(a);
      b = path('b');
      await git.clone(remote, b, branch: 'main');
    });

    test('keep remote resets to origin', () async {
      await diverge('A\n', 'B\n');
      final result = await git.resolve(
        b,
        'main',
        ConflictResolution.keepRemote,
      );
      expect(result.outcome, SyncOutcome.fastForwarded);
      expect(File(p.join(b, 'shared.md')).readAsStringSync(), 'A\n');
      expect(await unpushed(b, 'main'), 0);
    });

    test('abort changes nothing', () async {
      await diverge('A\n', 'B\n');
      await git.resolve(b, 'main', ConflictResolution.abort);
      expect(File(p.join(b, 'shared.md')).readAsStringSync(), 'B\n');
      expect(await unpushed(b, 'main'), 1);
    });

    test('force push refuses when the remote moved since the fetch', () async {
      await diverge('A\n', 'B\n');
      await write(a, 'other.md', 'later');
      await git.commit(a, 'a later');
      await sync(a);
      await expectLater(
        git.resolve(b, 'main', ConflictResolution.forcePushLocal),
        throwsA(
          isA<GitException>().having(
            (e) => e.message,
            'message',
            contains('sync again'),
          ),
        ),
      );
      expect(await sync(b), SyncOutcome.conflict);
      final forced = await git.resolve(
        b,
        'main',
        ConflictResolution.forcePushLocal,
      );
      expect(forced.outcome, SyncOutcome.pushed);
      // A now conflicts with the rewritten remote; keeping it gives B's text.
      expect(await sync(a), SyncOutcome.conflict);
      await git.resolve(a, 'main', ConflictResolution.keepRemote);
      expect(File(p.join(a, 'shared.md')).readAsStringSync(), 'B\n');
    });
  });

  test('cloning an empty remote leaves the branch unborn', () async {
    final remote = await bare('origin.git');
    final dir = path('c');
    await git.clone(remote, dir, branch: 'notes');
    expect(await unpushed(dir, 'notes'), 0);
    expect(await git.remoteUrl(dir), remote);
    await write(dir, 'n.md', 'n');
    await git.commit(dir, 'first');
    expect(await unpushed(dir, 'notes'), 1);
    expect(await sync(dir, 'notes'), SyncOutcome.pushed);
    expect(await unpushed(dir, 'notes'), 0);
  });

  test('cloning a remote without the branch fails and cleans up', () async {
    final remote = await bare('origin.git');
    final a = await cloneWithCommit(remote, 'a', 'a.md', 'a');
    await sync(a);
    final target = path('typo');
    await expectLater(
      git.clone(remote, target, branch: 'mian'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          'Remote branch mian not found in upstream origin (branches: main)',
        ),
      ),
    );
    expect(Directory(target).existsSync(), isFalse);
  });

  test('cloning checks out a branch other than the remote HEAD', () async {
    final remote = await bare('origin.git');
    final a = await cloneWithCommit(remote, 'a', 'main.md', 'm');
    await sync(a);
    await write(a, 'notes.md', 'n');
    await git.commit(a, 'notes only', paths: ['notes.md']);
    expect(await sync(a, 'notes'), SyncOutcome.pushed);
    final b = path('b');
    await git.clone(remote, b, branch: 'notes');
    expect(File(p.join(b, 'notes.md')).existsSync(), isTrue);
    expect(await unpushed(b, 'notes'), 0);
  });

  test('remote URL can be added, changed and removed', () async {
    final dir = path('r');
    await git.init(dir, branch: 'main');
    expect(await git.remoteUrl(dir), isNull);
    await git.setRemoteUrl(dir, '/tmp/one.git');
    expect(await git.remoteUrl(dir), '/tmp/one.git');
    await git.setRemoteUrl(dir, 'git@example.com:me/two.git');
    expect(await git.remoteUrl(dir), 'git@example.com:me/two.git');
    await git.setRemoteUrl(dir, '');
    expect(await git.remoteUrl(dir), isNull);
  });

  test('a remote that stops answering times out', () async {
    final server = await silentServer();
    final slow = GitBackend(networkTimeout: const Duration(seconds: 1));
    final watch = Stopwatch()..start();
    await expectLater(
      slow.clone(server, path('c'), branch: 'main'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          contains('timeout'),
        ),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('errors surface as GitException', () async {
    await expectLater(
      git.clone(path('missing.git'), path('x'), branch: 'main'),
      throwsA(isA<GitException>()),
    );
  });

  test('SSH host keys are trusted on first use, then pinned', () {
    final hosts = path('known_hosts.json');
    expect(GitBackend.trustOnFirstUse(hosts, 'github.com', 'AAA'), isTrue);
    expect(GitBackend.trustOnFirstUse(hosts, 'github.com', 'AAA'), isTrue);
    expect(GitBackend.trustOnFirstUse(hosts, 'github.com', 'BBB'), isFalse);
    expect(GitBackend.trustOnFirstUse(hosts, 'gitlab.com', 'BBB'), isTrue);
    // A damaged pin file refuses every host instead of starting over.
    File(hosts).writeAsStringSync('{"github.com": "AAA"');
    expect(GitBackend.trustOnFirstUse(hosts, 'github.com', 'EVIL'), isFalse);
    expect(GitBackend.trustOnFirstUse(hosts, 'new.host', 'CCC'), isFalse);
    expect(File(hosts).readAsStringSync(), '{"github.com": "AAA"');
  });

  group('validateGitSettings', () {
    String one(AppSettings settings) =>
        validateGitSettings(settings).join(' | ');

    test('local-only settings only need a valid branch', () {
      expect(validateGitSettings(const AppSettings()), isEmpty);
      expect(
        one(const AppSettings(branch: 'a b')),
        contains('not a valid branch'),
      );
    });

    test('branch names follow Git rules', () {
      for (final ok in ['main', 'notes/2026', 'feature-x', 'v1.2']) {
        expect(isValidBranchName(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        'refs/heads/main',
        'a..b',
        'a b',
        'a~1',
        'x^',
        'a:b',
        'q?',
        'st*r',
        'br[',
        r'back\slash',
        '/lead',
        'trail/',
        'end.',
        'x.lock',
        '-dash',
        '@',
        'a@{1}',
        'a//b',
        '.hidden',
        'a/.b',
      ]) {
        expect(isValidBranchName(bad), isFalse, reason: bad);
      }
    });

    test('URLs must not carry credentials', () {
      expect(
        one(const AppSettings(remoteUrl: 'https://me:tok@github.com/me/n.git')),
        contains('Remove the user name or token'),
      );
      expect(
        one(const AppSettings(remoteUrl: 'https://tok@github.com/me/n.git')),
        contains('Remove the user name or token'),
      );
      expect(
        one(
          const AppSettings(
            remoteUrl: 'ssh://git:pw@host/n.git',
            auth: GitAuth(method: AuthMethod.sshAgent),
          ),
        ),
        contains('Remove the password'),
      );
    });

    test('local paths must be Git repositories', () async {
      final plainDir = await Directory(p.join(sandbox.path, 'plain')).create();
      final repo = await bare('ok.git');
      expect(
        one(AppSettings(remoteUrl: plainDir.path)),
        contains('not a Git repository'),
      );
      expect(
        one(AppSettings(remoteUrl: p.join(sandbox.path, 'nope'))),
        contains('does not exist'),
      );
      expect(validateGitSettings(AppSettings(remoteUrl: repo)), isEmpty);
      expect(
        validateGitSettings(AppSettings(remoteUrl: Uri.file(repo).toString())),
        isEmpty,
      );
    });

    test('the auth method must suit the URL', () async {
      expect(
        one(const AppSettings(remoteUrl: 'git@github.com:me/n.git')),
        contains('need SSH key or SSH agent'),
      );
      expect(
        one(
          const AppSettings(
            remoteUrl: 'http://example.com/n.git',
            auth: GitAuth(method: AuthMethod.httpsToken, password: 't'),
          ),
        ),
        contains('needs an https://'),
      );
      // Unencrypted transports are refused whatever the auth method.
      expect(
        one(const AppSettings(remoteUrl: 'http://example.com/n.git')),
        contains('unencrypted'),
      );
      expect(
        one(const AppSettings(remoteUrl: 'git://example.com/n.git')),
        contains('Unsupported remote URL'),
      );
      expect(
        one(
          const AppSettings(
            remoteUrl: 'https://example.com/n.git',
            auth: GitAuth(method: AuthMethod.httpsToken),
          ),
        ),
        contains('Enter the HTTPS token'),
      );
      expect(
        one(
          const AppSettings(
            remoteUrl: 'https://example.com/n.git',
            auth: GitAuth(method: AuthMethod.sshAgent),
          ),
        ),
        contains('needs an SSH URL'),
      );
      final key = File(p.join(sandbox.path, 'id_ed25519'))
        ..writeAsStringSync('k');
      AppSettings ssh(String path) => AppSettings(
        remoteUrl: 'git@host:n.git',
        auth: GitAuth(method: AuthMethod.sshKey, sshKeyPath: path),
      );
      expect(one(ssh('')), contains('Enter the path'));
      expect(one(ssh('${key.path}.pub')), contains('not the public key'));
      expect(one(ssh('${key.path}-missing')), contains('does not exist'));
      expect(validateGitSettings(ssh(key.path)), isEmpty);
      final home = Platform.environment['HOME'];
      if (home != null && key.path.startsWith('$home/')) {
        expect(
          validateGitSettings(ssh('~${key.path.substring(home.length)}')),
          isEmpty,
        );
      }
      expect(GitBackend.expandHome('~/x'), '${home ?? '~'}/x');
      expect(GitBackend.expandHome('/abs/~/x'), '/abs/~/x');
      expect(
        validateGitSettings(
          const AppSettings(
            remoteUrl: 'https://example.com/n.git',
            auth: GitAuth(method: AuthMethod.httpsToken, password: 't'),
          ),
        ),
        isEmpty,
      );
    });
  });

  test('clone, sync and force push refuse http:// remotes', () async {
    // Nothing listens there: the refusal must come before any connection.
    const url = 'http://127.0.0.1:9/n.git';
    final git = GitBackend();
    await expectLater(
      git.clone(url, path('plain'), branch: 'main'),
      throwsA(
        isA<GitException>().having(
          (e) => e.message,
          'message',
          contains('unencrypted'),
        ),
      ),
    );
    expect(Directory(path('plain')).existsSync(), isFalse);
    // A remote saved before the rule existed.
    final dir = path('old');
    await git.init(dir, branch: 'main');
    await git.setRemoteUrl(dir, url);
    for (final run in [
      () => git.sync(dir, 'main'),
      () => git.resolve(dir, 'main', ConflictResolution.forcePushLocal),
    ]) {
      await expectLater(
        run(),
        throwsA(
          isA<GitException>().having(
            (e) => e.message,
            'message',
            contains('unencrypted'),
          ),
        ),
      );
    }
  });

  test('SSH URLs without a user get git@', () {
    expect(withSshUser('ssh://host/n.git'), 'ssh://git@host/n.git');
    expect(withSshUser('ssh://host:2222/n.git'), 'ssh://git@host:2222/n.git');
    expect(withSshUser('github.com:me/n.git'), 'git@github.com:me/n.git');
    expect(withSshUser(' me@host:n.git '), 'me@host:n.git');
    expect(withSshUser('ssh://me@host/n.git'), 'ssh://me@host/n.git');
    expect(withSshUser('https://host/n.git'), 'https://host/n.git');
    expect(withSshUser('/srv/n.git'), '/srv/n.git');
    expect(withSshUser(r'C:\notes\n.git'), r'C:\notes\n.git');
  });
}

/// An HTTPS remote that accepts connections and never answers (not even
/// the TLS handshake), like a server that hung. Closed when the test ends.
Future<String> silentServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final held = <Socket>[];
  server.listen(held.add);
  addTearDown(() async {
    for (final socket in held) {
      socket.destroy();
    }
    await server.close();
  });
  return 'https://127.0.0.1:${server.port}/notes.git';
}
