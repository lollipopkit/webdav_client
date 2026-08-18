import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests targeting the final uncovered lines across all source files.
void main() {
  group('Auth base class', () {
    test('Auth.authorize returns null by default', () {
      // Auth is sealed, but we can test the base implementation
      // via NoAuth which calls super (the default implementation)
      const auth = NoAuth();
      expect(auth.authorize('GET', '/'), isNull);
      expect(auth.authorize('PUT', '/file'), isNull);
    });
  });

  group('ping error path', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('ping throws on 500', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      expect(client.ping, throwsA(isA<WebdavException>()));
    });
  });

  group('move() with depth parameter', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('move calls rename internally', () async {
      server.listen((request) async {
        await request.drain();
        if (request.method == 'MOVE') {
          request.response.statusCode = HttpStatus.created;
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      await client.move('/src', '/dest');
    });

    test('rename rejects non-infinity depth', () {
      final client = WebdavClient.noAuth(url: 'http://localhost');
      expect(
        () => client.rename('/a', '/b', depth: PropsDepth.zero),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('lock refresh with non-200 response', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('lock refresh throws on non-200', () async {
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

    test('lock refresh returns existing token from If header', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
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

    test('lock refresh extracts token from If header with opaquelocktoken',
        () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock(
        '/file.txt',
        refreshLock: true,
        ifHeader:
            '<http://localhost/file.txt> (<opaquelocktoken:test-token-123>)',
      );
      expect(token, 'opaquelocktoken:test-token-123');
    });
  });

  group('lock with body returns 201', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('lock accepts 201 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.set('Lock-Token', '<opaquelocktoken:new-lock>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'opaquelocktoken:new-lock');
    });
  });

  group('mkdirAll incremental failure', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('mkdirAll throws when incremental MKCOL fails', () async {
      var mkcolCount = 0;
      server.listen((request) async {
        await request.drain();
        if (request.method == 'MKCOL') {
          mkcolCount++;
          if (mkcolCount == 1) {
            // First MKCOL returns 409 (trigger incremental path)
            request.response.statusCode = HttpStatus.conflict;
          } else {
            // Subsequent MKCOL also fails
            request.response.statusCode = HttpStatus.forbidden;
          }
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(
        () => client.mkdirAll('/a/b/'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  group('propFindRaw edge cases', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('propFindRaw returns empty map for empty Multi-Status', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(
              '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final raw = await client.propFindRaw('/empty');
      expect(raw, isEmpty);
    });

    test('propFindRaw merges duplicate href entries', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/merged</d:href>
    <d:propstat>
      <d:prop><d:displayname>Merged</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/merged</d:href>
    <d:propstat>
      <d:prop><d:getetag>"123"</d:getetag></d:prop>
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

      final raw = await client.propFindRaw('/merged', depth: PropsDepth.zero);
      final merged = raw['/merged'];
      expect(merged, isNotNull);
      // Both entries should be merged under same status 200
      expect(merged![200]!.length, 2);
    });

    test('propFindRaw normalizes empty href to path', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href></d:href>
    <d:propstat>
      <d:prop><d:displayname>Empty</d:displayname></d:prop>
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

      final raw = await client.propFindRaw('/my-path');
      expect(raw.containsKey('/my-path'), isTrue);
    });
  });

  group('readDir and readProps null data', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('readProps handles empty multi-status body', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.multiStatus
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(''); // empty body
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      // Empty XML body will cause an exception
      expect(
        () => client.readProps('/empty'),
        throwsA(anything),
      );
    });
  });

  group('MultiStatusPropstat null statusCode in parseMultiStatusToMap', () {
    test('propstat without status element is skipped in map', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/nocode</d:href>
    <d:propstat>
      <d:prop><d:displayname>NoCode</d:displayname></d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final result = parseMultiStatusToMap(xml);
      // Entry exists for /nocode but no propstat entries (null statusCode skipped)
      expect(result['/nocode'], isNotNull);
      expect(result['/nocode']!.length, 0);
    });
  });

  group('Multi-Status response location element', () {
    test('parses response with location element', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/moved</d:href>
    <d:location>
      <d:href>/new-location</d:href>
    </d:location>
    <d:propstat>
      <d:prop><d:displayname>Moved</d:displayname></d:prop>
      <d:status>HTTP/1.1 301 Moved Permanently</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final responses = parseMultiStatus(xml);
      expect(responses.first.locationHref, '/new-location');
    });

    test('parses response with empty location', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/no-loc-href</d:href>
    <d:location></d:location>
    <d:propstat>
      <d:prop><d:displayname>NoLocHref</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final responses = parseMultiStatus(xml);
      expect(responses.first.locationHref, isNull);
    });
  });

  group('responseDescription', () {
    test('parses response description', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/desc</d:href>
    <d:responsedescription>Some human-readable error description</d:responsedescription>
    <d:propstat>
      <d:prop><d:displayname>Desc</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final responses = parseMultiStatus(xml);
      expect(responses.first.responseDescription,
          'Some human-readable error description');
    });

    test('parses empty response description as null', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/desc-empty</d:href>
    <d:responsedescription></d:responsedescription>
    <d:propstat>
      <d:prop><d:displayname>DescEmpty</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final responses = parseMultiStatus(xml);
      expect(responses.first.responseDescription, isNull);
    });
  });

  group('lock with If header forwarding', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('lock sends If header when provided', () async {
      String? capturedIf;
      server.listen((request) async {
        capturedIf = request.headers.value('if');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:with-if>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.lock(
        '/file.txt',
        ifHeader: '<http://localhost/file.txt> (<opaquelocktoken:existing>)',
      );
      expect(capturedIf, contains('opaquelocktoken:existing'));
    });
  });

  group('rename/move with ifHeader', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('rename forwards ifHeader to MOVE request', () async {
      String? capturedIf;
      server.listen((request) async {
        capturedIf = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.rename(
        '/old',
        '/new',
        ifHeader: '<http://localhost/old> (<opaquelocktoken:tok>)',
      );
      expect(capturedIf, contains('opaquelocktoken:tok'));
    });
  });

  group('wdReadWithStream error paths', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('wdReadWithStream with progress on content-length response', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '4')
          ..add([100, 200, 150, 50]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('webdav_progress2_');
      addTearDown(() async {
        if (tmpDir.existsSync()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final progress = <(int, int)>[];
      await client.readFile(
        '/progress-test',
        '${tmpDir.path}/out.bin',
        onProgress: (count, total) => progress.add((count, total)),
      );

      expect(progress, isNotEmpty);
      expect(progress.last.$1, 4); // all bytes received
      expect(progress.last.$2, 4); // total from Content-Length
    });
  });

  group('_formatPropertyName edge cases', () {
    test('formats element without prefix and without namespace', () {
      // Use propFindRaw which exercises _formatPropertyName through parseMultiStatusFailureMessages
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/test</d:href>
    <d:propstat>
      <d:prop><bareprop/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('bareprop'));
    });
  });

  group('parseMultiStatusFailureMessages with overall status', () {
    test('captures overall failure status', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/locked</d:href>
    <d:status>HTTP/1.1 423 Locked</d:status>
  </d:response>
</d:multistatus>
''';
      final failures = parseMultiStatusFailureMessages(xml);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('423'));
    });
  });
}
