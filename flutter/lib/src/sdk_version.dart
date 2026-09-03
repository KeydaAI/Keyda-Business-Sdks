/// The version this package is published as — `version:` in pubspec.yaml.
///
/// Duplicated here because Dart has no `BuildConfig`: nothing at runtime can
/// read the pubspec, and the version has to reach the hosted page in the
/// User-Agent (`KeydaBot/<version> (Flutter)`) so it can tell a shell that
/// answers its file chooser from one that does not. `test/sdk_version_test.dart`
/// fails the moment this and the pubspec disagree, which is the only way two
/// copies of a version stay honest.
const String kKeydaSdkVersion = '0.1.4';
