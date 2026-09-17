import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _output = String.fromEnvironment('AUTH_UI_SNAPSHOT_DIR');
const _font = String.fromEnvironment('AUTH_UI_SNAPSHOT_FONT');
const authSnapshotKey = Key('auth-ui-snapshot');

Future<void> loadAuthSnapshotFonts(WidgetTester tester) async {
  if (_output.isEmpty) return;
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await tester.runAsync(icons.load);
  if (_font.isNotEmpty) {
    final text = FontLoader('AuthSnapshot')
      ..addFont(
        Future.value(ByteData.sublistView(File(_font).readAsBytesSync())),
      );
    await tester.runAsync(text.load);
  }
}

ThemeData authSnapshotTheme(Brightness brightness) => ThemeData(
  colorSchemeSeed: const Color(0xFF544451),
  useMaterial3: true,
  brightness: brightness,
  fontFamily: _output.isNotEmpty && _font.isNotEmpty ? 'AuthSnapshot' : null,
);

Future<void> captureAuthSnapshot(WidgetTester tester, String name) async {
  if (_output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(authSnapshotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
