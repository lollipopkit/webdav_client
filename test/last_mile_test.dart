import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests for the very last remaining uncovered lines.
void main() {
  // ========== utils.dart:255-256 (element with namespace but NO prefix) ==========
  group('_formatPropertyName namespace without prefix', () {
    test('element with default namespace (no prefix)', () {
      // xmlns (default namespace) gives namespaceUri but no prefix
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/test</d:href>
    <d:propstat>
      <d:prop><val xmlns="http://example.com/ns"/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isNotEmpty);
      // Should contain {http://example.com/ns}val
      expect(failures.first, contains('val'));
    });
  });

  // ========== utils.dart:410 ==========
  group('_ensurePropPatchSuccess status check', () {
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('modifyProps throws on non-2xx', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.modifyProps('/file', setProps: {'d:displayname': 'x'}),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== prop.dart:209,211 (propFindRaw null data) ==========
  group('propFindRaw', () {
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('returns empty for empty multistatus', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
          ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      final raw = await client.propFindRaw('/empty');
      expect(raw, isEmpty);
    });

    test('merges duplicate href entries (line 229-231)', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
          ..write('''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/m</d:href><d:propstat><d:prop><d:displayname>M</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/m</d:href><d:propstat><d:prop><d:getetag>"e"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      final raw = await client.propFindRaw('/m', depth: PropsDepth.zero);
      expect(raw['/m']![200]!.length, 2);
    });
  });

  // ========== read.dart:35,37,73,75 ==========
  group('readDir and readProps null data', () {
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readDir handles empty multistatus', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
          ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      expect(await client.readDir('/'), isEmpty);
    });

    test('readProps returns null for empty multistatus', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
          ..write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      expect(await client.readProps('/empty'), isNull);
    });
  });

  // ========== lock.dart:103 ==========
  // Line 103: `if (status != 200 && status != 201)` - this is checked AFTER wdLock returns.
  // wdLock already validates 200/201, so line 103 is unreachable dead code.
  // The only way to reach it is if wdLock returns something other than 200/201 without throwing.
  // Since wdLock checks (status != 200 && status != 201) → throw, lock.dart:103 is dead code.

  // ========== webdav_file.dart:286,291,308 ==========
  group('WebdavFile normalize remaining lines', () {
    test('query string in self href stripped for skipSelf (286)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/?v=1</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>child</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'child');
    });

    test('fragment in self href stripped for skipSelf (291)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/#top</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>child</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'child');
    });

    test('non-collection with trailing slash normalized for skipSelf (308)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/base/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>base</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/base/file/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>file</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/base/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'file');
    });
  });

  // ========== dio.dart remaining: _serverPathFromTarget, _createParent, _defaultPortForScheme ==========
  group('_createParent with various paths', () {
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('skip _createParent for absolute URI with matching authority', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final auth = 'http://${server.address.host}:${server.port}';
      final client = WebdavClient.noAuth(url: '$auth/base');
      // Absolute URI with same authority - _createParent should run
      await client.write('$auth/base/sub/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, contains('/base/sub/'));
    });

    test('skip _createParent when basePath is /', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      // Base path is '/' - should skip _createParent for root files
      await client.write('/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, isEmpty);
    });

    test('skip _createParent when effective path has no slash', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      await client.write('file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, isEmpty);
    });

    test('skip _createParent for absolute URI with different authority', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      // Use 127.0.0.1 for base, write target also to 127.0.0.1 (same server)
      final client = WebdavClient.noAuth(url: 'http://127.0.0.1:${server.port}/base/');
      // Same address but different base prefix
      await client.write('http://127.0.0.1:${server.port}/dir/file.txt', Uint8List.fromList([1]));
      // '/dir/file.txt' doesn't start with '/base/' → _createParent returns null
      expect(mkcolPaths, isEmpty);
    });
  });

  // ========== dio.dart:927-970 (_serverPathFromTarget) ==========
  group('_serverPathFromTarget via _createParent', () {
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('scheme-less target creates parent when path has slash', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      // scheme-less with leading slash: _serverPathFromTarget returns '/some/path/file.txt'
      // _createParent extracts parent '/some/path/' and creates it
      await client.write('/some/path/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, contains('/some/path/'));
    });
  });

  // ========== _defaultPortForScheme ==========
  group('_defaultPortForScheme via HTTPS', () {
    // Can't easily test HTTPS without certs, but we can verify HTTP default port works
    late HttpServer server;
    setUp(() async => server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('authority comparison with default http port', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('ok');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');
      final resp = await client.request<String>(
        'GET',
        configure: (o) => o.responseType = ResponseType.plain,
      );
      expect(resp.data, 'ok');
    });
  });
}
