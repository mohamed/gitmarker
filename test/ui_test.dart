import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dargit/dargit.dart' show Git;
import 'package:gitmarker/controller.dart';
import 'package:gitmarker/note_models.dart';
import 'package:gitmarker/ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  late AppController controller;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('gitmarker_ui_');
    controller = AppController(supportDir: support.path);
  });

  tearDown(() => support.delete(recursive: true));

  /// Taps [finder] in the real-async zone, so the file and Git I/O the tap
  /// starts can complete (I/O started in the fake-async zone never does),
  /// then pumps until [done] holds.
  Future<void> tapAndWait(
    WidgetTester tester,
    Finder finder,
    bool Function() done,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(done(), isTrue, reason: 'lastError: ${controller.lastError}');
  }

  testWidgets('checklist items can be ticked on the card and in the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GitMarkerApp(controller: controller));
    await tester.runAsync(() async {
      await controller.init();
      await controller.createNote(
        title: 'Shopping',
        body: '- [ ] milk\n- [x] eggs',
      );
    });
    await tester.pumpAndSettle();
    String body() => controller.notes.single.body;

    // Each item reads as a checkbox with its state, text and tap action,
    // and has a full-size touch target.
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('milk')),
      isSemantics(
        label: 'milk',
        hasCheckedState: true,
        isChecked: false,
        hasTapAction: true,
        isFocusable: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('eggs')),
      isSemantics(hasCheckedState: true, isChecked: true),
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();

    await tapAndWait(
      tester,
      find.byType(Checkbox).first, // milk
      () => body() == '- [x] milk\n- [x] eggs',
    );
    expect(find.byType(NoteEditorPage), findsNothing, reason: 'card stayed');

    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).last); // eggs, in the editor
    // The view's double-tap-to-edit gesture holds a single tap until the
    // double-tap timeout passes.
    await tester.pump(const Duration(milliseconds: 500));
    await tapAndWait(
      tester,
      find.byType(BackButton),
      () => body() == '- [x] milk\n- [ ] eggs',
    );
  });

  testWidgets('create an Arabic note, see it in the grid, open its history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GitMarkerApp(controller: controller));
    await tester.runAsync(controller.init);
    await tester.pumpAndSettle();
    expect(find.text('Notes you add appear here'), findsOneWidget);

    await tester.tap(find.byTooltip('Take a note'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'ملاحظة');
    await tester.enterText(fields.at(1), 'Hello body');
    await tester.pump();
    final title = tester.widget<TextField>(fields.at(0));
    final body = tester.widget<TextField>(fields.at(1));
    expect(title.textDirection, TextDirection.rtl);
    expect(body.textDirection, TextDirection.ltr);

    await tapAndWait(
      tester,
      find.byType(BackButton),
      () => find.byType(NoteCard).evaluate().isNotEmpty,
    );
    expect(controller.notes.single.title, 'ملاحظة');
    final cardTitle = tester.widget<Text>(
      find.descendant(of: find.byType(NoteCard), matching: find.text('ملاحظة')),
    );
    expect(cardTitle.textDirection, TextDirection.rtl);

    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    await tapAndWait(
      tester,
      find.byTooltip('History'),
      () => find.text('Go to latest').evaluate().isNotEmpty,
    );
    expect(find.text('Create note: ملاحظة'), findsOneWidget);
    expect(find.text('Go to latest'), findsOneWidget);
  });

  testWidgets('conflict dialog offers the three resolutions', (tester) async {
    ConflictResolution? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showDialog<ConflictResolution>(
                context: context,
                builder: (_) => const ConflictDialog(
                  result: SyncResult(
                    SyncOutcome.conflict,
                    conflictedFiles: ['a.md'],
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Keep remote'), findsOneWidget);
    expect(find.text('Force push'), findsOneWidget);
    expect(find.text('Abort'), findsOneWidget);
    await tester.tap(find.text('Force push'));
    await tester.pumpAndSettle();
    expect(picked, ConflictResolution.forcePushLocal);
  });

  testWidgets('code renders as code: fences, indented blocks, inline', (
    tester,
  ) async {
    const text =
        'Run `flutter test` now.\n'
        '```dart\n'
        'void main() {\n'
        '  print("a long line that must scroll instead of wrapping");\n'
        '}\n'
        '```\n'
        '\n'
        '    git status\n'
        '\n'
        '~~~\n'
        '# not a heading\n'
        '~~~\n'
        '- item\n'
        '    - nested item stays a list\n'
        '```\n'
        'unclosed';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkdownView(text: text)),
      ),
    );
    // Code blocks: fence lines dropped, content kept verbatim, one widget
    // per block, scrolling sideways without wrapping.
    for (final block in [
      'void main() {\n'
          '  print("a long line that must scroll instead of wrapping");\n'
          '}',
      'git status',
      '# not a heading',
      'unclosed',
    ]) {
      final widget = tester.widget<Text>(find.text(block));
      expect(widget.softWrap, isFalse);
      expect(widget.style!.fontFamilyFallback, contains('monospace'));
      expect(
        find.ancestor(
          of: find.text(block),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
    }
    expect(find.textContaining('```'), findsNothing);
    expect(find.textContaining('~~~'), findsNothing);
    // Inline code: backticks removed, the code in monospace.
    final inline = tester.widget<Text>(find.text('Run flutter test now.'));
    final code = (inline.textSpan! as TextSpan).children![1] as TextSpan;
    expect(code.text, 'flutter test');
    expect(code.style!.fontFamilyFallback, contains('monospace'));
    // Four-space indentation under a list item is nesting, not code.
    expect(find.text('nested item stays a list'), findsOneWidget);
  });

  testWidgets('bold, italic, links and math', (tester) async {
    const text =
        r'**bold** *italic* ***both*** snake_case_name \*plain\*'
        '\n'
        r'[GitMarker](https://gitmarker.com) and <https://pub.dev>'
        '\n'
        r'Euler $e^{i\pi}+1=0$, it costs $5 or $10'
        '\n'
        '\$\$\\frac{a}{b}\$\$\n'
        '```math\n'
        '\\sum_n n\n'
        '```\n'
        r'Broken $\frac{1}{$';
    Future<List<TextSpan>> leaves({required bool compact}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownView(text: text, compact: compact),
          ),
        ),
      );
      final out = <TextSpan>[];
      for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
        widget.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) out.add(span);
          return true;
        });
      }
      return out;
    }

    final spans = await leaves(compact: false);
    TextSpan span(String text) => spans.firstWhere((s) => s.text == text);
    expect(span('bold').style!.fontWeight, FontWeight.bold);
    expect(span('italic').style!.fontStyle, FontStyle.italic);
    expect(span('both').style!.fontWeight, FontWeight.bold);
    expect(span('both').style!.fontStyle, FontStyle.italic);
    // Underscores inside words and escaped stars stay text.
    expect(find.textContaining('snake_case_name *plain*'), findsOneWidget);
    // Links are underlined and tappable; the URL is the text of <url>.
    expect(span('GitMarker').recognizer, isA<TapGestureRecognizer>());
    expect(span('GitMarker').style!.decoration, TextDecoration.underline);
    expect(span('https://pub.dev').recognizer, isA<TapGestureRecognizer>());
    // Inline, $$ and ```math formulas; dollar amounts stay text.
    expect(find.byType(Math), findsNWidgets(4));
    expect(find.textContaining(r'costs $5 or $10'), findsOneWidget);
    // TeX that does not parse is shown as written.
    expect(find.text(r'$\frac{1}{$'), findsOneWidget);

    // On cards a tap opens the note, so links are not tappable there.
    final card = await leaves(compact: true);
    expect(card.firstWhere((s) => s.text == 'GitMarker').recognizer, isNull);
  });

  testWidgets('very long lines and formulas are shown as text', (tester) async {
    // Inline markup on this line would take minutes to match.
    final hostile = '[a' * 25000;
    final tex = '\$${'x+' * 600}x\$';
    final watch = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(text: '$hostile\n$tex'),
          ),
        ),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(find.text(hostile), findsOneWidget);
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining('x+x+'), findsOneWidget);
  });

  group('M7 behaviour', () {
    Future<void> start(WidgetTester tester, {Widget? home}) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(controller.init);
      await tester.pumpWidget(
        home == null
            ? GitMarkerApp(controller: controller)
            : MaterialApp(home: home),
      );
      await tester.pumpAndSettle();
    }

    Future<void> chooseAuth(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('auth-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    testWidgets('settings show only the selected auth method fields', (
      tester,
    ) async {
      await start(tester, home: SettingsPage(controller: controller));
      expect(find.text('Access token'), findsNothing);
      expect(find.text('Private key path'), findsNothing);

      await chooseAuth(tester, 'HTTPS access token');
      expect(find.text('Access token'), findsOneWidget);
      expect(find.text('Private key path'), findsNothing);
      // The user name is pre-filled with the default.
      expect(find.widgetWithText(TextField, defaultHttpsUser), findsOneWidget);

      await chooseAuth(tester, 'SSH key file');
      expect(find.text('Access token'), findsNothing);
      expect(find.text('Private key path'), findsOneWidget);
      expect(find.text('Key passphrase'), findsOneWidget);

      await chooseAuth(tester, 'SSH agent');
      expect(find.text('Private key path'), findsNothing);
    });

    testWidgets('invalid settings are listed and the page stays open', (
      tester,
    ) async {
      await start(tester, home: SettingsPage(controller: controller));
      await tester.enterText(
        find.widgetWithText(TextField, 'Remote URL'),
        'git@github.com:me/notes.git',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Branch'), 'a..b');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text("'a..b' is not a valid branch name."), findsOneWidget);
      expect(
        find.text('SSH remotes need SSH key or SSH agent authentication.'),
        findsOneWidget,
      );
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(controller.settings.remoteUrl, isEmpty);
    });

    testWidgets('replacing a remote asks first and warns about unpushed work', (
      tester,
    ) async {
      final first = p.join(support.path, 'first.git');
      final second = p.join(support.path, 'second.git');
      await tester.runAsync(() async {
        for (final path in [first, second]) {
          await Git().init(path, initialBranch: 'main', bare: true);
        }
        await File(p.join(support.path, AppController.settingsFileName))
            .writeAsString('{"remoteUrl": "$first"}');
      });
      await start(tester, home: SettingsPage(controller: controller));
      await tester.runAsync(
        () => controller.createNote(title: 'Unpushed', body: ''),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Remote URL'),
        second,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.text('Replace repository?').evaluate().isNotEmpty) break;
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Replace repository?'), findsOneWidget);
      expect(
        find.textContaining('1 local commit(s) have not been pushed'),
        findsOneWidget,
      );
      expect(
        find.text('Keep a backup of the current notes folder'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.settings.remoteUrl, first);
      expect(controller.notes.single.title, 'Unpushed');
    });

    testWidgets('a failed save keeps the editor open with the text', (
      tester,
    ) async {
      await start(tester);
      // Break the repository so the commit fails.
      await tester.runAsync(
        () =>
            Directory(p.join(controller.dataDir, '.git'))
                .delete(recursive: true),
      );
      await tester.tap(find.byTooltip('Take a note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Precious words');
      await tapAndWait(
        tester,
        find.byType(BackButton),
        () => find.textContaining('Not saved').evaluate().isNotEmpty,
      );
      expect(find.byType(NoteEditorPage), findsOneWidget);
      expect(find.text('Precious words'), findsOneWidget);
      // The error is shown once, in the editor, not also as a snackbar.
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditorPage), findsNothing);
    });

    testWidgets('deleting a note offers Undo', (tester) async {
      await start(tester);
      await tester.runAsync(
        () => controller.createNote(title: 'Precious', body: 'text'),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(NoteCard));
      await tester.pumpAndSettle();
      await tapAndWait(
        tester,
        find.text('Delete'),
        () =>
            controller.notes.isEmpty &&
            find.text('Note deleted').evaluate().isNotEmpty,
      );
      expect(find.text('Note deleted'), findsOneWidget);
      await tapAndWait(
        tester,
        find.text('Undo'),
        () => controller.notes.isNotEmpty,
      );
      expect(find.text('Precious'), findsOneWidget);
      // The snackbar was shown from the real-async zone; let its closing
      // animation finish there while the widgets still exist.
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    });

    testWidgets('notes edited elsewhere show up when the app resumes', (
      tester,
    ) async {
      await start(tester);
      expect(find.byType(NoteCard), findsNothing);
      await tester.runAsync(() async {
        await File(p.join(controller.dataDir, 'outside.md'))
            .writeAsString('# From outside\n');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        for (var i = 0; i < 100 && controller.notes.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('From outside'), findsOneWidget);
    });

    testWidgets('the grid builds only the cards on screen', (tester) async {
      await tester.runAsync(() async {
        final data = Directory(controller.dataDir)..createSync(recursive: true);
        for (var i = 0; i < 2000; i++) {
          File(p.join(data.path, 'n${i.toString().padLeft(4, '0')}.md'))
              .writeAsStringSync('---\ntitle: Note $i\n---\n\nbody $i\n');
        }
      });
      await start(tester);
      expect(controller.notes.length, 2000);
      final built = find.byType(NoteCard).evaluate().length;
      expect(built, lessThan(200), reason: '$built cards built');
      // Scrolling reaches the end of the list.
      await tester.scrollUntilVisible(
        find.text('Note 1999'),
        2000,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 200,
      );
      expect(find.text('Note 1999'), findsOneWidget);
    });

    testWidgets('skipped files are reported in a dismissible banner', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final data = Directory(controller.dataDir)..createSync(recursive: true);
        File(p.join(data.path, 'ok.md')).writeAsStringSync('fine');
        File(p.join(data.path, 'bad.md'))
            .writeAsStringSync('---\ntitle: [\n---\n');
      });
      await start(tester);
      expect(find.textContaining('bad.md was skipped'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.textContaining('was skipped'), findsNothing);
    });

    /// The colour menu entry labelled [label] (its text alone does not take
    /// pointer events).
    Finder menuItem(String label) =>
        find.widgetWithText(CheckedPopupMenuItem<Object>, label);

    testWidgets('the colour filter narrows the grid; About opens', (
      tester,
    ) async {
      await start(tester);
      await tester.runAsync(() async {
        await controller.createNote(
          title: 'Sunny',
          body: '',
          color: NoteColor.yellow,
        );
        await controller.createNote(title: 'Plain', body: '');
      });
      await tester.pumpAndSettle();
      expect(find.byType(NoteCard), findsNWidgets(2));

      await tester.tap(find.byTooltip('Filter by colour'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Yellow'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteCard), findsOneWidget);
      expect(find.text('Sunny'), findsOneWidget);

      await tester.tap(find.byTooltip('Showing yellow notes'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Any colour'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteCard), findsNWidgets(2));

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      Iterable<double?> logoSizes() => tester
          .widgetList<Image>(
            find.byWidgetPredicate(
              (w) => w is Image && w.semanticLabel == 'GitMarker logo',
            ),
          )
          .map((i) => i.width);
      expect(logoSizes(), [36.0]); // next to the name in the drawer
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.textContaining('BSD 3-Clause'), findsOneWidget);
      expect(logoSizes(), [112.0]); // heading the About window
      await tester.tap(find.text('Licences'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
