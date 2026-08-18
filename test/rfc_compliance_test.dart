import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests for RFC compliance improvements:
/// - HEAD method (RFC 4918 §9.4)
/// - MKCOL with request body (RFC 4918 §9.3.1)
void main() {
  group('HEAD method (RFC 4918 §9.4)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('HEAD returns resource metadata without body', () async {
      server.listen((request) async {
        if (request.method == 'HEAD' && request.uri.path == '/file.txt') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..headers.set('ETag', '"abc123"')
            ..headers.set('Content-Length', '1024')
            ..headers.set('Last-Modified', 'Mon, 01 Jan 2024 00:00:00 GMT');
        } else if (request.method == 'HEAD') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final result = await client.head('/file.txt');
      expect(result.statusCode, 200);
      expect(result.headers.value('etag'), '"abc123"');
      expect(result.headers.value('content-length'), '1024');
    });

    test('HEAD forwards caller supplied headers', () async {
      String? ifNoneMatch;

      server.listen((request) async {
        ifNoneMatch = request.headers.value('If-None-Match');
        await request.drain();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final result = await client.head(
        '/file.txt',
        headers: const {'If-None-Match': '"etag"'},
      );

      expect(result.statusCode, 200);
      expect(ifNoneMatch, '"etag"');
    });

    test('HEAD on non-existent resource returns 404', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'HEAD') {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final result = await client.head('/missing');
      expect(result.statusCode, 404);
    });

    test('HEAD on collection returns 200', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'HEAD') {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('httpd', 'unix-directory');
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final result = await client.head('/dir/');
      expect(result.statusCode, 200);
    });
  });

  group('MKCOL with request body (RFC 4918 §9.3.1)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('MKCOL with XML body sets initial properties', () async {
      String? capturedBody;
      String? capturedContentType;

      server.listen((request) async {
        if (request.method == 'MKCOL') {
          capturedBody =
              await request.map(String.fromCharCodes).join();
          capturedContentType = request.headers.contentType?.toString();
          request.response.statusCode = HttpStatus.created;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      const xmlBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:mkcol xmlns:d="DAV:">
  <d:set>
    <d:prop>
      <d:displayname>New Folder</d:displayname>
    </d:prop>
  </d:set>
</d:mkcol>''';

      await client.mkdir('/new-folder/', body: xmlBody);

      expect(capturedBody, contains('mkcol'));
      expect(capturedBody, contains('New Folder'));
      expect(capturedContentType, contains('xml'));
    });

    test('mkdirWithProps builds RFC 4918 extended MKCOL body', () async {
      String? capturedBody;

      server.listen((request) async {
        capturedBody = await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.mkdirWithProps(
        '/with-props/',
        const {
          'displayname': 'With Props',
          'x:color': 'blue',
        },
        namespaces: const {'x': 'http://example.com/ns'},
      );

      expect(capturedBody, contains('<d:mkcol'));
      expect(
          capturedBody, contains('<d:displayname>With Props</d:displayname>'));
      expect(capturedBody, contains('<x:color>blue</x:color>'));
    });

    test('MKCOL with body returns 201 on success', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(
        client.mkdir('/test/',
            body:
                '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:"><d:set><d:prop><d:displayname>Test</d:displayname></d:prop></d:set></d:mkcol>'),
        completes,
      );
    });

    test('MKCOL without body works as before', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.mkdir('/no-body/'), completes);
    });
  });
}
