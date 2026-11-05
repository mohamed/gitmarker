# Contributing to GitMarker

Thanks for helping. GitMarker is a Markdown notes app in the style of Google
Keep that keeps its notes in a Git repository. This guide covers how to set
up, the rules the code follows, and what a pull request needs.

## Setup

GitMarker is built with **Flutter 3.47.7**, the version CI pins. Other
versions may work, but generated platform files and Android SDK levels
follow the Flutter version, so use this one for anything you submit.

`android/` is committed. The other platform folders are generated, once,
after cloning:

```sh
flutter create --empty --org com .   # ios/, linux/, macos/, windows/, web/
dart run flutter_launcher_icons       # app icons from assets/icon/
```

`flutter create` leaves the committed files alone, and `--empty` keeps it
from adding a sample test. The app ID is `com.gitmarker`.

## Before you open a pull request

```sh
dart format lib test
flutter analyze        # no issues
flutter test           # all green
```

CI runs the same checks, the SSH test, and release builds for Android,
iOS, Linux, macOS and Windows. A pull request should pass all of them.

The network tests are skipped by default. Run them when you touch sync or
transports:

```sh
flutter test test/network --run-skipped   # SSH (starts its own sshd: needs sshd, ssh-keygen, git); HTTPS (needs internet)
```

## Architecture

The UI is Flutter; everything below it is plain Dart, with calls only going
downwards:

```
lib/ui.dart ──▶ lib/controller.dart ──▶ lib/note_store.dart   files
                                    └─▶ lib/git.dart          Git
                 all of them use lib/note_models.dart and lib/bidi.dart
```

| File | Owns |
|---|---|
| `lib/main.dart` | Flutter entry point |
| `lib/ui.dart` | The Keep-style UI. It talks only to the controller. |
| `lib/controller.dart` | Workflows across the store and Git (save → commit → reload, sync, history, settings), observable state. No file I/O and no Git rules of its own. |
| `lib/note_store.dart` | All file storage: notes (Markdown with YAML front matter), folders, the settings file, data-directory moves and backups. |
| `lib/git.dart` | GitMarker's Git rules and workflows (remote URLs, branch names, settings validation, credentials, host keys, sync), each written as the git commands it runs. |
| `lib/note_models.dart` | Data models only. |
| `lib/bidi.dart` | Text direction and search normalization. |

Only `main.dart` and `ui.dart` may import Flutter.

Git itself is [dargit](https://github.com/mohamed/dargit), a pure-Dart Git
whose API mirrors git commands. There is no native library and no `git`
executable. Git formats and protocols belong in dargit, not here.

## Conventions

- **Tests mirror `lib/`.** Git behaviour is tested against dargit and real
  local bare repositories, without mocks (`test/git_test.dart`,
  `test/controller_test.dart`). Interop tests check the repositories with
  the `git` CLI and skip themselves where it isn't installed.
- **Widget tests that start file or Git I/O** dispatch the gesture inside
  `tester.runAsync` (see `test/ui_test.dart`); I/O started in the fake-async
  zone never completes.
- **Text direction.** Every widget that shows note content sets its
  `textDirection` from `bidi.dart`, so Arabic and mixed lines lay out
  correctly.
- **Commit messages written by the app** are `Create note: …`,
  `Update note: …`, `Move note: … to …`, `Delete note: …` and
  `Create folder: …`. Keep these stable; users' histories depend on them.
- **Untrusted input.** Repositories the app opens may come from anyone, so
  their files are untrusted: keep the limits in `note_store.dart` (file and
  front matter size, nesting, YAML alias expansion, no writes through
  symbolic links) and in the Markdown view (line and formula length).
- **Credentials** stay out of `.git/config`: URLs with credentials, and
  `http://` remotes, are refused by validation.

## Platform files

- `android/` is committed in full, because F-Droid and Google Play build
  from it. Its `.gitignore` leaves out `local.properties`, the Gradle
  wrapper jar and scripts (Flutter supplies them),
  `GeneratedPluginRegistrant.java` and keystores. Never commit a keystore.
- In the other platform folders only customised files are committed, each
  with a `!` exception in `.gitignore`:
  - `ios/Runner/Info.plist`
  - `macos/Runner/{DebugProfile,Release}.entitlements`
  - and the files that carry the display name "GitMarker":
    `linux/runner/my_application.cc` (also the window icon),
    `macos/Runner/Configs/AppInfo.xcconfig`,
    `macos/Runner/Base.lproj/MainMenu.xib`, `windows/runner/main.cpp`,
    `windows/runner/Runner.rc`

  To customise another platform file, commit it and add an exception.
- `pubspec.lock` is committed, so release builds use the tested dependency
  versions.

## Android signing

Release builds are signed with the upload key from `android/key.properties`:

```properties
storeFile=upload-keystore.jks     # relative to android/app/
storePassword=…
keyAlias=…
keyPassword=…
```

Neither that file nor the keystore is ever committed (`android/.gitignore`).
Without it, `flutter build apk --release` produces an unsigned APK. That is
what F-Droid builds, since F-Droid signs its builds itself, but an unsigned
APK cannot be installed, so use `flutter run` (debug) to try changes on a
phone.

CI signs the APK when the repository has these secrets:

- `ANDROID_KEYSTORE_BASE64`: the keystore, base64-encoded
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Without them it uploads `gitmarker-android-unsigned.apk`, and releases
leave the APK out.

## Icons

The logo is `docs/logo.svg`. After changing it, render the variants and
regenerate the platform icons:

```sh
python3 docs/render_icons.py docs/logo.svg assets/icon   # needs cairosvg and Pillow
dart run flutter_launcher_icons
```

Commit `assets/icon/` and the Android icons under `android/app/src/main/res/`.

## Releases

Releases are made by the maintainer:

1. Bump `version:` in `pubspec.yaml`. The part after `+` is the Android
   versionCode and must increase.
2. Add a `## X.Y.Z` section to `CHANGELOG.md`, and
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` for
   F-Droid.
3. Tag the commit `vX.Y.Z`. `.github/workflows/release.yml` checks the
   tag against `pubspec.yaml` and `CHANGELOG.md`, runs CI and publishes
   the builds as a GitHub release.

## Licence

GitMarker is BSD 3-Clause licensed (`LICENSE`). By contributing, you agree
that your contributions are released under the same licence.
