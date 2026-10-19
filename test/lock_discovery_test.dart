import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('lockDiscovery parses active lock details', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? depth;

    server.listen((request) async {
      depth = request.headers.value('Depth');
      await request.drain();
      request.response
        ..statusCode = 207
        ..headers.contentType = ContentType('application', 'xml')
        ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:lockdiscovery>
          <d:activelock>
            <d:lockscope><d:exclusive/></d:lockscope>
            <d:locktype><d:write/></d:locktype>
            <d:depth>infinity</d:depth>
            <d:owner><d:href>mailto:alice@example.com</d:href></d:owner>
            <d:timeout>Second-3600</d:timeout>
            <d:locktoken><d:href>opaquelocktoken:abc</d:href></d:locktoken>
            <d:lockroot><d:href>/dir%20a/</d:href></d:lockroot>
          </d:activelock>
        </d:lockdiscovery>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final locks = await client.lockDiscovery('/file.txt');

    expect(depth, '0');
    expect(locks, hasLength(1));
    expect(locks.single.token, 'opaquelocktoken:abc');
    expect(locks.single.scope, 'exclusive');
    expect(locks.single.type, 'write');
    expect(locks.single.depth, 'infinity');
    expect(locks.single.owner, 'mailto:alice@example.com');
    expect(locks.single.timeout, 'Second-3600');
    expect(locks.single.lockRoot, '/dir%20a/');
  });
}
