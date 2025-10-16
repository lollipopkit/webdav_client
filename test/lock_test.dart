import 'dart:io';

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

  test('lock uses Lock-Token response header when XML omits token', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'LOCK') {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.add('Lock-Token', '<opaquelocktoken:header-only>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(
              '<?xml version="1.0" encoding="utf-8"?><d:prop xmlns:d="DAV:"/>');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final token = await client.lock('/resource.txt');
    expect(token, equals('opaquelocktoken:header-only'));
  });

  test('lock falls back to body when Lock-Token header is absent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    const xmlResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:lockdiscovery>
    <d:activelock>
      <d:locktype><d:write/></d:locktype>
      <d:lockscope><d:exclusive/></d:lockscope>
      <d:locktoken><d:href>opaquelocktoken:body-only</d:href></d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>
''';

    server.listen((request) async {
      if (request.method == 'LOCK') {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(xmlResponse);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final token = await client.lock('/resource.txt');
    expect(token, equals('opaquelocktoken:body-only'));
  });
}
