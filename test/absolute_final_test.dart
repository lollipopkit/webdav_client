import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Final targeted tests for remaining uncovered lines.
void main() {
  // ========== lock.dart:57 (lock refresh returns 201 instead of 200) ==========
  group('lock refresh 201 path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('lock refresh throws when wdLock returns 201', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.created // 201
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<empty/>');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      // wdLock returns 201 (valid for wdLock), but lock.dart:57 checks != 200
      // So for refresh, 201 should throw
      expect(
        () => client.lock('/file.txt',
            refreshLock: true,
            ifHeader: '<http://localhost/file.txt> (<opaquelocktoken:abc>)'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== lock.dart:103 (lock body returns status neither 200 nor 201) ==========
  // This is unreachable because wdLock already validates 200/201.
  // But let's verify: wdLock returns 200/201, and lock.dart:103 checks for
  // status != 200 && status != 201. Since wdLock already threw, this is dead code.
  // However, the _extractLockToken path after line 103 IS reachable.

  group('lock token extraction from body', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('lock returns 200 with locktoken/href in body (no header)', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.ok
          // No Lock-Token header
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:">
  <d:lockdiscovery>
    <d:activelock>
      <d:locktoken>
        <d:href>opaquelocktoken:from-body</d:href>
      </d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>
''');
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      final token = await client.lock('/file.txt');
      expect(token, 'opaquelocktoken:from-body');
    });
  });

  // ========== prop.dart:209,211 (propFindRaw null data) ==========
  group('propFindRaw null data handling', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('propFindRaw throws on empty multi-status body', () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('text', 'plain')
          ..write(''); // empty body
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(() => client.propFindRaw('/test'), throwsA(anything));
    });
  });

  // ========== prop.dart:229-231 (propFindRaw merge same href+status) ==========
  group('propFindRaw merge duplicate entries', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('merges properties under same href and status code', () async {
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
    <d:href>/res</d:href>
    <d:propstat>
      <d:prop><d:displayname>Name</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/res</d:href>
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
      final raw = await client.propFindRaw('/res', depth: PropsDepth.zero);
      expect(raw['/res']![200]!.length, 2);
    });
  });

  // ========== read.dart:35,37 (readDir null data) ==========
  group('readDir empty XML body', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('readDir returns empty list for empty multistatus', () async {
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
      final files = await client.readDir('/');
      expect(files, isEmpty);
    });
  });

  // ========== read.dart:73,75 (readProps null data) ==========
  group('readProps empty result', () {
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
      final props = await client.readProps('/empty');
      expect(props, isNull);
    });
  });

  // ========== utils.dart:255-256 ==========
  group('_formatPropertyName with namespace URI', () {
    test('element with namespace but no prefix shows as {uri}name', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:custom="http://example.com/ns">
  <d:response>
    <d:href>/test</d:href>
    <d:propstat>
      <d:prop><custom:val/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('custom:val'));
    });
  });

  // ========== utils.dart:410 ==========
  group('_ensurePropPatchSuccess error check', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('setProps throws on non-2xx status', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
          url: 'http://${server.address.host}:${server.port}');
      expect(
        () => client.setProps('/file', {'d:displayname': 'x'}),
        throwsA(isA<WebdavException>()),
      );
    });
  });
}
