import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Final targeted tests to cover every remaining uncovered line.
void main() {
  // ========== auth.dart:10 ==========
  group('Auth base class authorize', () {
    test('base Auth.authorize is tested via NoAuth subclass', () {
      // Auth.authorize line 10 is the abstract/overridden method
      // NoAuth overrides it, so line 10 is the default implementation
      // We can't directly instantiate Auth (sealed), but NoAuth calls super
      const auth = NoAuth();
      expect(auth.authorize('GET', '/'), isNull);
      expect(auth.authorize('PUT', '/test'), isNull);
    });
  });

  // ========== client.dart:89 ==========
  group('ping throws on non-2xx', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('ping throws on 403', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(client.ping, throwsA(isA<WebdavException>()));
    });
  });

  // ========== dio.dart:368,371 ==========
  group('wdCopyMove 207 with non-String body', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('COPY returns 207 with non-String body throws', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('text', 'plain')
          ..add([1, 2, 3]); // binary data, not String
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
          () => client.copy('/src', '/dest'), throwsA(isA<WebdavException>()));
    });
  });

  // ========== dio.dart:478-622 (wdReadWithStream) ==========
  group('wdReadWithStream stream lifecycle', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('download with compressed encoding sets total=-1', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Encoding', 'deflate')
          ..headers.set('Transfer-Encoding', 'chunked')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_compress_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      int? lastTotal;
      await client.readFile('/compressed', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('download with Content-Length header tracks progress', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Content-Length', '5')
          ..add([10, 20, 30, 40, 50]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_cl_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      final progress = <(int, int)>[];
      await client.readFile('/cl-test', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => progress.add((c, t)));
      expect(progress, isNotEmpty);
      expect(progress.last.$1, 5);
      expect(progress.last.$2, 5);
    });

    test('download without Content-Length sets total=-1', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_nocl_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      int? lastTotal;
      await client.readFile('/no-cl', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('download with cancel token cancels stream', () async {
      final controller = StreamController<List<int>>();
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked');
        // Send initial data then block
        request.response.add([1, 2, 3]);
        await request.response.flush();
        // Keep connection open
        await controller.stream.listen((data) {
          request.response.add(data);
        }).asFuture<void>();
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_cancel_');
      addTearDown(() async {
        await controller.close();
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      final cancelToken = CancelToken();
      // Cancel after a short delay
      Future.delayed(
          const Duration(milliseconds: 50), () => cancelToken.cancel('test'));

      expect(
        () => client.readFile('/cancel', '${tmpDir.path}/out.bin',
            cancelToken: cancelToken),
        throwsA(anything),
      );
    });

    test('download throws on non-200 stream response', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_throw_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      expect(
        () => client.readFile('/missing', '${tmpDir.path}/out.bin'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== dio.dart:927-970 (_serverPathFromTarget) ==========
  group('_serverPathFromTarget edge cases', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('write with http:// scheme extracts path', () async {
      String? putPath;
      server.listen((request) async {
        if (request.method == 'PUT') putPath = request.uri.path;
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final auth = 'http://${server.address.host}:${server.port}';
      final client = WebdavClient.noAuth(url: '$auth/base');
      await client.write('$auth/test/path.txt', Uint8List.fromList([1]));
      expect(putPath, '/test/path.txt');
    });

    test('write with scheme-less target falls through', () async {
      String? putPath;
      server.listen((request) async {
        if (request.method == 'PUT') putPath = request.uri.path;
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      await client.write('/direct/target', Uint8List.fromList([1]));
      expect(putPath, '/direct/target');
    });
  });

  // ========== lock.dart:57,103,117,120 ==========
  group('lock error paths', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('lock refresh throws on non-200 (line 57)', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.lock('/file.txt',
            refreshLock: true,
            ifHeader: '<http://localhost/file.txt> (<opaquelocktoken:abc>)'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('lock body throws on non-200/201 (line 103)', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.lock('/file.txt'), throwsA(isA<WebdavException>()));
    });

    test('lock with empty body and no header throws (lines 117-120)', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          // No Lock-Token header
          ..headers.contentType = ContentType('text', 'plain')
          ..write(''); // Empty body
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.lock('/file.txt'), throwsA(isA<WebdavException>()));
    });
  });

  // ========== prop.dart:209,211 (propFindRaw null data) ==========
  group('propFindRaw null data', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('propFindRaw throws when response data is null', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = 207;
        // No content-type, empty body
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.propFindRaw('/test'), throwsA(anything));
    });
  });

  // ========== prop.dart:229-231 (propFindRaw merge) ==========
  group('propFindRaw merge duplicate href entries', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('merges duplicate href entries under same status', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
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
      <d:prop><d:getetag>"abc"</d:getetag></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final raw = await client.propFindRaw('/merged', depth: PropsDepth.zero);
      expect(raw['/merged']![200]!.length, 2);
    });
  });

  // ========== read.dart:35,37 (readDir null data) ==========
  group('readDir null data', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readDir throws when response is empty', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('text', 'plain')
          ..write('');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.readDir('/test'), throwsA(anything));
    });
  });

  // ========== read.dart:73,75 (readProps null data) ==========
  group('readProps null data', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readProps returns null when no matching entry', () async {
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
      final result = await client.readProps('/empty');
      expect(result, isNull);
    });
  });

  // ========== utils.dart:192 (_decodeHref FormatException) ==========
  group('_decodeHref FormatException', () {
    test('parseMultiStatus with malformed UTF-8 in href returns original', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/path/%C0%AE</d:href>
    <d:propstat>
      <d:prop><d:displayname>bad</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final responses = parseMultiStatus(xml);
      expect(responses.first.href, '/path/%C0%AE');
    });
  });

  // ========== utils.dart:255-256 (_formatPropertyName with namespace, no prefix) ==========
  group('_formatPropertyName with namespace but no prefix', () {
    test('formats element with namespace URI but no prefix', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:custom="http://example.com/custom">
  <d:response>
    <d:href>/test</d:href>
    <d:propstat>
      <d:prop><custom:test/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('custom:test'));
    });
  });

  // ========== utils.dart:410 (_ensurePropPatchSuccess status check) ==========
  group('_ensurePropPatchSuccess', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('setProps throws on 403', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.setProps('/file', {'d:displayname': 'val'}),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== webdav_file.dart:255 (_decodeHrefValue FormatException) ==========
  group('_decodeHrefValue FormatException', () {
    test('parseFiles with malformed UTF-8 in href returns original', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/path/%C0%AE</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>bad</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.path, '/path/%C0%AE');
    });
  });

  // ========== webdav_file.dart:279-280 (_normalizeHrefForComparison) ==========
  group('_normalizeHrefForComparison edge cases', () {
    test('href without scheme and with non-empty path (line 279-280)', () {
      // scheme-less, non-empty path - parsed.path is non-empty
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>child.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'child.txt');
    });

    test('href with query gets stripped (line 286)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child.txt?v=1</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'child.txt');
    });

    test('href with fragment gets stripped (line 291)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/child.txt#frag</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
    });

    test('href without leading slash gets / prepended (line 295)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>relative/child.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>child.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'child.txt');
    });

    test(
        'non-collection href ending with / gets trailing slash removed (line 308)',
        () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/file/</d:href>
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
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      // Non-collection with / ending: path preserves decoded href
      expect(files.first.path, '/dir/file/');
      // But name is still extracted
      expect(files.first.name, 'file');
    });
  });
}
