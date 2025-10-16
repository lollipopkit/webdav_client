import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('delete sends Depth infinity per RFC 4918 §9.6.1', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? depthHeader;

    server.listen((request) async {
      if (request.method == 'DELETE') {
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

    await client.remove('/collection/');

    expect(depthHeader, equals('infinity'));
  });
}
