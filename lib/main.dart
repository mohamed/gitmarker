// Flutter entry point.

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'controller.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final controller = AppController(supportDir: support.path);
  runApp(GitMarkerApp(controller: controller));
  await controller.init();
}
