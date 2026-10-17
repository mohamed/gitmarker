// Applies to every test in this folder.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A tap that misses its widget fails the test instead of only logging a
  // warning, so a test cannot pass while tapping something else.
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}
