import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests targeting specific remaining uncovered lines.
void main() {
  // ========== dio.dart:479-486 (wdReadWithStream WebdavException catch) ==========
  group('wdReadWithStream error paths', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('401 without WWW-Authenticate triggers WebdavException catch',
        () async {
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.contentType = ContentType('text', 'plain')
          ..write('Unauthorized');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_auth_fail_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      // The 401 in req() triggers WebdavException, which is caught
      // by the catch block in wdReadWithStream (lines 478-486)
      expect(
        () => client.readFile('/protected', '${tmpDir.path}/out.bin'),
        throwsA(anything),
      );
    });

    test('403 triggers WebdavException in stream request', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_forbidden_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      expect(
        () => client.readFile('/forbidden', '${tmpDir.path}/out.bin'),
        throwsA(isA<WebdavException>()),
      );
    });

    test('500 triggers WebdavException in stream request', () async {
      server.listen((request) async {
        await request.drain();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_server_err_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      expect(
        () => client.readFile('/error', '${tmpDir.path}/out.bin'),
        throwsA(isA<WebdavException>()),
      );
    });
  });

  // ========== dio.dart:939-970 (_serverPathFromTarget) ==========
  group('_serverPathFromTarget via malformed URL', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('write with malformed URL triggers _serverPathFromTarget fallback',
        () async {
      var hits = 0;
      server.listen((request) async {
        hits++;
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      // 'http://[' causes Uri.parse to throw, triggering _serverPathFromTarget
      await expectLater(
        client.write('http://[', Uint8List.fromList([1])),
        throwsException,
      );
      expect(hits, 1);
    });
  });
}
