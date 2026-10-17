import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitmarker/note_models.dart';
import 'package:gitmarker/note_store.dart';
import 'package:path/path.dart' as p;

void main() {
  group('parse', () {
    test('plain note: a leading # heading is the title', () {
      final note = NoteStore.parse(
        'ideas.md',
        '\n# Idea  \n\n\ntext\n## Sub\n',
      )!;
      expect(note.format, NoteFormat.plain);
      expect(note.title, 'Idea');
      expect(note.titleInHeading, isTrue);
      expect(note.body, 'text\n## Sub\n');
      expect(NoteStore.serialize(note), '# Idea\n\ntext\n## Sub\n');
    });

    test('plain note: only a level-1 heading on the first line counts', () {
      for (final text in [
        '## Sub\ntext',
        'intro\n# Later',
        '#hashtag',
        '#  \nx',
      ]) {
        final note = NoteStore.parse('n.md', text)!;
        expect(note.title, 'n', reason: text);
        expect(note.titleInHeading, isFalse, reason: text);
        expect(note.body, text);
      }
    });

    test('malformed front matter reports why', () {
      String reason(String text) {
        try {
          NoteStore.parseOrThrow('a.md', text);
          return 'parsed';
        } on FormatException catch (e) {
          return e.message;
        }
      }

      expect(reason('---\ntitle: x\nno end'), contains('not closed'));
      expect(
        reason('---\ntitle: [unclosed\n---\n'),
        contains('not valid YAML'),
      );
      expect(reason('---\n- a list\n---\n'), contains('key: value'));
    });

    test('plain note: title from file name, body is the whole file', () {
      final note = NoteStore.parse(
        'work/Shopping list.md',
        '- milk\n- eggs\n',
      )!;
      expect(note.format, NoteFormat.plain);
      expect(note.title, 'Shopping list');
      expect(note.body, '- milk\n- eggs\n');
      expect(note.folder, 'work');
      expect(note.hasMetadata, isFalse);
    });

    test('managed note reads metadata', () {
      final note = NoteStore.parse('a.md', '''---
title: "Groceries: weekly"
tags: [home, food]
pinned: true
color: yellow
created: 2026-01-02T03:04:05.000Z
author: someone
nested: {a: 1}
---

Body line
''')!;
      expect(note.format, NoteFormat.managed);
      expect(note.title, 'Groceries: weekly');
      expect(note.tags, ['home', 'food']);
      expect(note.pinned, isTrue);
      expect(note.color, NoteColor.yellow);
      expect(note.created, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(note.body, 'Body line\n');
      expect(note.extraFrontMatter, {
        'author': 'someone',
        'nested': {'a': 1},
      });
    });

    test('managed note without title falls back to file name', () {
      final note = NoteStore.parse('x/Idea.md', '---\ntags: a, b\n---\ntext')!;
      expect(note.title, 'Idea');
      expect(note.tags, ['a', 'b']);
      expect(note.body, 'text');
    });

    test('empty front matter is a managed note', () {
      final note = NoteStore.parse('n.md', '---\n---\nhi')!;
      expect(note.format, NoteFormat.managed);
      expect(note.body, 'hi');
    });

    test('CRLF and BOM are handled', () {
      final note = NoteStore.parse(
        'n.md',
        '﻿---\r\ntitle: T\r\n---\r\n\r\nb\r\n',
      )!;
      expect(note.title, 'T');
      expect(note.body, 'b\n');
    });

    test('malformed front matter is skipped', () {
      expect(NoteStore.parse('a.md', '---\ntitle: x\nno end'), isNull);
      expect(NoteStore.parse('a.md', '---\ntitle: [unclosed\n---\n'), isNull);
      expect(NoteStore.parse('a.md', '---\n- a list\n---\n'), isNull);
    });

    test('a horizontal rule that is not at the start is plain text', () {
      final note = NoteStore.parse('a.md', 'text\n---\nmore')!;
      expect(note.format, NoteFormat.plain);
    });
  });

  group('serialize', () {
    test('round trips managed notes, quoting where needed', () {
      final note = Note(
        path: 'a.md',
        title: 'true',
        body: '# Heading\n\n---\n\nText',
        tags: ['one', 'two words', 'has: colon', '١٢', 'وسم'],
        pinned: true,
        color: NoteColor.darkBlue,
        created: DateTime.utc(2026, 5, 6),
        extraFrontMatter: {
          'custom': 'value',
          'list': [1, 2],
        },
      );
      final text = NoteStore.serialize(note);
      expect(text, startsWith('---\ntitle: "true"\n'));
      final back = NoteStore.parse('a.md', text)!;
      expect(back.sameContentAs(note), isTrue);
      expect(back.created, note.created);
      expect(back.extraFrontMatter, {
        'custom': 'value',
        'list': [1, 2],
      });
    });

    test('Arabic titles stay readable in YAML', () {
      final text = NoteStore.serialize(
        Note(path: 'a.md', title: 'ملاحظة جديدة', body: ''),
      );
      expect(text, contains('title: ملاحظة جديدة\n'));
      expect(NoteStore.parse('a.md', text)!.title, 'ملاحظة جديدة');
    });

    test('titles with newlines, quotes and leading symbols round trip', () {
      for (final title in [
        '- dash',
        '#hash',
        "it's",
        'a "b"',
        ' padded ',
        '2026-01-01',
        '1.5',
        '',
      ]) {
        final text = NoteStore.serialize(
          Note(path: 'a.md', title: title, body: 'x'),
        );
        expect(NoteStore.parse('a.md', text)!.title, title, reason: text);
      }
    });

    test('plain notes serialize to their body', () {
      final note = Note(
        path: 'a.md',
        title: 'a',
        body: 'raw',
        format: NoteFormat.plain,
      );
      expect(NoteStore.serialize(note), 'raw');
    });
  });

  test('fileNameFor keeps unicode and strips unsafe characters', () {
    expect(NoteStore.fileNameFor('ملاحظة'), 'ملاحظة');
    expect(NoteStore.fileNameFor('a/b:c*?'), 'a_b_c__');
    expect(NoteStore.fileNameFor('  ..dots..  '), 'dots');
    expect(NoteStore.fileNameFor('   '), 'Untitled');
    expect(NoteStore.fileNameFor('first\nsecond'), 'first');
  });

  test('fileNameFor gives portable names', () {
    // Windows device names, with or without an extension.
    expect(NoteStore.fileNameFor('CON'), 'CON-note');
    expect(NoteStore.fileNameFor('nul'), 'nul-note');
    expect(NoteStore.fileNameFor('com1.backup'), 'com1-note.backup');
    expect(NoteStore.fileNameFor('Console'), 'Console');
    expect(NoteStore.fileNameFor(' a  bad/name... '), 'a bad_name');
    expect(NoteStore.fileNameFor('...'), 'Untitled');
  });

  test('fileNameFor limits names by UTF-8 bytes, not characters', () {
    for (final title in ['😀' * 120, 'ملاحظة' * 40, '漢' * 100, 'a' * 300]) {
      final name = NoteStore.fileNameFor(title);
      expect(
        utf8.encode(name).length,
        lessThanOrEqualTo(NoteStore.maxStemBytes),
      );
      expect(name, isNotEmpty);
      // Never cuts a character in half.
      expect(title.startsWith(name), isTrue);
    }
  });

  test('normalizeFolder rejects traversal and reserved names', () {
    expect(NoteStore.normalizeFolder(' a / b/ '), 'a/b');
    expect(NoteStore.normalizeFolder(r'a\b'), 'a/b');
    expect(
      () => NoteStore.normalizeFolder('../x'),
      throwsA(isA<NoteStoreException>()),
    );
    for (final folder in ['.git', '.GIT', '.Gitmarker', 'work/.Git/objects']) {
      expect(
        () => NoteStore.normalizeFolder(folder),
        throwsA(isA<NoteStoreException>()),
        reason: folder,
      );
    }
  });

  group('hostile files', () {
    test('YAML aliases cannot expand front matter without bound', () {
      // Seven levels of ten aliases each: 10^7 values from 8 lines.
      final yaml = StringBuffer('---\na: &a [x,x,x,x,x,x,x,x,x,x]\n');
      for (var i = 1; i < 7; i++) {
        final prev = i == 1 ? 'a' : 'l${i - 1}';
        yaml.writeln('l$i: &l$i [${List.filled(10, '*$prev').join(',')}]');
      }
      yaml.write('---\nbody');
      expect(
        () => NoteStore.parseOrThrow('bomb.md', yaml.toString()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      // Ordinary aliases still work.
      final note = NoteStore.parseOrThrow(
        'ok.md',
        '---\nx: &v [1, 2]\ny: *v\n---\n',
      );
      expect(note.extraFrontMatter['y'], [1, 2]);
    });

    test('deeply nested front matter is a skipped file, not a crash', () {
      final deep = '---\na: ${'[' * 100000}${']' * 100000}\n---\nbody';
      expect(NoteStore.parse('deep.md', deep), isNull);
      expect(
        () => NoteStore.parseOrThrow('deep.md', deep),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('file operations', () {
    late Directory dir;
    late NoteStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gitmarker_store_');
      store = NoteStore(dir.path);
    });

    tearDown(() => dir.delete(recursive: true));

    Future<void> write(String rel, String content) async {
      final file = File(p.joinAll([dir.path, ...rel.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    Future<Note?> load(String rel) async =>
        NoteStore.parse(rel, await File(store.absolute(rel)).readAsString());

    Future<List<String>> folders() async {
      await store.loadAll();
      return store.folders;
    }

    test(
      'loadAll discovers notes recursively and skips excluded dirs',
      () async {
        await write('a.md', 'A');
        await write('deep/er/b.MD', '---\ntitle: B\n---\n');
        await write('.git/c.md', 'ignored');
        await write('.gitmarker/d.md', 'ignored');
        await write('notes.txt', 'ignored');
        await write('bad.md', '---\ntitle: [\n---\n');
        final notes = await store.loadAll();
        expect(notes.map((n) => n.path), ['a.md', 'deep/er/b.MD']);
        expect(await folders(), ['deep', 'deep/er']);
      },
    );

    test('a note with a very long title can be saved', () async {
      final change = await store.create(title: '😀' * 120, body: 'x');
      expect(File(store.absolute(change.note!.path)).existsSync(), isTrue);
      final again = await store.create(title: '😀' * 120, body: 'y');
      expect(again.note!.path, isNot(change.note!.path));
      expect((await store.loadAll()).length, 2);
    });

    test('reserved directories are skipped in any letter case', () async {
      await write('.GIT/x.md', 'ignored');
      await write('sub/.Gitmarker/y.md', 'ignored');
      await write('sub/z.md', 'kept');
      expect((await store.loadAll()).map((n) => n.path), ['sub/z.md']);
      expect(await folders(), ['sub']);
    });

    test('plain notes take their modification time from the file', () async {
      await write('plain.md', 'body');
      await write('managed.md', '---\ntitle: M\n---\n');
      final when = DateTime(2024, 5, 6, 7, 8, 9);
      await File(store.absolute('plain.md')).setLastModified(when);
      final notes = {for (final n in await store.loadAll()) n.path: n};
      expect(notes['plain.md']!.modified, when);
      expect(notes['managed.md']!.modified, isNull);
    });

    test('create picks unique file names', () async {
      final a = await store.create(title: 'Same', body: '');
      final b = await store.create(title: 'same', body: '');
      final c = await store.create(title: '', body: 'From body\nmore');
      expect(a.note!.path, 'Same.md');
      expect(b.note!.path, 'same (2).md');
      expect(c.note!.path, 'From body.md');
      expect((await store.loadAll()).length, 3);
    });

    test('saving a plain note with metadata converts it to managed', () async {
      await write('plain.md', 'body');
      final original = (await load('plain.md'))!;
      final change = await store.save(
        original.copyWith(pinned: true),
        original: original,
      );
      expect(change.note!.format, NoteFormat.managed);
      final reread = (await load('plain.md'))!;
      expect(reread.pinned, isTrue);
      expect(reread.title, 'plain');
      expect(reread.body, 'body');
    });

    test('renaming a plain note renames its file', () async {
      await write('dir/old.md', 'body');
      final original = (await load('dir/old.md'))!;
      final change = await store.save(
        original.copyWith(title: 'new'),
        original: original,
      );
      expect(change.note!.path, 'dir/new.md');
      expect(change.paths, unorderedEquals(['dir/new.md', 'dir/old.md']));
      expect(File(p.join(dir.path, 'dir', 'old.md')).existsSync(), isFalse);
      final renamed = (await load('dir/new.md'))!;
      expect(renamed.title, 'new');
      expect(renamed.body, 'body');
      // The new title is kept as the note's heading, so it stays plain.
      expect(renamed.format, NoteFormat.plain);
      expect(
        File(store.absolute('dir/new.md')).readAsStringSync(),
        '# new\n\nbody',
      );
    });

    test('editing a plain note keeps it plain and its heading', () async {
      await write('plain.md', '# Original\n\nBody');
      final original = (await load('plain.md'))!;
      final change = await store.save(
        original.copyWith(title: 'Updated', body: 'Plain body\n'),
        original: original,
      );
      expect(change.note!.path, 'Updated.md');
      expect(
        File(store.absolute('Updated.md')).readAsStringSync(),
        '# Updated\n\nPlain body\n',
      );
      final reread = (await load('Updated.md'))!;
      expect((reread.format, reread.title), (NoteFormat.plain, 'Updated'));
    });

    test('pinning a plain note moves its heading into front matter', () async {
      await write('idea.md', '# Idea\n\ntext');
      final original = (await load('idea.md'))!;
      await store.save(original.copyWith(pinned: true), original: original);
      final reread = (await load('idea.md'))!;
      expect(reread.format, NoteFormat.managed);
      expect(
        (reread.title, reread.body, reread.pinned),
        ('Idea', 'text', true),
      );
    });

    test('a rename onto an existing title leaves that note alone', () async {
      final a = (await store.create(title: 'Alpha', body: 'a')).note!;
      final b = (await store.create(title: 'Beta', body: 'b')).note!;
      final change = await store.save(b.copyWith(title: 'Alpha'), original: b);
      // Managed notes keep their file; the title lives in front matter.
      expect(change.note!.path, b.path);
      expect((await load(a.path))!.body, 'a');

      await write('plain.md', 'p');
      final plain = (await load('plain.md'))!;
      final renamed = await store.save(
        plain.copyWith(title: 'Alpha'),
        original: plain,
      );
      expect(renamed.note!.path, 'Alpha (2).md');
      expect((await load(a.path))!.body, 'a');
    });

    test('skipped files are listed with a reason', () async {
      await write('good.md', 'fine');
      await write('bad.md', '---\ntitle: [\n---\n');
      await write('deep/open.md', '---\ntitle: x\n');
      expect((await store.loadAll()).map((n) => n.path), ['good.md']);
      expect(store.skipped.map((s) => s.path), ['bad.md', 'deep/open.md']);
      expect(store.skipped.first.reason, contains('YAML'));
      await File(store.absolute('bad.md'))
          .writeAsString('---\ntitle: ok\n---\n');
      await File(store.absolute('deep/open.md')).delete();
      expect((await store.loadAll()).length, 2);
      expect(store.skipped, isEmpty);
    });

    test('oversized files are skipped, not loaded', () async {
      await write('ok.md', 'fine');
      final big = File(store.absolute('big.md'));
      await big.writeAsString('x');
      final handle = await big.open(mode: FileMode.append);
      await handle.truncate(NoteStore.maxNoteBytes + 1);
      await handle.close();
      expect((await store.loadAll()).map((n) => n.path), ['ok.md']);
      expect(store.skipped.single.reason, contains('larger than'));
    });

    test(
      'symbolic links from a repository are never written through',
      () async {
        final outside = await Directory.systemTemp.createTemp('outside_');
        addTearDown(() => outside.delete(recursive: true));
        File(p.join(outside.path, 'secret.md')).writeAsStringSync('secret');
        // A cloned repository can carry links to anywhere.
        Link(store.absolute('Work')).createSync(outside.path);
        Link(store.absolute('linked.md'))
            .createSync(p.join(outside.path, 'secret.md'));
        await write('note.md', 'mine');
        final notes = await store.loadAll();
        expect(notes.map((n) => n.path), ['note.md']);
        expect(store.folders, isEmpty);

        await expectLater(
          store.create(title: 'x', body: 'y', folder: 'Work'),
          throwsA(isA<NoteStoreException>()),
        );
        await expectLater(
          store.createFolder('Work'),
          throwsA(isA<NoteStoreException>()),
        );
        await expectLater(
          store.move(notes.single, 'Work'),
          throwsA(isA<NoteStoreException>()),
        );
        await expectLater(
          store.restore(notes.single.copyWith(path: 'Work/secret.md')),
          throwsA(isA<NoteStoreException>()),
        );
        expect(outside.listSync().map((e) => p.basename(e.path)), [
          'secret.md',
        ]);
        expect(
          File(p.join(outside.path, 'secret.md')).readAsStringSync(),
          'secret',
        );
      },
      skip: Platform.isWindows ? 'links need privileges on Windows' : false,
    );

    test('unchanged files are not re-parsed; changed ones are', () async {
      await write('a.md', 'one');
      await write('b.md', 'other');
      expect((await store.loadAll()).length, 2);
      expect(store.lastReadCount, 2);
      await store.loadAll();
      expect(store.lastReadCount, 0);

      // A different size is noticed even within the same timestamp tick.
      await write('a.md', 'one two');
      expect((await store.loadAll()).first.body, 'one two');
      expect(store.lastReadCount, 1);

      // Same size, different timestamp.
      final file = File(store.absolute('a.md'));
      await file.writeAsString('two one');
      await file.setLastModified(DateTime(2000));
      expect((await store.loadAll()).first.body, 'two one');
      expect(store.lastReadCount, 1);

      // clearCache forces a re-read even when nothing looks different.
      store.clearCache();
      await store.loadAll();
      expect(store.lastReadCount, 2);
    });

    test('move keeps the file name and removes emptied folders', () async {
      final created = (await store.create(
        title: 'n',
        body: 'x',
        folder: 'a/b',
      )).note!;
      final moved = await store.move(created, 'c');
      expect(moved.note!.path, 'c/n.md');
      expect(Directory(p.join(dir.path, 'a')).existsSync(), isFalse);
      expect(await folders(), ['c']);
    });

    test('createFolder keeps empty folders with .gitkeep', () async {
      final change = await store.createFolder('Projects/Ideas');
      expect(change.paths, ['Projects/Ideas/.gitkeep']);
      expect(await folders(), ['Projects', 'Projects/Ideas']);
    });
  });

  group('settings file and directories', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gitmarker_dirs_');
    });
    tearDown(() => dir.delete(recursive: true));

    test('the settings file and the support directory are private', () async {
      final support = p.join(dir.path, 'support');
      await NoteStore.createPrivateDirectory(support);
      final file = SettingsFile(p.join(support, 'settings.json'));
      await file.save(
        const AppSettings(
          auth: GitAuth(method: AuthMethod.httpsToken, password: 't'),
        ),
      );
      expect(Directory(support).statSync().modeString(), 'rwx------');
      expect(File(file.path).statSync().modeString(), 'rw-------');
    }, skip: Platform.isLinux || Platform.isMacOS ? false : 'POSIX only');

    test(
      'settings round-trip; missing or corrupt files give defaults',
      () async {
        final file = SettingsFile(p.join(dir.path, 'sub', 'settings.json'));
        expect((await file.load()).branch, 'main');
        await file.save(
          const AppSettings(remoteUrl: '/srv/n.git', branch: 'b'),
        );
        final loaded = await file.load();
        expect((loaded.remoteUrl, loaded.branch), ('/srv/n.git', 'b'));
        await File(file.path).writeAsString('{not json');
        expect((await file.load()).remoteUrl, isEmpty);
      },
    );

    test(
      'replaceWith swaps in a directory, with or without a backup',
      () async {
        final root = p.join(dir.path, 'data');
        final store = NoteStore(root);
        expect(await store.hasFiles(), isFalse);
        await File(p.join(root, 'old.md')).create(recursive: true);
        expect(await store.hasFiles(), isTrue);

        final incoming = p.join(dir.path, 'incoming');
        await File(p.join(incoming, 'new.md')).create(recursive: true);
        final backup = await store.replaceWith(
          incoming,
          backupAt: DateTime(2026, 1, 2, 3, 4, 5),
        );
        expect(backup, p.join(dir.path, 'data_backup_20260102-030405'));
        expect(File(p.join(backup!, 'old.md')).existsSync(), isTrue);
        expect(File(p.join(root, 'new.md')).existsSync(), isTrue);
        expect(Directory(incoming).existsSync(), isFalse);

        await File(p.join(incoming, 'newer.md')).create(recursive: true);
        expect(await store.replaceWith(incoming), isNull);
        expect(File(p.join(root, 'newer.md')).existsSync(), isTrue);
        expect(File(p.join(root, 'new.md')).existsSync(), isFalse);

        await NoteStore.deleteDirectory(backup);
        expect(Directory(backup).existsSync(), isFalse);
      },
    );
  });
}
