import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('lock refresh omits Content-Type and Depth headers per RFC 4918 §9.10.2',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    var callCount = 0;
    String? initialContentType;
    String? initialDepth;
    String? refreshContentType;
    String? refreshDepth;
    String? refreshBody;
    String? refreshIfHeader;

    String lockDiscoveryBody(String token) => '''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:lockdiscovery>
    <d:activelock>
      <d:locktype><d:write/></d:locktype>
      <d:lockscope><d:exclusive/></d:lockscope>
      <d:depth>infinity</d:depth>
      <d:locktoken><d:href>$token</d:href></d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>
''';

    server.listen((request) async {
      callCount += 1;
      if (callCount == 1) {
        initialContentType = request.headers.value('content-type');
        initialDepth = request.headers.value('depth');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.add('Lock-Token', '<opaquelocktoken:test-token>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(lockDiscoveryBody('opaquelocktoken:test-token'));
      } else {
        refreshContentType = request.headers.value('content-type');
        refreshDepth = request.headers.value('depth');
        refreshIfHeader = request.headers.value('if');
        refreshBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(lockDiscoveryBody('opaquelocktoken:test-token'));
      }
      await request.response.close();
    });

    final baseUrl =
        'http://${server.address.host}:${server.port}/remote.php/dav/files/alice';
    final client = WebdavClient.noAuth(url: baseUrl);

    final token = await client.lock(
      '/reports/activity',
      owner: 'tester',
    );

    expect(token, equals('opaquelocktoken:test-token'));
    expect(initialContentType, contains('application/xml'));
    expect(initialDepth, equals('infinity'));

    final resourceHref = '$baseUrl/reports/activity';
    final ifHeader = '<$resourceHref> (<opaquelocktoken:test-token>)';
    final refreshedToken = await client.lock(
      '/reports/activity',
      refreshLock: true,
      ifHeader: ifHeader,
    );

    expect(refreshedToken, equals('opaquelocktoken:test-token'));
    expect(refreshContentType, isNull);
    expect(refreshDepth, isNull);
    expect(refreshIfHeader, equals(ifHeader));
    expect(refreshBody, isEmpty);
  });
}
