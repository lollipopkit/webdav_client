import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('lock rejects depth one per RFC 4918 §9.10.3', () {
    final client = WebdavClient.noAuth(url: 'http://example.com');

    expect(
      () => client.lock('/resource', depth: PropsDepth.one),
      throwsA(isA<ArgumentError>()),
    );
  });
}
