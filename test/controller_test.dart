// Integration tests: the Git backend (dargit) against local bare repositories.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dargit/dargit.dart' show Git;
import 'package:gitmarker/controller.dart';
import 'package:gitmarker/git.dart';
import 'package:gitmarker/note_models.dart';
import 'package:path/path.dart' as p;

late Directory sandbox;

Future<String> bareRemote(String name) async {
  final path = p.join(sandbox.path, '$name.git');
  await Git().init(path, initialBranch: 'main', bare: true);
  return path;
}

Future<AppController> client(
  String name, {
  String remote = '',
  String branch = 'main',
}) async {
  final support = p.join(sandbox.path, name);
  await Directory(support).create(recursive: true);
  if (remote.isNotEmpty || branch != 'main') {
    await File(p.join(support, AppController.settingsFileName))
        .writeAsString('{"remoteUrl": "$remote", "branch": "$branch"}');
  }
  var tick = 0;
  final controller = AppController(
    supportDir: support,
    clock: () => DateTime.utc(2026, 1, 1).add(Duration(minutes: tick++)),
  );
  await controller.init();
  expect(controller.fatalError, isNull);
  return controller;
}

/// Commit subjects reachable from HEAD, newest first.
Future<List<String>> log(String dir) async {
  return [for (final e in await Git().log(dir)) e.subject];
}

