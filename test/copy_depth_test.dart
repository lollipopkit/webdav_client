import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('copy Depth 0 propagates header per RFC 4918 §9.8', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? depthHeader;

    server.listen((request) async {
      if (request.method == 'COPY') {
        depthHeader = request.headers.value('Depth');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url:
          'http://${server.address.host}:${server.port}/remote.php/dav/files/alice',
    );

    await client.copy(
      '/remote.php/dav/files/alice/src.txt',
      '/remote.php/dav/files/alice/dest.txt',
      depth: PropsDepth.zero,
    );

    expect(depthHeader, equals('0'));
  });

  test('copy defaults to Depth infinity per RFC 4918 §9.8', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? depthHeader;

    server.listen((request) async {
      if (request.method == 'COPY') {
        depthHeader = request.headers.value('Depth');
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await client.copy('/source', '/dest');

    expect(depthHeader, equals('infinity'));
  });

  test('copy rejects Depth.one to follow RFC 4918 §9.8', () {
    final client = WebdavClient.noAuth(url: 'http://example.com');

    expect(
      () => client.copy(
        '/source',
        '/dest',
        depth: PropsDepth.one,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
