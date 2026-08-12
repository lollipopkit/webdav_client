import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Tests for readStream/readFile stream handling using a real HTTP server.
void main() {
  group('readFile truncated response', () {
    late ServerSocket server;
    setUp(() async =>
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close());

    /// Serve a single raw HTTP response with [body] bytes and
    /// [declaredLength] on the Content-Length header, then close the socket.
    void serveOnce({required int declaredLength, required List<int> body}) {
      server.listen((socket) async {
        final buffer = BytesBuilder();
        await for (final chunk in socket) {
          buffer.add(chunk);
          final bytes = buffer.toBytes();
          if (bytes.length >= 4 &&
              String.fromCharCodes(bytes.sublist(bytes.length - 4)) ==
                  '\r\n\r\n') {
            socket.write(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Content-Length: $declaredLength\r\n'
              '\r\n',
            );
            socket.add(body);
            await socket.flush();
            // Abruptly close mid-body: fewer bytes than Content-Length.
            await socket.close();
            return;
          }
        }
      });
    }

    test('stream cut short by Content-Length mismatch throws and cleans up',
        () async {
      serveOnce(declaredLength: 100, body: [1, 2, 3]);

      final client = WebdavClient(
        url: 'http://${server.address.address}:${server.port}',
      );
      client.setReceiveTimeout(5000);

      final tmpDir =
          await Directory.systemTemp.createTemp('wd_truncated_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      final outFile = '${tmpDir.path}/out.bin';
      await expectLater(
        client.readFile('/truncated', outFile),
        throwsA(anything),
      );
      // A partial download must not be left behind as a valid file.
      expect(await File(outFile).exists(), isFalse);
    });
  });

  group('readFile receive timeout', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('receive timeout fires when server stops mid-stream', () async {
      // Send the response headers and one chunk, then hang forever. The
      // client-side receive timeout has to fire.
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked')
          ..add([1, 2, 3]);
        await request.response.flush();
        await Completer<void>().future; // hang forever
      });

      final client = WebdavClient(
        url: 'http://${server.address.host}:${server.port}',
      );
      client.setReceiveTimeout(300); // 300ms

      final tmpDir =
          await Directory.systemTemp.createTemp('wd_stream_timeout_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      final outFile = '${tmpDir.path}/out.bin';
      await expectLater(
        client.readFile('/slow', outFile),
        throwsA(isA<WebdavException>()),
      );
      expect(await File(outFile).exists(), isFalse);
    });
  });

  group('readFile cancel token', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('cancel token fires during an in-flight download', () async {
      final controller = StreamController<List<int>>();
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('application', 'octet-stream')
          ..headers.set('Transfer-Encoding', 'chunked');
        try {
          // Keep trickling data so the transfer stays alive until cancelled.
          await for (final data in controller.stream) {
            request.response.add(data);
            await request.response.flush();
          }
          await request.response.close();
        } catch (_) {
          // The client cancels mid-transfer, which may reset the connection
          // while we write; that is expected and must not fail the test.
        }
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.host}:${server.port}',
      );
      client.setReceiveTimeout(10000);

      final tmpDir = await Directory.systemTemp.createTemp('wd_cancel_');
      addTearDown(() async {
        await controller.close();
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      final cancelToken = CancelToken();
      // Keep the transfer going until cancellation arrives.
      final trickle = Stream.periodic(
        const Duration(milliseconds: 20),
        (_) => <int>[1, 2, 3],
      ).listen(controller.add);
      addTearDown(() => trickle.cancel());
      Future.delayed(
        const Duration(milliseconds: 150),
        () => cancelToken.cancel('test'),
      );

      await expectLater(
        client.readFile('/cancel', '${tmpDir.path}/out.bin',
            cancelToken: cancelToken),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('readFile connection error', () {
    late ServerSocket server;
    setUp(() async =>
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close());

    test('server aborting mid-body surfaces an error', () async {
      server.listen((socket) async {
        final buffer = BytesBuilder();
        await for (final chunk in socket) {
          buffer.add(chunk);
          final bytes = buffer.toBytes();
          if (bytes.length >= 4 &&
              String.fromCharCodes(bytes.sublist(bytes.length - 4)) ==
                  '\r\n\r\n') {
            // Begin a chunked response, send one chunk, then kill the
            // connection with no terminating chunk.
            socket.write(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Transfer-Encoding: chunked\r\n'
              '\r\n'
              '3\r\nabc\r\n',
            );
            await socket.flush();
            await socket.close();
            return;
          }
        }
      });

      final client = WebdavClient.noAuth(
        url: 'http://${server.address.address}:${server.port}',
      );
      client.setReceiveTimeout(5000);

      final tmpDir = await Directory.systemTemp.createTemp('wd_error_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      await expectLater(
        client.readFile('/error', '${tmpDir.path}/out.bin'),
        throwsA(anything),
      );
    });
  });

  group('readFile successful download', () {
    late HttpServer server;
    setUp(() async =>
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    tearDown(() async => server.close(force: true));

    test('writes the full body for a plain 200 response', () async {
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

      final tmpDir = await Directory.systemTemp.createTemp('wd_ok_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });

      await client.readFile('/ok', '${tmpDir.path}/out.bin');
      expect(await File('${tmpDir.path}/out.bin').readAsBytes(), [10, 20, 30]);
    });
  });
}