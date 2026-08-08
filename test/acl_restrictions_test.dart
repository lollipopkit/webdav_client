import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:xml/xml.dart';

void main() {
  test('aclRestrictions returns acl-restrictions element', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = 207
        ..headers.contentType = ContentType('application', 'xml')
        ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/file.txt</d:href><d:propstat><d:prop>
    <d:acl-restrictions>
      <d:required-principal><d:all/></d:required-principal>
      <d:no-invert/>
    </d:acl-restrictions>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final restrictions = await client.aclRestrictions(path: '/file.txt');

    expect(restrictions, isNotNull);
    expect(
      restrictions!.findElements('required-principal', namespaceUri: '*'),
      isNotEmpty,
    );
    expect(restrictions.findElements('no-invert', namespaceUri: '*'), isNotEmpty);
  });
}
