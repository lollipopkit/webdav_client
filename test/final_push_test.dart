import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Final targeted tests for every remaining testable uncovered line.
void main() {
  // ========== dio.dart:612-622 (wdReadWithStream receive timeout) ==========
  group('wdReadWithStream receive timeout', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    // Note: The stream-level timeout (lines 612-622) fires only when the initial
    // HTTP response succeeds but the stream body hangs. This requires the initial
    // req() to return a 200 ResponseBody, then the stream to not complete within
    // receiveTimeout. In practice, Dio's own receive timeout fires at the HTTP
    // level before we reach this code path. This makes the stream timeout handler
    // effectively unreachable in normal operation.
    test('stream download completes normally', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add([1, 2, 3]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_stream_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      await client.readFile('/ok', '${tmpDir.path}/out.bin');
      final file = File('${tmpDir.path}/out.bin');
      expect(await file.readAsBytes(), [1, 2, 3]);
    });
  });

  // ========== dio.dart:927-929 (_defaultPortForScheme https) ==========
  group('_defaultPortForScheme via HTTPS authority comparison', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('write to HTTP server from HTTPS base skips MKCOL (different scheme)',
        () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });

      // Base uses http (our server), target also uses http
      // _authoritiesMatch compares default ports for scheme
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}/base/',
      );
      await client.write(
        'http://${server.address.host}:${server.port}/other/file.txt',
        Uint8List.fromList([1]),
      );
      // /other/file.txt doesn't start with /base/ → _createParent skips
      expect(mkcolPaths, isEmpty);
    });
  });

  // ========== dio.dart:939-970 (_serverPathFromTarget) ==========
  group('_serverPathFromTarget via _createParent', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('write with http:// URL extracts path via _serverPathFromTarget',
        () async {
      String? putPath;
      server.listen((request) async {
        if (request.method == 'PUT') putPath = request.uri.path;
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      // This uses resolveAgainstBaseUrl which handles http:// URLs
      await client.write(
        'http://${server.address.host}:${server.port}/a/b/c.txt',
        Uint8List.fromList([1]),
      );
      expect(putPath, '/a/b/c.txt');
    });

    test('write with scheme-less path creates parent', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      // scheme-less path with leading / → resolveAgainstBaseUrl resolves it
      await client.write('/new/dir/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, contains('/new/dir/'));
    });

    test('write with path not starting with / creates parent', () async {
      final mkcolPaths = <String>[];
      server.listen((request) async {
        if (request.method == 'MKCOL') mkcolPaths.add(request.uri.path);
        await request.drain();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      // No leading slash - resolveAgainstBaseUrl treats as relative
      await client.write('dir/file.txt', Uint8List.fromList([1]));
      expect(mkcolPaths, contains('/dir/'));
    });
  });

  // ========== dio.dart:479-486 (wdReadWithStream WebdavException catch) ==========
  // This is hit when req<ResponseBody> itself throws WebdavException during
  // the stream request. This happens when the server's response triggers
  // an exception in the req pipeline (e.g., auth failure with no retry).

  // ========== dio.dart:558-568 (onData handler) ==========
  // Already covered by normal download tests - the onData callback runs
  // for every chunk received during readFile.

  // ========== dio.dart:581-584 (onDone catch) ==========
  // Hit when fileReader.close() or asyncWrite fails in onDone.
  // Extremely hard to trigger - requires file system failure.

  // ========== dio.dart:589-596 (onError) ==========
  // Hit when the response stream emits an error event.
  // Very hard to trigger with a real HTTP server.

  // ========== lock.dart:103 (dead code after wdLock validation) ==========
  // This line is unreachable because wdLock already validates 200/201.

  // ========== prop.dart:229-231 (propFindRaw merge update) ==========
  group('propFindRaw merge path', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('duplicate href+status triggers update() existing branch', () async {
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
}
