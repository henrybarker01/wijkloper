/// The server the app connects to unless a parent picks another one
/// (e.g. a Raspberry Pi on the home Wi-Fi via the advanced options).
///
/// Override at build time:
///   flutter build apk --release --dart-define=WIJKLOPER_DEFAULT_SERVER=https://example.org
const String defaultServerUrl = String.fromEnvironment(
  'WIJKLOPER_DEFAULT_SERVER',
  defaultValue: 'https://wijkloper.aeromech.co',
);
