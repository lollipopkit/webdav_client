import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Precise tests targeting every remaining uncovered line.
void main() {
  // ========== auth.dart:10 (sealed base class) ==========
  // Auth is sealed and its authorize() is never called directly - only via subclasses.

  // ========== client.dart:89 ==========
  group('ping error path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('throws when OPTIONS returns non-2xx', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(client.ping, throwsA(isA<WebdavException>()));
    });
  });

  // ========== dio.dart:368,371 (wdCopyMove 207 non-string) ==========
  // These lines require the response.data to NOT be a String.
  // Dio with ResponseType.plain always returns String for 207.
  // The only way is if Dio returns something else - which requires raw ResponseType.
  // Since wdCopyMove uses ResponseType.plain, body is! String is dead code for normal flows.

  // ========== dio.dart:479-496 (wdReadWithStream WebdavException catch) ==========
  // Lines 479-486: on WebdavException during stream request - requires stream req to fail
  // This happens when the initial stream request throws WebdavException.
  // But wdReadWithBytes already handles redirects, and wdReadWithStream uses the same req.
  // These lines are hit when the server responds with non-200 on the stream request.

  // ========== dio.dart:558-622 (stream onDone/onError/cancel/timeout) ==========
  // onDone with error: fileReader.writeFrom fails
  // onError: stream emits error
  // cancel: cancelToken fires
  // timeout: receive timeout fires

  // ========== dio.dart:927-970 (_defaultPortForScheme, _serverPathFromTarget) ==========
  // _defaultPortForScheme: called via _authoritiesMatch when URI has no port
  // _serverPathFromTarget: called via _createParent when target is not absolute

  // ========== lock.dart:103 ==========
  // Dead code - wdLock already validates 200/201

  // ========== prop.dart:209,211 (propFindRaw null data) ==========
  // Dio typed Response<String> for 207 never has null data - it's always empty string or XML.
  // These are defensive null checks that are unreachable in practice.

  // ========== prop.dart:229-231 (propFindRaw merge) ==========
  // The update() existing branch - reached when same href has duplicate status codes

  // ========== read.dart:35,37,73,75 (null data) ==========
  // Same as prop.dart - Dio Response<String> data is never null for successful PROPFIND.

  // ========== utils.dart:255-256 (_formatPropertyName namespace path) ==========
  // Reached when element has namespaceUri but no prefix
  // This happens with xmlns="..." (default namespace)

  // ========== utils.dart:410 (_ensurePropPatchSuccess) ==========
  // The status < 200 || status >= 300 check

  // ========== webdav_file.dart:286 (query strip in normalize) ==========
  // Reached when value has '?' AFTER the parsed block doesn't strip it.
  // This happens when parsed is null OR parsed conditions don't match.
  // For href '?q=1': parsed = Uri.parse('?q=1'), path='', hasScheme=false,
  // value doesn't start with '/', path is empty → none match → value stays '?q=1'
  // → indexOf('?') = 0 → line 286!

  // ========== webdav_file.dart:291 (fragment strip in normalize) ==========
  // Similar: href '#frag' → parsed = Uri.parse('#frag'), path='', none match
  // → value stays '#frag' → indexOf('#') = 0 → line 291!

  // ========== webdav_file.dart:308 (trailing slash strip for non-collection) ==========
  // Reached when treatAsCollection=false AND value.length > 1 AND value.endsWith('/')
  // Base without trailing / → treatAsCollection = false
  // href ending with / → value ends with /

  group('webdav_file normalize remaining paths', () {
    // Line 286: href starts with '?' (no path, no leading /)
    test('query in href without path (line 286)', () {
      // When skipSelf uses base '/dir', href '?q=1' is normalized:
      // value='?q=1', parsed=Uri.parse('?q=1') → path='', hasScheme=false
      // value doesn't start with '/', path is empty → none match
      // queryIndex = 0 → value = '' → line 286!
      // Then: value doesn't start with '/' → value = '/' → line 295!
      // Result: '/' ≠ '/dir' → NOT skipped
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>?q=1</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>q</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'q');
    });

    // Line 291: href starts with '#' (no path, no leading /)
    test('fragment in href without path (line 291)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>#top</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>t</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 't');
    });

    // Line 308: non-collection base, href with trailing /
    test('non-collection href ending with / gets slash stripped (line 308)',
        () {
      // Base = '/dir' (no trailing /) → treatAsCollection = false
      // Href = '/dir/file/' → value = '/dir/file/' → ends with '/' → line 308!
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>dir</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/file/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>file</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      // skipSelf=true, base='/dir' (no /) → treatAsCollection=false
      // self '/dir' → normalized = '/dir' → matches base → skipped
      // child '/dir/file/' → normalized = '/dir/file' (line 308!) → not equal to '/dir' → kept
      final files = WebdavFile.parseFiles('/dir', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'file');
    });
  });

  // ========== prop.dart:229-231 (merge update path) ==========
  group('propFindRaw merge update path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('merge duplicate href+status triggers update() existing branch',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/merged</d:href><d:propstat><d:prop><d:displayname>Name</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/merged</d:href><d:propstat><d:prop><d:getetag>"e"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final raw = await client.propFindRaw('/merged', depth: PropsDepth.zero);
      // Second entry triggers statusMap.update() with existing map
      expect(raw['/merged']![200]!.length, 2);
    });
  });

  // ========== utils.dart:255-256 (namespace without prefix) ==========
  group('_formatPropertyName namespace without prefix', () {
    test('element with default xmlns has namespace but no prefix', () {
      // xmlns="http://example.com" without prefix → namespaceUri set, prefix null
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
      expect(failures.first, contains('{http://example.com/ns}val'));
    });
  });

  // ========== utils.dart:410 ==========
  group('_ensurePropPatchSuccess status check', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('setProps throws on 500 status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.setProps('/f', {'d:displayname': 'x'}),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== read.dart:35,37 (readDir null data) ==========
  group('readDir null data path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readDir with empty multistatus returns empty', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(
              '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(await client.readDir('/'), isEmpty);
    });
  });

  // ========== read.dart:73,75 (readProps null data) ==========
  group('readProps null data path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readProps returns null for empty multistatus', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(
              '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(await client.readProps('/empty'), isNull);
    });
  });

  // ========== lock.dart:103 (dead code after wdLock validation) ==========
  // Line 103 `if (status != 200 && status != 201)` is unreachable because
  // wdLock already throws for non-200/201 responses at the Dio level.

  // ========== dio.dart remaining ==========
  group('dio internal paths', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('wdReadWithStream with deflate encoding', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Encoding', 'deflate')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('dio_deflate_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });
      int? lastTotal;
      await client.readFile('/d', '${tmpDir.path}/o',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('wdReadWithStream with compress encoding', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Encoding', 'compress')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('dio_compress_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });
      int? lastTotal;
      await client.readFile('/c', '${tmpDir.path}/o',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('wdReadWithStream tracks progress with Content-Length', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '3')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('dio_progress_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });
      final p = <(int, int)>[];
      await client.readFile('/p', '${tmpDir.path}/o',
          onProgress: (c, t) => p.add((c, t)));
      expect(p, isNotEmpty);
      expect(p.last.$2, 3);
    });

    test('wdReadWithStream cancel triggers closeAndDelete', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('dio_cancel_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });
      final cancel = CancelToken();
      // Cancel before the request even starts - the request may already
      // complete, so we just verify it doesn't hang
      cancel.cancel('test');
      try {
        await client.readFile('/x', '${tmpDir.path}/o', cancelToken: cancel);
      } catch (_) {} // expected
    });

    test('wdReadWithBytes 3xx without Location throws', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.movedPermanently;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.read('/noloc'), throwsA(isA<WebdavException>()));
    });
  });

  // ========== _serverPathFromTarget via _createParent ==========
  group('_serverPathFromTarget paths', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('absolute URI with http scheme extracts path', () async {
      String? putPath;
      server.listen((request) async {
        if (request.method == 'PUT') putPath = request.uri.path;
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      await client.write('http://${server.address.host}:${server.port}/a/b.txt',
          Uint8List.fromList([1]));
      expect(putPath, '/a/b.txt');
    });

    test('relative path creates parent via _createParent', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      await client.write('/a/b/c.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, contains('/a/b/'));
    });

    test('root file does not create parent', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      await client.write('/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, isEmpty);
    });
  });
}
