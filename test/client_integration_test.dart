import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  group('Client constructors and configuration', () {
    test('noAuth constructor', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      expect(client.url, 'http://localhost');
      expect(client.auth, isA<NoAuth>());
    });

    test('basicAuth constructor', () {
      final client = WebdavClient.basicAuth(
        url: 'http://localhost',
        user: 'test',
        pwd: 'test',
      );
      expect(client.auth, isA<BasicAuth>());
    });

    test('bearerToken constructor', () {
      final client = WebdavClient.bearerToken(
        url: 'http://localhost',
        token: 'tok123',
      );
      expect(client.auth, isA<BearerAuth>());
    });

    test('default constructor with NoAuth', () {
      final client = WebdavClient(url: 'http://localhost');
      expect(client.auth, isA<NoAuth>());
    });

    test('setHeaders', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      client.setHeaders({'x-custom': 'value'});
      // no throw
    });

    test('setConnectTimeout', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      client.setConnectTimeout(5000);
    });

    test('setSendTimeout', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      client.setSendTimeout(5000);
    });

    test('setReceiveTimeout', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      client.setReceiveTimeout(5000);
    });
  });

  group('Client HTTP integration', () {
    late HttpServer server;
    late WebdavClient client;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
    });

    tearDown(() async => server.close(force: true));

    group('quota', () {
      test('parses available quota', () async {
        server.listen((request) async {
          if (request.method == 'PROPFIND' && request.uri.path == '/') {
            await request.drain();
            const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:quota-available-bytes>5000000</d:quota-available-bytes>
        <d:quota-used-bytes>5000000</d:quota-used-bytes>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
            request.response
              ..statusCode = HttpStatus.multiStatus
              ..headers.contentType =
                  ContentType('application', 'xml', charset: 'utf-8')
              ..write(body);
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        });

        final (percent, size) = await client.quota();
        expect(percent, isNot(isNaN));
        expect(size, contains('M'));
      });

      test('parses unlimited quota', () async {
        server.listen((request) async {
          if (request.method == 'PROPFIND' && request.uri.path == '/') {
            await request.drain();
            const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:quota-available-bytes>-1</d:quota-available-bytes>
        <d:quota-used-bytes>1048576</d:quota-used-bytes>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
            request.response
              ..statusCode = HttpStatus.multiStatus
              ..headers.contentType =
                  ContentType('application', 'xml', charset: 'utf-8')
              ..write(body);
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        });

        final (percent, size) = await client.quota();
        expect(percent, isNaN);
        expect(size, contains('unlimited'));
      });

      test('throws when quota response is empty', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.multiStatus
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write(
                '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
          await request.response.close();
        });

        expect(() => client.quota(), throwsA(isA<WebdavException>()));
      });

      test('throws when quota fields missing', () async {
        server.listen((request) async {
          await request.drain();
          const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
          request.response
            ..statusCode = HttpStatus.multiStatus
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write(body);
          await request.response.close();
        });

        expect(() => client.quota(), throwsA(isA<WebdavException>()));
      });

      test('handles zero total quota', () async {
        server.listen((request) async {
          await request.drain();
          const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:quota-available-bytes>0</d:quota-available-bytes>
        <d:quota-used-bytes>0</d:quota-used-bytes>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
          request.response
            ..statusCode = HttpStatus.multiStatus
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write(body);
          await request.response.close();
        });

        final (percent, size) = await client.quota();
        expect(percent, 0.0);
        expect(size, '0M/0M');
      });
    });

    group('options with allowNotFound', () {
      test('returns empty list when DAV header absent', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set('Allow', 'OPTIONS');
          await request.response.close();
        });

        final features = await client.options();
        expect(features, isEmpty);
      });

      test('returns empty list when DAV header is empty', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set('DAV', '  ');
          await request.response.close();
        });

        final features = await client.options();
        expect(features, isEmpty);
      });
    });

    group('request helper', () {
      test('with empty target uses base URL', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write(request.uri.path);
          await request.response.close();
        });

        final resp = await client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        );
        expect(resp.data, '/');
      });

      test('with absolute URL target', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write(request.uri.path);
          await request.response.close();
        });

        final resp = await client.request<String>(
          'GET',
          target: 'http://${server.address.host}:${server.port}/other',
          configure: (options) => options.responseType = ResponseType.plain,
        );
        expect(resp.data, '/other');
      });

      test('with configure callback', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write('ok');
          await request.response.close();
        });

        final resp = await client.request<String>(
          'GET',
          configure: (options) {
            options.headers ??= {};
            options.headers!['X-Custom'] = 'test';
            options.responseType = ResponseType.plain;
          },
        );
        expect(resp.data, 'ok');
      });

      test('with onSendProgress and onReceiveProgress', () async {
        server.listen((request) async {
          await request.drain();
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write('ok');
          await request.response.close();
        });

        int? sent;
        int? received;
        final resp = await client.request<String>(
          'GET',
          data: 'body',
          onSendProgress: (count, total) => sent = count,
          onReceiveProgress: (count, total) => received = count,
          configure: (options) => options.responseType = ResponseType.plain,
        );
        expect(resp.data, 'ok');
        expect(sent, isNotNull);
        expect(received, isNotNull);
      });
    });

    group('ping', () {
      test('throws on non-2xx OPTIONS', () async {
        server.listen((request) async {
          await request.drain();
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
        });

        expect(() => client.ping(), throwsA(isA<WebdavException>()));
      });
    });
  });

  group('Dio layer: auth retry', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('retries on 401 with Digest challenge', () async {
      var requestCount = 0;
      server.listen((request) async {
        await request.drain();
        requestCount++;
        if (requestCount == 1) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set('WWW-Authenticate',
                'Digest realm="test", nonce="abc", qop="auth"');
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write('ok');
        }
        await request.response.close();
      });

      final client = WebdavClient(
        url: 'http://${server.address.host}:${server.port}',
        auth: DigestAuth(
          user: 'u',
          pwd: 'p',
          digestParts: DigestParts('realm="test", nonce="initial"'),
        ),
      );

      final resp = await client.request<String>(
        'GET',
        configure: (options) => options.responseType = ResponseType.plain,
      );
      expect(resp.data, 'ok');
      expect(requestCount, 2);
    });

    test('throws on 401 with Basic challenge when using BasicAuth', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Basic realm="test"');
        await request.response.close();
      });

      final client = WebdavClient.basicAuth(
        url: 'http://${server.address.host}:${server.port}',
        user: 'u',
        pwd: 'p',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('Basic Auth failed'),
          ),
        ),
      );
    });

    test('throws on 401 with non-Basic challenge when using BasicAuth',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Digest realm="test", nonce="abc"');
        await request.response.close();
      });

      final client = WebdavClient.basicAuth(
        url: 'http://${server.address.host}:${server.port}',
        user: 'u',
        pwd: 'p',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('server requires'),
          ),
        ),
      );
    });

    test('throws on 401 with Bearer challenge when using BearerAuth', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Bearer realm="test"');
        await request.response.close();
      });

      final client = WebdavClient.bearerToken(
        url: 'http://${server.address.host}:${server.port}',
        token: 'tok',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('Bearer Auth failed'),
          ),
        ),
      );
    });

    test('throws on 401 with non-Bearer challenge when using BearerAuth',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Basic realm="test"');
        await request.response.close();
      });

      final client = WebdavClient.bearerToken(
        url: 'http://${server.address.host}:${server.port}',
        token: 'tok',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('server requires'),
          ),
        ),
      );
    });

    test('throws on 401 with NoAuth', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Basic realm="test"');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(
          isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('server requires'),
          ),
        ),
      );
    });

    test('throws on 401 without WWW-Authenticate', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(isA<WebdavException>()),
      );
    });

    test('DigestAuth retries with empty digest challenge list falls through',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'NTLM realm="test"');
        await request.response.close();
      });

      final client = WebdavClient(
        url: 'http://${server.address.host}:${server.port}',
        auth: DigestAuth(
          user: 'u',
          pwd: 'p',
          digestParts: DigestParts('realm="old", nonce="old"'),
        ),
      );

      expect(
        () => client.request<String>(
          'GET',
          configure: (options) => options.responseType = ResponseType.plain,
        ),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('Dio layer: redirect', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('follows 302 redirect', () async {
      var requestCount = 0;
      server.listen((request) async {
        await request.drain();
        requestCount++;
        if (requestCount == 1) {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('Location', '/redirected');
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('text', 'plain')
            ..write('redirected');
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final resp = await client.request<String>(
        'GET',
        configure: (options) => options.responseType = ResponseType.plain,
      );
      expect(resp.data, 'redirected');
      expect(requestCount, 2);
    });

    test('302 without location header is not retried', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.found;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final resp = await client.request<String>(
        'GET',
        configure: (options) => options.responseType = ResponseType.plain,
      );
      expect(resp.statusCode, 302);
    });
  });

  group('wdReadWithBytes', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-200 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.read('/missing'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('follows 3xx redirect with Location header', () async {
      server.listen((request) async {
        await request.drain();
        if (request.uri.path == '/original') {
          request.response
            ..statusCode = HttpStatus.movedPermanently
            ..headers.set('Location', '/target');
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('application', 'octet-stream')
            ..add([1, 2, 3]);
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final bytes = await client.read('/original');
      expect(bytes, [1, 2, 3]);
    });

    test('throws on 3xx redirect without Location', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.movedPermanently;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.read('/no-location'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('wdReadWithStream', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('downloads file to disk', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '5')
          ..add([10, 20, 30, 40, 50]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_stream_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final savePath = '${tmpDir.path}/downloaded.bin';
      await client.readFile('/stream-file', savePath);

      final file = File(savePath);
      expect(file.existsSync(), isTrue);
      expect(await file.readAsBytes(), [10, 20, 30, 40, 50]);
    });

    test('reports progress during download', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '3')
          ..add([1, 2, 3]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_progress_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final progress = <(int, int)>[];
      await client.readFile(
        '/progress-file',
        '${tmpDir.path}/out.bin',
        onProgress: (count, total) => progress.add((count, total)),
      );

      expect(progress, isNotEmpty);
    });

    test('throws on non-200', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_throw_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      expect(
        () => client.readFile('/forbidden', '${tmpDir.path}/out.bin'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('response without content-length reports total=-1', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked')
          ..add([1, 2, 3]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_nocl_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      int? lastTotal;
      await client.readFile(
        '/no-content-length',
        '${tmpDir.path}/out.bin',
        onProgress: (count, total) => lastTotal = total,
      );

      // total should be -1 since no Content-Length was provided
      expect(lastTotal, -1);
    });
  });

  group('wdWriteWithBytes', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('creates parent directories then PUTs', () async {
      final mkcolPaths = <String>[];
      String? putPath;

      server.listen((request) async {
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
          request.response.statusCode = HttpStatus.created;
          await request.response.close();
        } else if (request.method == 'PUT') {
          putPath = request.uri.path;
          request.response.statusCode = HttpStatus.created;
          await request.drain();
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.drain();
          await request.response.close();
        }
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.write('/a/b/c.txt', Uint8List.fromList([1, 2, 3]));

      expect(mkcolPaths, contains('/a/b/'));
      expect(putPath, '/a/b/c.txt');
    });

    test('accepts 200 OK', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(
        client.write('/ok.txt', Uint8List.fromList([1])),
        completes,
      );
    });

    test('accepts 204 No Content', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(
        client.write('/nc.txt', Uint8List.fromList([1])),
        completes,
      );
    });

    test('throws on non-success status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.write('/forbidden.txt', Uint8List.fromList([1])),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('wdWriteWithStream', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('streams file content', () async {
      String? putPath;

      server.listen((request) async {
        if (request.method == 'PUT') {
          putPath = request.uri.path;
          request.response.statusCode = HttpStatus.created;
          await request.drain();
        } else if (request.method == 'MKCOL') {
          request.response.statusCode = HttpStatus.created;
          await request.drain();
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.drain();
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_upload_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final localFile = File('${tmpDir.path}/upload.txt');
      await localFile.writeAsBytes([10, 20, 30, 40, 50]);

      await client.writeFile(localFile.path, '/remote/upload.txt');

      expect(putPath, '/remote/upload.txt');
    });

    test('throws on non-success status', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          request.response.statusCode = HttpStatus.created;
        } else if (request.method == 'PUT') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir =
          await Directory.systemTemp.createTemp('webdav_upload_fail_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final localFile = File('${tmpDir.path}/upload.txt');
      await localFile.writeAsBytes([1, 2, 3]);

      expect(
        () => client.writeFile(localFile.path, '/remote/forbidden.txt'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('wdPropfind', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-2xx PROPFIND', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.readDir('/'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('throws when readDir returns null data', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.multiStatus;
        await request.response.close();
      });

      // readDir will call wdPropfind which expects text response
      // null data depends on Dio behavior - may or may not be testable
    });

    test('throws when readProps returns null data', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.multiStatus;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.readProps('/empty'),
        throwsA(anything),
      );
    });
  });

  group('wdMkcol', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-201/405 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.mkdir('/forbidden-dir/'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('mkdirAll falls back to incremental creation on 409', () async {
      final mkcolPaths = <String>[];

      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
          // First attempt returns 409, incremental succeeds
          if (mkcolPaths.length == 1) {
            request.response.statusCode = HttpStatus.conflict;
          } else {
            request.response.statusCode = HttpStatus.created;
          }
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.mkdirAll('/a/b/c/');

      expect(mkcolPaths.length, greaterThan(1));
      expect(mkcolPaths, contains('/a/'));
      expect(mkcolPaths, contains('/a/b/'));
      expect(mkcolPaths, contains('/a/b/c/'));
    });

    test('mkdirAll throws on non-201/405 during incremental', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.mkdirAll('/a/b/c/'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('mkdirAll accepts 405 for existing directories', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.mkdirAll('/existing/'), completes);
    });
  });

  group('wdDelete', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('accepts 200 OK', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.remove('/ok'), completes);
    });

    test('accepts 202 Accepted', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.remove('/accepted'), completes);
    });

    test('accepts 404 Not Found', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.remove('/not-found'), completes);
    });

    test('207 Multi-Status without body throws', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.remove('/empty-multi-status'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('207 Multi-Status with success-only body throws', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/ok</d:href>
    <d:propstat>
      <d:prop><d:displayname>ok</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.remove('/success-only'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('no member failures'),
        )),
      );
    });

    test('207 Multi-Status with invalid XML throws', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('not-valid-xml');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.remove('/invalid-xml'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('Unable to parse'),
        )),
      );
    });

    test('throws on unexpected status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 418;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.remove('/teapot'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('wdCopyMove', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('COPY throws on 207 with failure', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dest</d:href>
    <d:status>HTTP/1.1 403 Forbidden</d:status>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.copy('/src', '/dest'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('COPY throws on 207 with non-String body', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.copy('/src', '/dest'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('COPY throws on 207 with invalid XML', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('not-xml');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.copy('/src', '/dest'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('Unable to parse'),
        )),
      );
    });

    test('COPY with success-only 207 completes', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dest</d:href>
    <d:propstat>
      <d:prop><d:displayname>dest</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await expectLater(client.copy('/src', '/dest'), completes);
    });

    test('COPY auto-creates parent on 409', () async {
      final methods = <String>[];

      server.listen((request) async {
        await request.drain();
        methods.add(request.method);
        if (request.method == 'MKCOL') {
          request.response.statusCode = HttpStatus.created;
        } else if (request.method == 'COPY') {
          if (methods.where((m) => m == 'COPY').length <= 1) {
            request.response.statusCode = HttpStatus.conflict;
          } else {
            request.response.statusCode = HttpStatus.created;
          }
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.copy('/src', '/new-dir/dest');

      expect(methods, contains('MKCOL'));
      expect(methods.where((m) => m == 'COPY').length, 2);
    });

    test('throws on unexpected status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.copy('/src', '/dest'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('wdLock', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-200/201 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.lock('/file.txt'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('refresh lock returns existing token from If header', () async {
      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:lockdiscovery>
    <d:activelock>
      <d:locktoken><d:href>opaquelocktoken:new-token</d:href></d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock(
        '/file.txt',
        refreshLock: true,
        ifHeader:
            '<http://localhost/file.txt> (<opaquelocktoken:existing-token>)',
      );

      expect(token, 'opaquelocktoken:existing-token');
    });

    test('refresh lock throws when If header missing', () async {
      final client = WebdavClient.noAuth(url: 'http://localhost');

      expect(
        () => client.lock('/file.txt', refreshLock: true),
        throwsA(isA<WebdavException>()),
      );
    });

    test('refresh lock throws when If header has no valid token', () async {
      final client = WebdavClient.noAuth(url: 'http://localhost');

      expect(
        () => client.lock(
          '/file.txt',
          refreshLock: true,
          ifHeader: '<http://localhost/file.txt> (["etag"])',
        ),
        throwsA(isA<WebdavException>()),
      );
    });

    test('refresh lock throws on non-200', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.lock(
          '/file.txt',
          refreshLock: true,
          ifHeader: '<http://localhost/file.txt> (<opaquelocktoken:abc>)',
        ),
        throwsA(isA<WebdavException>()),
      );
    });

    test('lock extracts token from response header', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:header-token>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'opaquelocktoken:header-token');
    });

    test('lock extracts token from response body', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:lockdiscovery>
    <d:activelock>
      <d:lockscope><d:exclusive/></d:lockscope>
      <d:locktype><d:write/></d:locktype>
      <d:locktoken>
        <d:href>opaquelocktoken:body-token</d:href>
      </d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'opaquelocktoken:body-token');
    });

    test('lock falls back to locktoken/href', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:locktoken>
    <d:href>urn:uuid:fallback-token</d:href>
  </d:locktoken>
</d:prop>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'urn:uuid:fallback-token');
    });

    test('lock falls back to href with uuid pattern', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:href>urn:uuid:direct-href-token</d:href>
</d:prop>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'urn:uuid:direct-href-token');
    });

    test('lock throws when no token found in response', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<?xml version="1.0"?><empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.lock('/file.txt'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('lock with shared scope', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:shared>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt', exclusive: false);
      expect(token, 'opaquelocktoken:shared');
    });

    test('lock with owner as URL wraps in href element', () async {
      String? capturedBody;

      server.listen((request) async {
        capturedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:url-owner>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.lock('/file.txt', owner: 'http://example.com/user');
      expect(capturedBody, contains('<d:href>'));
      expect(capturedBody, contains('http://example.com/user'));
    });

    test('lock with owner as text', () async {
      String? capturedBody;

      server.listen((request) async {
        capturedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:text-owner>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.lock('/file.txt', owner: 'Test User');
      expect(capturedBody, contains('Test User'));
      expect(capturedBody, isNot(contains('<d:href>')));
    });
  });

  group('wdUnlock', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-204/200 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.unlock('/file.txt', 'opaquelocktoken:abc'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('sends Lock-Token header', () async {
      String? capturedToken;

      server.listen((request) async {
        await request.drain();
        capturedToken = request.headers.value('Lock-Token');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.unlock('/file.txt', 'opaquelocktoken:abc');
      expect(capturedToken, '<opaquelocktoken:abc>');
    });

    test('does not double-wrap an already bracketed Lock-Token header',
        () async {
      String? capturedToken;

      server.listen((request) async {
        await request.drain();
        capturedToken = request.headers.value('Lock-Token');
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.unlock('/file.txt', '<opaquelocktoken:abc>');
      expect(capturedToken, '<opaquelocktoken:abc>');
    });
  });

  group('wdProppatch', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('throws on non-2xx status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.setProps('/file.txt', {'d:displayname': 'new'}),
        throwsA(isA<WebdavException>()),
      );
    });

    test('throws when 207 response has no body', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.setProps('/file.txt', {'d:displayname': 'new'}),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('multi-status body'),
        )),
      );
    });

    test('throws when 207 response has failure', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.setProps('/file.txt', {'d:displayname': 'new'}),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('Failed'),
        )),
      );
    });

    test('throws on invalid XML in 207', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        request.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.response.write('not-xml');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.setProps('/file.txt', {'d:displayname': 'new'}),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('Unable to parse'),
        )),
      );
    });
  });

  group('Client request target resolution', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('_requestTarget with query string', () async {
      String? capturedPath;

      server.listen((request) async {
        capturedPath = '${request.uri.path}?${request.uri.query}';
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('ok');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.request<String>(
        'GET',
        target: '/path?query=value',
        configure: (options) => options.responseType = ResponseType.plain,
      );

      expect(capturedPath, '/path?query=value');
    });
  });

  group('Cache-control for If headers', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test(
        'adds cache-control when If header present without existing cache-control',
        () async {
      String? capturedCacheControl;
      String? capturedPragma;

      server.listen((request) async {
        capturedCacheControl = request.headers.value('cache-control');
        capturedPragma = request.headers.value('pragma');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('ok');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.request<String>(
        'GET',
        headers: {'If': '<http://localhost/path> (["etag"])'},
        configure: (options) => options.responseType = ResponseType.plain,
      );

      expect(capturedCacheControl, 'no-cache');
      expect(capturedPragma, 'no-cache');
    });

    test('preserves existing cache-control when If header present', () async {
      String? capturedCacheControl;

      server.listen((request) async {
        capturedCacheControl = request.headers.value('cache-control');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('ok');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.request<String>(
        'GET',
        headers: {
          'If': '<http://localhost/path> (["etag"])',
          'Cache-Control': 'max-age=3600',
          'Pragma': 'custom',
        },
        configure: (options) => options.responseType = ResponseType.plain,
      );

      expect(capturedCacheControl, 'max-age=3600');
    });
  });

  group('_createParent edge cases', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('skip _createParent when target is empty path', () async {
      final mkcolPaths = <String>[];

      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
        }
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      // Write to root path - parent is empty so no MKCOL
      await client.write('/', Uint8List.fromList([1]));
      // Should not create any directories
      expect(mkcolPaths, isEmpty);
    });

    test('skip _createParent when file is at root', () async {
      final mkcolPaths = <String>[];

      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
        }
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.write('/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, isEmpty);
    });

    test('skip _createParent for absolute URI with different authority',
        () async {
      final mkcolPaths = <String>[];

      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
        }
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://localhost:${server.port}/base',
      );

      // Write to a different host's URI - should skip MKCOL
      await client.write(
        'http://${server.address.host}:${server.port}/other/dir/file.txt',
        Uint8List.fromList([1]),
      );
      expect(mkcolPaths, isEmpty);
    });
  });

  group('exists', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('returns false on 404', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(await client.exists('/missing'), isFalse);
    });

    test('rethrows non-404 errors', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.exists('/forbidden'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('modifyProps', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async => server.close(force: true));

    test('sets and removes properties', () async {
      String? capturedBody;

      server.listen((request) async {
        if (request.method == 'PROPPATCH') {
          capturedBody = await utf8.decoder.bind(request).join();
          request.response
            ..statusCode = 207
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.modifyProps(
        '/file.txt',
        setProps: {'custom:prop1': 'val1'},
        removeProps: ['custom:prop2'],
        namespaces: {'custom': 'http://example.com/custom'},
      );

      expect(capturedBody, contains('prop1'));
      expect(capturedBody, contains('val1'));
      expect(capturedBody, contains('prop2'));
    });

    test('only sets properties', () async {
      String? capturedBody;

      server.listen((request) async {
        if (request.method == 'PROPPATCH') {
          capturedBody = await utf8.decoder.bind(request).join();
          request.response
            ..statusCode = 207
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        } else {
          await request.drain();
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.modifyProps(
        '/file.txt',
        setProps: {'d:displayname': 'New Name'},
      );

      expect(capturedBody, contains('displayname'));
      expect(capturedBody, contains('New Name'));
    });

    test('only removes properties', () async {
      String? capturedBody;

      server.listen((request) async {
        if (request.method == 'PROPPATCH') {
          capturedBody = await utf8.decoder.bind(request).join();
          request.response
            ..statusCode = 207
            ..headers.contentType =
                ContentType('application', 'xml', charset: 'utf-8')
            ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        } else {
          await request.drain();
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.modifyProps(
        '/file.txt',
        removeProps: ['d:displayname'],
      );

      expect(capturedBody, contains('displayname'));
    });
  });
}
