import 'package:flutter_test/flutter_test.dart';
import 'package:wijkloper/core/api_client.dart';
import 'package:wijkloper/core/defaults.dart';

void main() {
  test('normalizeServerUrl treats bare domains as public HTTPS servers', () {
    expect(normalizeServerUrl('wijkloper.aeromech.co'), 'https://wijkloper.aeromech.co');
    expect(normalizeServerUrl(' https://wijkloper.aeromech.co/api/health '), 'https://wijkloper.aeromech.co');
    expect(normalizeServerUrl('https://example.org:8443/x'), 'https://example.org:8443');
    expect(normalizeServerUrl('http://wijkloper.aeromech.co'), 'http://wijkloper.aeromech.co');
  });

  test('normalizeServerUrl treats LAN hosts as plain http on port 8000', () {
    expect(normalizeServerUrl('192.168.178.240'), 'http://192.168.178.240:8000');
    expect(normalizeServerUrl('192.168.178.240:9000'), 'http://192.168.178.240:9000');
    expect(normalizeServerUrl('pi.local'), 'http://pi.local:8000');
    expect(normalizeServerUrl('localhost'), 'http://localhost:8000');
  });

  test('normalizeServerUrl leaves empty and broken input alone', () {
    expect(normalizeServerUrl(''), '');
    expect(normalizeServerUrl('   '), '');
    expect(normalizeServerUrl('https://'), 'https://');
  });

  test('default server is a valid https URL', () {
    expect(normalizeServerUrl(defaultServerUrl), defaultServerUrl);
    expect(defaultServerUrl, startsWith('https://'));
  });
}
