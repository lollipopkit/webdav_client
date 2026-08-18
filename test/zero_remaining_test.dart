import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests for the absolute last remaining uncovered lines.
void main() {
  // ========== auth.dart:10 (Auth base class - sealed, dead code) ==========

  // ========== client.dart:89 (ping error on non-2xx) ==========
  group('ping error', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('ping throws on 500 response', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(client.ping, throwsA(isA<WebdavException>()));
    });
  });

  // ========== dio.dart:368,371 (wdCopyMove 207 with non-String body) ==========
  group('wdCopyMove 207 non-string', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('COPY with 207 response body type check', () async {
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
      <d:prop><d:displayname>ok</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      await expectLater(client.copy('/src', '/dest'), completes);
    });
  });

  // ========== dio.dart:478-622 (wdReadWithStream internals) ==========
  group('wdReadWithStream compressed encoding', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('download with Content-Encoding deflate sets total=-1', () async {
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
      final tmpDir = await Directory.systemTemp.createTemp('wd_deflate_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      int? lastTotal;
      await client.readFile('/deflate', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('download with Content-Encoding compress sets total=-1', () async {
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
      final tmpDir = await Directory.systemTemp.createTemp('wd_compress2_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      int? lastTotal;
      await client.readFile('/compress', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => lastTotal = t);
      expect(lastTotal, -1);
    });

    test('download with cancel token triggers closeAndDelete', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add([1, 2, 3]);
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final tmpDir = await Directory.systemTemp.createTemp('wd_cancel2_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      // Cancel immediately - should trigger the cancel path
      final cancelToken = CancelToken();
      scheduleMicrotask(() => cancelToken.cancel('test cancel'));

      try {
        await client.readFile('/cancel', '${tmpDir.path}/out.bin',
            cancelToken: cancelToken);
        fail('Expected an exception from cancelled download');
      } catch (e) {
        expect(e, isException);
        expect(File('${tmpDir.path}/out.bin').existsSync(), isFalse,
            reason: 'closeAndDelete should remove the output file');
      }
    });

    test('download progress tracks total from Content-Length', () async {
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
      final tmpDir = await Directory.systemTemp.createTemp('wd_total_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      final progress = <(int, int)>[];
      await client.readFile('/total', '${tmpDir.path}/out.bin',
          onProgress: (c, t) => progress.add((c, t)));
      expect(progress, isNotEmpty);
      expect(progress.last.$2, 3);
    });
  });

  // ========== utils.dart:255-256 (element with namespace, no prefix) ==========
  group('_formatPropertyName namespace path', () {
    test('element with default namespace (xmlns=) has namespace but no prefix',
        () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:">
  <response>
    <href>/test</href>
    <propstat>
      <prop><val xmlns="http://example.com/custom"/></prop>
      <status>HTTP/1.1 403 Forbidden</status>
    </propstat>
  </response>
</multistatus>
''';
      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isNotEmpty);
    });
  });

  // ========== utils.dart:410 ==========
  group('_ensurePropPatchSuccess', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('modifyProps throws on 500', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.modifyProps('/f', setProps: {'d:displayname': 'x'}),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== prop.dart:209,211,229-231 ==========
  group('propFindRaw edge cases', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('returns empty for empty multistatus response', () async {
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
      final raw = await client.propFindRaw('/empty');
      expect(raw, isEmpty);
    });

    test('merges duplicate href+status entries', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/m</d:href><d:propstat><d:prop><d:displayname>M</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/m</d:href><d:propstat><d:prop><d:getetag>"e"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final raw = await client.propFindRaw('/m', depth: PropsDepth.zero);
      expect(raw['/m']![200]!.length, 2);
    });
  });

  // ========== read.dart:35,37,73,75 (null data check) ==========
  group('readDir/readProps null data', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readDir handles empty XML response', () async {
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

    test('readProps returns null for empty response', () async {
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

  // ========== webdav_file.dart:286,291,308 ==========
  group('WebdavFile normalize edge cases', () {
    test('query in self href stripped for skipSelf comparison (286)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/d/?v=1</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>d</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/d/c</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>c</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/d/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'c');
    });

    test('fragment in self href stripped for skipSelf comparison (291)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/d/#top</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>d</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/d/c</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>c</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/d/', xml, skipSelf: true);
      expect(files.length, 1);
    });

    test(
        'non-collection ending with / gets slash stripped for non-collection (308)',
        () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/b/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype><d:displayname>b</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/b/f/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/><d:displayname>f</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/b/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'f');
    });
  });
}
