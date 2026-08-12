import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:xml/xml.dart';

void main() {
  group('SabreDAV-style propFind helpers', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
        'propFind returns only successful properties for the requested resource',
        () async {
      String? method;
      String? depth;
      String body = '';

      server.listen((request) async {
        method = request.method;
        depth = request.headers.value('Depth');
        body = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"abc"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop><d:displayname /></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final props = await client.propFind(
        '/file.txt',
        properties: const ['getetag', 'displayname'],
      );

      expect(method, 'PROPFIND');
      expect(depth, '0');
      expect(body, contains('<d:getetag/>'));
      expect(props.keys, contains('{DAV:}getetag'));
      expect(props.keys, isNot(contains('{DAV:}displayname')));
      expect(props['{DAV:}getetag']!.innerText, '"abc"');
    });

    test('propFind matches absolute response hrefs among multiple responses',
        () async {
      server.listen((request) async {
        await request.drain();
        final origin = 'http://${server.address.host}:${server.port}';
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>$origin/other.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"other"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>$origin/file.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"target"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final props = await client.propFind('/file.txt');

      expect(props['{DAV:}getetag']!.innerText, '"target"');
    });

    test('propFind matches percent encoded target among multiple responses',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/a%20b/child.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"child"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/a%20b/</d:href>
    <d:propstat>
      <d:prop><d:displayname>A B</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final props = await client.propFind(
        '/a%20b/',
        depth: PropsDepth.one,
      );

      expect(props.keys, contains('{DAV:}displayname'));
      expect(props.keys, isNot(contains('{DAV:}getetag')));
      expect(props['{DAV:}displayname']!.innerText, 'A B');
    });

    test('propFindNames sends propname and returns successful property names',
        () async {
      String body = '';

      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag/><d:displayname/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final names = await client.propFindNames('/file.txt');

      expect(body, contains('<d:propname/>'));
      expect(names, contains('{DAV:}getetag'));
      expect(names, contains('{DAV:}displayname'));
    });

    test('propFindDepth returns successful properties for each href', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop><d:displayname>root</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"etag"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final result = await client.propFindDepth('/');

      expect(result.keys, contains('/'));
      expect(result.keys, contains('/file.txt'));
      expect(result['/file.txt']!['{DAV:}getetag']!.innerText, '"etag"');
    });

    test('propFindAll sends allprop with include list', () async {
      String body = '';

      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:getetag>"abc"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final props = await client.propFindAll('/file.txt', include: const [
        'getetag',
      ]);

      // RFC 4918: `include` must be nested inside `allprop`.
      expect(body, contains('<d:allprop><d:include>'));
      expect(body, contains('<d:getetag/></d:include></d:allprop>'));
      expect(props.keys, contains('{DAV:}getetag'));
    });
  });
}
