import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('rename rejects Depth values other than infinity per RFC 4918 §10.2',
      () {
    final client = WebdavClient.noAuth(url: 'http://example.com');

    expect(
      () => client.rename(
        '/source.txt',
        '/destination.txt',
        depth: PropsDepth.zero,
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(
      () => client.rename(
        '/source.txt',
        '/destination.txt',
        depth: PropsDepth.one,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
