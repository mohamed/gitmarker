// SSH transport against a throwaway sshd on localhost, started by the test.
// Needs sshd, ssh-keygen and git (the server side runs git-upload-pack).
// Skipped by default; run with:
//   flutter test test/network/ssh_test.dart --run-skipped
@Skip('Starts a local sshd; run with --run-skipped')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitmarker/git.dart';
import 'package:gitmarker/note_models.dart';

const String _passphrase = 'secret phrase';

void main() {
  late Directory work;
  late Process sshd;
  late String url;

  setUpAll(() async {
    work = await Directory.systemTemp.createTemp('gitmarker_ssh_');
    final dir = work.path;
    Future<void> run(String command, List<String> args) async {
      final result = await Process.run(command, args);
      if (result.exitCode != 0) {
        throw StateError('$command ${args.join(' ')}: ${result.stderr}');
      }
    }

    await run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '$dir/host_key',
    ]);
    await run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '$dir/user_plain',
    ]);
    await run('ssh-keygen', [
      '-q', '-t', 'rsa', '-b', '3072', '-N', _passphrase, '-f', //
      '$dir/user_encrypted',
    ]);
    // No .pub next to the encrypted key: GitMarker must derive it.
    final encryptedPub = File('$dir/user_encrypted.pub');
    final authorized = File('$dir/authorized_keys')
      ..writeAsStringSync(
        File('$dir/user_plain.pub').readAsStringSync() +
            encryptedPub.readAsStringSync(),
      );
    encryptedPub.deleteSync();
    await run('chmod', ['600', authorized.path]);

    // A free port: bind to port 0, note it, release it.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    File('$dir/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
AuthorizedKeysFile $dir/authorized_keys
PidFile $dir/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
StrictModes no
UsePAM no
''');
    // sshd must be started by its absolute path.
    final which = await Process.run('sh', [
      '-c',
      'command -v sshd || ls /usr/sbin/sshd',
    ]);
    final sshdPath = (which.stdout as String).trim().split('\n').first;
    sshd = await Process.start(sshdPath, [
      '-D', '-e', '-f', '$dir/sshd_config', //
    ]);
    final log = StringBuffer();
    sshd.stderr.transform(utf8.decoder).listen(log.write);
    for (var i = 0; ; i++) {
      try {
        (await Socket.connect('127.0.0.1', port)).destroy();
        break;
      } on SocketException {
        if (i == 50) throw StateError('sshd did not start:\n$log');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await run('git', ['init', '-q', '--bare', '-b', 'main', '$dir/remote.git']);
    final user = (await Process.run('id', ['-un'])).stdout.toString().trim();
    url = 'ssh://$user@127.0.0.1:$port$dir/remote.git';
  });

  tearDownAll(() async {
    sshd.kill();
    await sshd.exitCode;
    await work.delete(recursive: true);
  });

  test('key auth, encrypted key, and trust on first use', () async {
    final dir = work.path;
    final hosts = '$dir/known_hosts.json';
    final plain = GitBackend(
      auth: GitAuth(method: AuthMethod.sshKey, sshKeyPath: '$dir/user_plain'),
      knownHostsPath: hosts,
    );

    // Unknown host: accepted and recorded on first use.
    await plain.clone(url, '$dir/a', branch: 'main');
    final recorded = jsonDecode(File(hosts).readAsStringSync()) as Map;
    expect(recorded, hasLength(1));
    await File('$dir/a/n.md').writeAsString('over ssh');
    await plain.commit('$dir/a', 'ssh commit');
    final pushed = await plain.sync('$dir/a', 'main');
    expect(pushed.outcome, SyncOutcome.pushed);

    // Encrypted RSA key without a .pub file next to it.
    final encrypted = GitBackend(
      auth: GitAuth(
        method: AuthMethod.sshKey,
        sshKeyPath: '$dir/user_encrypted',
        sshPassphrase: _passphrase,
      ),
      knownHostsPath: hosts,
    );
    await encrypted.clone(url, '$dir/b', branch: 'main');
    expect(File('$dir/b/n.md').readAsStringSync(), 'over ssh');

    // Wrong passphrase fails cleanly instead of looping.
    final wrong = GitBackend(
      auth: GitAuth(
        method: AuthMethod.sshKey,
        sshKeyPath: '$dir/user_encrypted',
        sshPassphrase: 'nope',
      ),
      knownHostsPath: hosts,
    );
    await expectLater(
      wrong.sync('$dir/b', 'main'),
      throwsA(isA<GitException>()),
    );

    // A changed host key is refused.
    final host = recorded.keys.single as String;
    File(hosts).writeAsStringSync(jsonEncode({host: 'AAAA'}));
    await expectLater(
      plain.sync('$dir/a', 'main'),
      throwsA(isA<GitException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
