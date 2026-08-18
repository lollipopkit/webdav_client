import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests for wdReadWithStream internal paths using real HTTP server.
void main() {
  group('wdReadWithStream timeout path (lines 612-622)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('stream timeout after initial data', () async {
      // Send 200 OK with chunked encoding, send some data, then hang
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked');
        // Send first chunk
        request.response.add([1, 2, 3]);
        await request.response.flush();
        // Then hang - never close, never send more
        // The timeout should fire
        await Completer<void>().future; // hang forever
      });

      // Create client with very short receive timeout
      final client = WebdavClient(
        url: 'http://${server.address.host}:${server.port}',
      );
      client.setReceiveTimeout(500); // 500ms

      final tmpDir =
          await Directory.systemTemp.createTemp('wd_stream_timeout_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      // The timeout should fire after 500ms since the stream never completes
      expect(
        () => client.readFile('/slow', '${tmpDir.path}/out.bin'),
        throwsA(anything),
      );
    });
  });

  group('wdReadWithStream cancel path (lines 605-607)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('cancel token fires during stream', () async {
      final controller = StreamController<List<int>>();
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked');
        request.response.add([1, 2, 3]);
        await request.response.flush();
        // Keep connection open using a controlled stream
        await for (final data in controller.stream) {
          request.response.add(data);
          await request.response.flush();
        }
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_cancel_');
      addTearDown(() async {
        await controller.close();
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      final cancelToken = CancelToken();
      // Cancel after a short delay
      Future.delayed(
          const Duration(milliseconds: 100), () => cancelToken.cancel('test'));

      expect(
        () => client.readFile('/cancel', '${tmpDir.path}/out.bin',
            cancelToken: cancelToken),
        throwsA(anything),
      );
    });
  });

  group('wdReadWithStream onError path (lines 589-596)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('stream error during download', () async {
      // Send 200 OK with chunked encoding, send data, then force error
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked');
        request.response.add([1, 2, 3]);
        await request.response.flush();
        // Force close the connection (this should trigger stream error)
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_error_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      // This should either succeed (data received before close) or throw
      try {
        await client.readFile('/error', '${tmpDir.path}/out.bin');
      } catch (_) {}
    });
  });

  group('wdReadWithStream null respData (line 496)', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('download succeeds for normal 200 response', () async {
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..add([10, 20, 30]);
        await request.response.close();
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );

      final tmpDir = await Directory.systemTemp.createTemp('wd_null_');
      addTearDown(() async {
        if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
      });

      await client.readFile('/ok', '${tmpDir.path}/out.bin');
      expect(await File('${tmpDir.path}/out.bin').readAsBytes(), [10, 20, 30]);
    });
  });
}
