// Clones a public repository over HTTPS. Skipped by default; run with:
//   flutter test test/network --run-skipped
@Skip('Needs network access; run with --run-skipped')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitmarker/git.dart';
import 'package:gitmarker/note_models.dart';

void main() {
  test('clones a public HTTPS repository and syncs again', () async {
    final dir = await Directory.systemTemp.createTemp('gitmarker_https_');
    addTearDown(() => dir.delete(recursive: true));
    final git = GitBackend();
    final repo = '${dir.path}/repo';
    await git.clone(
      'https://github.com/libgit2/TestGitRepository',
      repo,
      branch: 'master',
    );
    final sync = await git.sync(repo, 'master');
    expect(sync.outcome, SyncOutcome.upToDate);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
