import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyda_bot/src/sdk_version.dart';

// The version is written twice - pubspec.yaml for pub.dev, sdk_version.dart for
// the User-Agent the hosted page reads - and a release that bumps one without
// the other ships a shell that reports the wrong version to the page. This is
// the check that makes that impossible to do quietly.
void main() {
  test('kKeydaSdkVersion is the version in pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? declared =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(declared, isNotNull, reason: 'pubspec.yaml has no version: line');
    expect(kKeydaSdkVersion, declared!.group(1));
  });
}
