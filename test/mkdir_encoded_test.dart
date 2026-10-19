import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('mkdirAll preserves percent-encoded path segments incrementally', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    final paths = <String>[];

    server.listen((request) async {
      paths.add(request.uri.toString());
      await request.drain();
      if (paths.length == 1) {
        request.response.statusCode = HttpStatus.conflict;
      } else {
        request.response.statusCode = HttpStatus.created;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
      options: const WebdavOptions(pathMode: PathMode.legacy),
    );

    await client.mkdirAll('/a%20b/c%2Fd/');

    expect(paths, contains('/a%20b/'));
    expect(paths, contains('/a%20b/c%2Fd/'));
    expect(paths, isNot(contains('/a b/')));
  });
}
