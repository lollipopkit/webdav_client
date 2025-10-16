import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('conditionalPut adds cache-busting headers with If per RFC 4918 §10.4.5',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? cacheControl;
    String? pragma;
    String? ifHeader;

    server.listen((request) async {
      if (request.method == 'PUT') {
        cacheControl = request.headers.value('cache-control');
        pragma = request.headers.value('pragma');
        ifHeader = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await client.conditionalPut(
      '/file.txt',
      Uint8List.fromList([1, 2, 3]),
      lockToken: 'opaquelocktoken:put-test',
    );

    expect(ifHeader, isNotNull);
    expect(cacheControl, equals('no-cache'));
    expect(pragma, equals('no-cache'));
  });

  test('custom cache headers are preserved when present', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? cacheControl;
    String? pragma;

    server.listen((request) async {
      if (request.method == 'PUT') {
        cacheControl = request.headers.value('cache-control');
        pragma = request.headers.value('pragma');
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await client.conditionalPut(
      '/file.txt',
      Uint8List.fromList([4, 5, 6]),
      lockToken: 'opaquelocktoken:custom-cache',
      headers: const {
        'Cache-Control': 'no-cache, max-age=0',
        'Pragma': 'no-cache, custom',
      },
    );

    expect(cacheControl, equals('no-cache, max-age=0'));
    expect(pragma, equals('no-cache, custom'));
  });
}