/// The `git` executable, when installed, used only as an independent check
/// that repositories written by dargit are valid for real Git.
final bool gitCliAvailable = () {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

void main() {
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('gitmarker_ctl_');
  });
  tearDown(() => sandbox.delete(recursive: true));

  test(
    'repositories written by dargit pass git fsck and read back in git log',
    () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      var note = await a.createNote(title: 'Interop', body: 'v1');
      await a.createFolder('f');
      note = await a.moveNote(note, 'f');
      await a.saveNote(note.copyWith(body: 'v2'), original: note);
      await a.sync();
      for (final dir in [a.dataDir, remote]) {
        final fsck = Process.runSync('git', [
          'fsck',
          '--strict',
        ], workingDirectory: dir);
        expect(fsck.exitCode, 0, reason: '${fsck.stdout}${fsck.stderr}');
      }
      final cliLog = Process.runSync('git', [
        'log',
        '--follow',
        '--format=%s',
        '--',
        'f/Interop.md',
      ], workingDirectory: a.dataDir);
      expect('${cliLog.stdout}'.trim().split('\n'), [
        'Update note: Interop',
        'Move note: Interop to f',
        'Create note: Interop',
      ]);
      final history = await a.openHistory(a.notes.single);
      expect(history.revisions.map((r) => r.message), [
        'Update note: Interop',
        'Move note: Interop to f',
        'Create note: Interop',
      ]);
    },
    skip: gitCliAvailable ? false : 'git executable not installed',
  );

  group('local repository', () {
    test('note operations are committed automatically', () async {
      final c = await client('a');
      final note = await c.createNote(title: 'First', body: 'hello');
      final edited = await c.saveNote(
        note.copyWith(body: 'hello world'),
        original: note,
      );
      await c.createFolder('Archive');
      final moved = await c.moveNote(edited, 'Archive');
      final pinned = await c.saveNote(
        moved.copyWith(pinned: true),
        original: moved,
      );
      await c.deleteNote(pinned);
      expect(await log(c.dataDir), [
        'Delete note: First',
        'Update note: First',
        'Move note: First to Archive',
        'Create folder: Archive',
        'Update note: First',
        'Create note: First',
      ]);
      expect(c.notes, isEmpty);
      expect(c.folders, ['Archive']);
    });

    test('a deleted note can be restored exactly', () async {
      final c = await client('a');
      final note = await c.createNote(
        title: 'Keep',
        body: 'body',
        color: NoteColor.teal,
        tags: ['x'],
        pinned: true,
      );
      await c.deleteNote(note);
      expect(c.notes, isEmpty);
      final restored = await c.restoreNote(note);
      expect(restored.path, note.path);
      final reloaded = c.notes.single;
      expect(reloaded.sameContentAs(note), isTrue);
      expect(reloaded.created, note.created);
      expect((await log(c.dataDir)).first, 'Restore note: Keep');
    });

    test('restoring onto a taken path picks a free name', () async {
      final data = p.join(sandbox.path, 'a', AppController.dataDirName);
      await Directory(data).create(recursive: true);
      await File(p.join(data, 'plain.md')).writeAsString('# Plain\n\nold');
      final c = await client('a');
      final plain = c.notes.single;
      await c.deleteNote(plain);
      await c.createNote(title: 'plain', body: 'newcomer');
      final restored = await c.restoreNote(plain);
      expect(restored.path, 'plain (2).md');
      expect(restored.title, 'Plain');
      expect(c.notes.length, 2);
    });

    test('unchanged saves do not commit', () async {
      final c = await client('a');
      final note = await c.createNote(title: 'T', body: 'b');
      await c.saveNote(note.copyWith(), original: note);
      expect(await log(c.dataDir), ['Create note: T']);
    });

    test('existing Markdown files are imported on first start', () async {
      final data = p.join(sandbox.path, 'a', AppController.dataDirName);
      await Directory(p.join(data, 'sub')).create(recursive: true);
      await File(p.join(data, 'sub', 'x.md')).writeAsString('plain');
      final c = await client('a');
      expect(c.notes.single.path, 'sub/x.md');
      expect(await log(c.dataDir), ['Import existing notes']);
    });

    test('malformed files are reported, not loaded', () async {
      final data = p.join(sandbox.path, 'a', AppController.dataDirName);
      await Directory(data).create(recursive: true);
      await File(p.join(data, 'ok.md')).writeAsString('fine');
      await File(p.join(data, 'broken.md'))
          .writeAsString('---\ntitle: [\n---\n');
      final c = await client('a');
      expect(c.notes.single.path, 'ok.md');
      expect(c.skippedFiles.single.path, 'broken.md');
      await File(p.join(data, 'broken.md'))
          .writeAsString('---\ntitle: Fixed\n---\n');
      await c.refresh();
      expect(c.skippedFiles, isEmpty);
      expect(c.notes.map((n) => n.title), containsAll(['Fixed', 'ok']));
    });

    test('search, folder and tag filters', () async {
      final c = await client('a');
      await c.createNote(title: 'Shopping', body: 'milk', tags: ['home']);
      await c.createNote(title: 'مكتبة', body: 'كتب', folder: 'ar');
      await c.createNote(
        title: 'Work',
        body: 'report',
        folder: 'ar/sub',
        tags: ['job'],
      );
      c.query = 'MILK';
      expect(c.visibleNotes.map((n) => n.title), ['Shopping']);
      c.query = 'مَكْتَبَه';
      expect(c.visibleNotes.map((n) => n.title), ['مكتبة']);
      c.query = '';
      c.showFolder('ar');
      expect(c.visibleNotes.map((n) => n.title), ['Work', 'مكتبة']);
      c.showFolder('');
      expect(c.visibleNotes.map((n) => n.title), ['Shopping']);
      c.showTag('job');
      expect(c.visibleNotes.map((n) => n.title), ['Work']);
      expect(c.tags, ['home', 'job']);
    });

    test('history navigates back, forward and to latest', () async {
      final c = await client('a');
      var note = await c.createNote(title: 'H', body: 'v1');
      note = await c.saveNote(note.copyWith(body: 'v2'), original: note);
      await c.createFolder('f');
      note = await c.moveNote(note, 'f');
      note = await c.saveNote(note.copyWith(body: 'v3'), original: note);

      final history = await c.openHistory(note);
      expect(history.revisions.length, 4);
      await history.load();
      expect(history.isLatest, isTrue);
      expect(history.current!.note!.body, 'v3');
      expect(history.canGoForward, isFalse);

      await history.back();
      expect(history.current!.note!.body, 'v2');
      expect(history.current!.revision.message, startsWith('Move note'));
      await history.back();
      await history.back();
      expect(history.current!.note!.body, 'v1');
      expect(history.current!.revision.path, 'H.md');
      expect(history.canGoBack, isFalse);

      await history.forward();
      expect(history.current!.note!.body, 'v2');
      await history.latest();
      expect(history.isLatest, isTrue);
      expect(history.current!.note!.body, 'v3');
      await history.dispose();
    });

    test('sync without remote is a no-op', () async {
      final c = await client('a');
      expect((await c.sync()).outcome, SyncOutcome.noRemote);
    });
  });

  group('sync', () {
    test('push, fast-forward, rebase and up to date', () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      final b = await client('b', remote: remote);

      expect((await a.sync()).outcome, SyncOutcome.upToDate);
      await a.createNote(title: 'From A', body: '1');
      expect((await a.sync()).outcome, SyncOutcome.pushed);

      expect((await b.sync()).outcome, SyncOutcome.fastForwarded);
      expect(b.notes.single.title, 'From A');

      await a.createNote(title: 'A2', body: '');
      await b.createNote(title: 'B2', body: '');
      expect((await a.sync()).outcome, SyncOutcome.pushed);
      expect((await b.sync()).outcome, SyncOutcome.rebased);
      expect(b.notes.map((n) => n.title).toSet(), {'From A', 'A2', 'B2'});
      expect((await a.sync()).outcome, SyncOutcome.fastForwarded);
      expect((await a.sync()).outcome, SyncOutcome.upToDate);
      expect(a.notes.length, 3);
    });

    test('a note created and deleted before syncing syncs cleanly', () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      await a.createNote(title: 'Keep', body: '');
      final temporary = await a.createNote(title: 'Temporary', body: 'x');
      await a.deleteNote(temporary);
      expect((await a.sync()).outcome, SyncOutcome.pushed);
      final b = await client('b', remote: remote);
      expect(b.notes.map((n) => n.title), ['Keep']);
      expect((await a.sync()).outcome, SyncOutcome.upToDate);
    });

    test('a note deleted and synced can be restored and synced', () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      final note = await a.createNote(title: 'Back', body: 'again');
      await a.sync();
      await a.deleteNote(note);
      await a.sync();
      await a.restoreNote(note);
      expect((await a.sync()).outcome, SyncOutcome.pushed);
      final b = await client('b', remote: remote);
      expect(b.notes.single.body, 'again');
    });

    test('a sync that times out reports it and frees the app', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final socket in held) {
          socket.destroy();
        }
        await server.close();
      });
      final support = p.join(sandbox.path, 'slow');
      final c = AppController(
        supportDir: support,
        networkTimeout: const Duration(seconds: 1),
      );
      await c.init();
      await c.applySettings(
        AppSettings(remoteUrl: 'https://127.0.0.1:${server.port}/n.git'),
      );
      await c.createNote(title: 'Local', body: 'x');
      final result = await c.sync();
      expect(result.outcome, SyncOutcome.error);
      expect(result.message, contains('network timeout'));
      expect(c.syncing, isFalse);
      // Later operations are not stuck behind the abandoned sync.
      await c.createNote(title: 'After', body: 'y');
      expect(c.notes, hasLength(2));
    });

    test('dirty working tree blocks sync', () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      await File(p.join(a.dataDir, 'external.md'))
          .writeAsString('edited elsewhere');
      expect((await a.sync()).outcome, SyncOutcome.dirtyTree);
      expect(await a.commitPendingChanges(), isTrue);
      expect((await a.sync()).outcome, SyncOutcome.pushed);
    });

    Future<(AppController, AppController)> conflicted() async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote);
      final b = await client('b', remote: remote);
      await a.createNote(title: 'Shared', body: 'base');
      await a.sync();
      await b.sync();
      final na = a.notes.single;
      await a.saveNote(na.copyWith(body: 'from A'), original: na);
      await a.sync();
      final nb = b.notes.single;
      await b.saveNote(nb.copyWith(body: 'from B'), original: nb);
      final result = await b.sync();
      expect(result.outcome, SyncOutcome.conflict);
      expect(result.conflictedFiles, ['Shared.md']);
      expect(b.syncPaused, isTrue);
      // The rebase was aborted: working tree is clean and untouched.
      expect(
        Directory(p.join(b.dataDir, '.git', 'rebase-merge')).existsSync(),
        isFalse,
      );
      expect(b.notes.single.body, 'from B');
      return (a, b);
    }

    test('conflict: keep remote', () async {
      final (_, b) = await conflicted();
      await b.resolveConflict(ConflictResolution.keepRemote);
      expect(b.syncPaused, isFalse);
      expect(b.notes.single.body, 'from A');
      expect((await b.sync()).outcome, SyncOutcome.upToDate);
    });

    test('conflict: force push local', () async {
      final (a, b) = await conflicted();
      await b.resolveConflict(ConflictResolution.forcePushLocal);
      expect(b.syncPaused, isFalse);
      // A now diverges from the rewritten remote and conflicts too; keeping
      // the remote gives it B's version.
      expect((await a.sync()).outcome, SyncOutcome.conflict);
      await a.resolveConflict(ConflictResolution.keepRemote);
      expect(a.notes.single.body, 'from B');
    });

    test('conflict: abort leaves both sides as they were', () async {
      final (_, b) = await conflicted();
      await b.resolveConflict(ConflictResolution.abort);
      expect(b.syncPaused, isFalse);
      expect(b.notes.single.body, 'from B');
      expect((await b.sync()).outcome, SyncOutcome.conflict);
    });

    test(
      'a local-only repository can be attached to an empty remote',
      () async {
        final remote = await bareRemote('origin');
        final a = await client('a');
        await a.createNote(title: 'Local', body: '');
        await a.applySettings(a.settings.copyWith(remoteUrl: remote));
        expect(a.replacesRepository(a.settings), isFalse);
        expect((await a.sync()).outcome, SyncOutcome.pushed);
        final b = await client('b', remote: remote);
        expect(b.notes.single.title, 'Local');
      },
    );

    test('a remote branch other than main is cloned and synced', () async {
      final remote = await bareRemote('origin');
      final a = await client('a', remote: remote, branch: 'notes');
      await a.createNote(title: 'N', body: '');
      expect((await a.sync()).outcome, SyncOutcome.pushed);
      final b = await client('b', remote: remote, branch: 'notes');
      expect(b.notes.single.title, 'N');
    });
  });

  group('remote replacement', () {
    test('reports unpushed commits and keeps a backup', () async {
      final first = await bareRemote('first');
      final second = await bareRemote('second');
      final seed = await client('seed', remote: second);
      await seed.createNote(title: 'Second remote note', body: '');
      await seed.sync();

      final a = await client('a', remote: first);
      await a.createNote(title: 'Unpushed', body: '');
      final next = a.settings.copyWith(remoteUrl: second);
      expect(a.replacesRepository(next), isTrue);
      final check = await a.checkRemoteChange();
      expect(check.unpushedCommits, 1);
      expect(check.hasUncommittedChanges, isFalse);
      expect(check.losesData, isTrue);

      final backup = await a.applySettings(next, keepBackup: true);
      expect(backup, isNotNull);
      expect(File(p.join(backup!, 'Unpushed.md')).existsSync(), isTrue);
      expect(a.notes.single.title, 'Second remote note');
      expect(a.settings.remoteUrl, second);

      // Settings persist across restarts.
      final restarted = AppController(supportDir: a.supportDir);
      await restarted.init();
      expect(restarted.settings.remoteUrl, second);
      expect(restarted.notes.single.title, 'Second remote note');
    });

    test('without backup the old data is removed', () async {
      final first = await bareRemote('first');
      final second = await bareRemote('second');
      final a = await client('a', remote: first);
      await a.createNote(title: 'Gone', body: '');
      final backup = await a.applySettings(
        a.settings.copyWith(remoteUrl: second),
        keepBackup: false,
      );
      expect(backup, isNull);
      expect(a.notes, isEmpty);
      final leftovers = Directory(a.supportDir)
          .listSync()
          .map((e) => p.basename(e.path));
      expect(leftovers.where((n) => n.contains('backup')), isEmpty);
    });

    test('uncommitted changes are reported', () async {
      final first = await bareRemote('first');
      final a = await client('a', remote: first);
      await File(p.join(a.dataDir, 'loose.md')).writeAsString('x');
      expect((await a.checkRemoteChange()).hasUncommittedChanges, isTrue);
    });

    test('a failed clone keeps the current repository', () async {
      final first = await bareRemote('first');
      final second = await bareRemote('second');
      final seed = await client('seed', remote: second);
      await seed.createNote(title: 'On main', body: '');
      await seed.sync();

      final a = await client('a', remote: first);
      await a.createNote(title: 'Keep me', body: '');
      // The second remote has commits but no branch 'typo'.
      await expectLater(
        a.applySettings(a.settings.copyWith(remoteUrl: second, branch: 'typo')),
        throwsA(
          isA<GitException>().having(
            (e) => e.message,
            'message',
            'Remote branch typo not found in upstream origin (branches: main)',
          ),
        ),
      );
      expect(a.settings.remoteUrl, first);
      expect(a.notes.single.title, 'Keep me');
      expect(a.lastError, isNotNull);
      final leftovers = Directory(a.supportDir)
          .listSync()
          .map((e) => p.basename(e.path));
      expect(leftovers.where((n) => n.contains('incoming')), isEmpty);
    });

    test('invalid settings are rejected before anything changes', () async {
      final first = await bareRemote('first');
      final a = await client('a', remote: first);
      final missing = p.join(sandbox.path, 'does-not-exist.git');
      await expectLater(
        a.applySettings(a.settings.copyWith(remoteUrl: missing)),
        throwsA(isA<SettingsException>()),
      );
      expect(a.settings.remoteUrl, first);
      expect(a.lastError, contains('does not exist'));
    });
  });

  group('settings file', () {
    test('an unreadable settings file falls back to defaults', () async {
      final support = p.join(sandbox.path, 'broken');
      await Directory(support).create(recursive: true);
      await File(p.join(support, AppController.settingsFileName))
          .writeAsString('{not json');
      final c = AppController(supportDir: support);
      await c.init();
      expect(c.fatalError, isNull);
      expect(c.settings.remoteUrl, isEmpty);
      expect(c.settings.branch, 'main');
    });
  });

  test('applied SSH URLs gain the default user', () async {
    final c = AppController(supportDir: p.join(sandbox.path, 'ssh'));
    await c.init();
    await c.applySettings(
      const AppSettings(
        remoteUrl: 'github.com:me/n.git',
        auth: GitAuth(method: AuthMethod.sshAgent),
      ),
    );
    expect(c.settings.remoteUrl, 'git@github.com:me/n.git');
    expect(await GitBackend().remoteUrl(c.dataDir), 'git@github.com:me/n.git');
  });
}
