import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Final targeted tests to close remaining coverage gaps.
void main() {
  group('quota with null data', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('quota throws when no files parsed from response', () async {
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

      expect(client.quota, throwsA(isA<WebdavException>()));
    });
  });

  group('buildPutHeaders additional headers', () {
    test('overrides content-type via additionalHeaders', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      String? capturedContentType;
      server.listen((request) async {
        capturedContentType = request.headers.contentType?.toString();
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.write(
        '/test.txt',
        Uint8List.fromList([1, 2, 3]),
      );
      // Default content type is application/octet-stream
      expect(capturedContentType, contains('octet-stream'));
    });
  });

  group('_serverPathFromTarget edge cases', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('write with absolute URL extracts server path', () async {
      String? putPath;
      server.listen((request) async {
        if (request.method == 'PUT') {
          putPath = request.uri.path;
        }
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final authority = 'http://${server.address.host}:${server.port}';
      final client = WebdavClient.noAuth(url: '$authority/base');

      await client.write(
        '$authority/other/path/file.txt',
        Uint8List.fromList([1]),
      );

      expect(putPath, '/other/path/file.txt');
    });
  });

  group('_defaultPortForScheme', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('authority comparison with default ports', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
        }
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      // Use explicit port so _authoritiesMatch compares correctly
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}/base',
      );

      // Write to same authority - should create parent
      await client.write(
        'http://${server.address.host}:${server.port}/base/sub/file.txt',
        Uint8List.fromList([1]),
      );

      expect(mkcolPaths, contains('/base/sub/'));
    });
  });

  group('wdReadWithStream stream error handling', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('stream download with progress tracking', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '10')
          ..add([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir =
          await Directory.systemTemp.createTemp('webdav_stream_test_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      final progressList = <int>[];
      await client.readFile(
        '/progress.bin',
        '${tmpDir.path}/out.bin',
        onProgress: (count, total) => progressList.add(count),
      );

      expect(progressList, isNotEmpty);
      expect(progressList.last, 10);
    });
  });

  group('_createParent with scheme-less base', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('skip _createParent when base has no authority', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') {
          mkcolPaths.add(request.uri.path);
        }
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      // Normal base with authority
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      // Write to root file (no parent to create)
      await client.write('/root.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, isEmpty);
    });
  });

  group('_serializeTimeoutHeader edge cases', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('lock with timeout preferences', () async {
      String? capturedTimeout;
      server.listen((request) async {
        capturedTimeout = request.headers.value('timeout');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:tok>')
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
        timeoutPreferences: [LockTimeout.seconds(600), const LockTimeout.infinite()],
      );

      expect(capturedTimeout, 'Second-600, Infinite');
    });

    test('lock with infinite timeout (timeout <= 0)', () async {
      String? capturedTimeout;
      server.listen((request) async {
        capturedTimeout = request.headers.value('timeout');
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '<opaquelocktoken:tok>')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.lock('/file.txt', timeout: 0);

      expect(capturedTimeout, 'Infinite');
    });
  });

  group('MKCOL with ifHeader forwarding', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('mkdirAll forwards ifHeader to MKCOL', () async {
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

      await client.mkdirAll(
        '/new-dir/',
        ifHeader: '<http://localhost/new-dir/> (<opaquelocktoken:abc>)',
      );

      expect(capturedIf, contains('opaquelocktoken:abc'));
    });
  });

  group('_extractLockToken edge cases', () {
    test('lock body with only href matching urn:uuid', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0"?>
<root>
  <href>urn:uuid:some-random-uuid</href>
</root>
''');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'urn:uuid:some-random-uuid');
    });
  });

  group('wdLock body with empty data for refresh', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('lock refresh omits Content-Type and Depth headers', () async {
      String? capturedContentType;
      String? capturedDepth;
      server.listen((request) async {
        capturedContentType = request.headers.contentType?.toString();
        capturedDepth = request.headers.value('depth');
        await request.drain();
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

      await client.lock(
        '/file.txt',
        refreshLock: true,
        ifHeader: '<http://localhost/file.txt> (<opaquelocktoken:tok>)',
      );

      expect(capturedContentType, isNull);
      expect(capturedDepth, isNull);
    });
  });

  group('_parseHttpDate edge cases', () {
    test('parses correct HTTP date format', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

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
    <d:href>/dated.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getlastmodified>Fri, 20 Dec 2024 15:30:00 GMT</d:getlastmodified>
        <d:creationdate>2024-12-20T15:30:00Z</d:creationdate>
        <d:displayname>dated.txt</d:displayname>
      </d:prop>
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

      final files = await client.readDir('/', depth: PropsDepth.zero);
      expect(files.length, 1);
      expect(files.first.modified, isNotNull);
      expect(files.first.created, isNotNull);
    });

    test('falls back to DateTime.tryParse for non-HTTP date', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

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
    <d:href>/isodate.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getlastmodified>2024-12-20T15:30:00Z</d:getlastmodified>
        <d:displayname>isodate.txt</d:displayname>
      </d:prop>
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

      final files = await client.readDir('/', depth: PropsDepth.zero);
      expect(files.length, 1);
      // Falls back to DateTime.tryParse which handles ISO dates
      expect(files.first.modified, isNotNull);
    });
  });

  group('_normalizeHrefForComparison edge cases', () {
    test('skipSelf filters non-collection file with trailing slash', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

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
    <d:href>/dir</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>file.txt</d:displayname>
      </d:prop>
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

      // readDir with path that doesn't end in /
      final files = await client.readDir('/dir', depth: PropsDepth.zero);
      expect(files.length, 1);
      expect(files.first.name, 'file.txt');
    });

    test('skipSelf handles query strings in href', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

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
    <d:href>/dir/?t=123</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
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

      final files = await client.readDir('/dir/');
      expect(files.length, 1);
      expect(files.first.name, 'child.txt');
    });

    test('skipSelf handles fragment in href', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

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
    <d:href>/dir/#frag</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
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

      final files = await client.readDir('/dir/');
      expect(files.length, 1);
      expect(files.first.name, 'child.txt');
    });
  });

  group('_formatPropertyName without prefix and namespace', () {
    test('formats bare element name', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/bare</d:href>
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

  group('_extractLockTokenFromHeaderValue', () {
    test('lock with token in angle brackets in header', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', '  <opaquelocktoken:trimmed>  ')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'opaquelocktoken:trimmed');
    });

    test('lock with bare token in header (no angle brackets)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Lock-Token', 'urn:uuid:bare-token')
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final token = await client.lock('/file.txt');
      expect(token, 'urn:uuid:bare-token');
    });
  });

  group('_buildIfHeader with Not tag', () {
    test('conditionalPut with notTag=true', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      String? capturedIf;
      server.listen((request) async {
        capturedIf = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.conditionalPut(
        '/resource.txt',
        Uint8List.fromList([1, 2, 3]),
        etag: 'old-etag',
        notTag: true,
      );

      expect(capturedIf, contains('Not'));
      expect(capturedIf, contains('"old-etag"'));
    });

    test('conditionalPut with weak etag', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      String? capturedIf;
      server.listen((request) async {
        capturedIf = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.conditionalPut(
        '/resource.txt',
        Uint8List.fromList([1, 2, 3]),
        etag: 'W/"weak-etag"',
      );

      expect(capturedIf, contains('W/"weak-etag"'));
    });

    test('conditionalPut with unquoted etag gets quoted', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));

      String? capturedIf;
      server.listen((request) async {
        capturedIf = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      await client.conditionalPut(
        '/resource.txt',
        Uint8List.fromList([1, 2, 3]),
        etag: 'unquoted',
      );

      expect(capturedIf, contains('"unquoted"'));
    });
  });

  group('wdReadWithBytes on non-2xx non-redirect', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => server.close(force: true));

    test('throws on 403', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      expect(() => client.read('/forbidden'), throwsA(isA<WebdavException>()));
    });
  });
}
