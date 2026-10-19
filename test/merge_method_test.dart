import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('merge builds RFC 3253 MERGE body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? body;

    server.listen((request) async {
      method = request.method;
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<multistatus/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
      options: const WebdavOptions(pathMode: PathMode.legacy),
    );

    final response = await client.merge(
      '/target',
      '/versions/1',
      noAutoMerge: true,
      noCheckout: true,
    );

    expect(method, 'MERGE');
    expect(body, contains('<d:merge'));
    expect(body, contains('<d:source>'));
    expect(body, contains('<d:href>/versions/1</d:href>'));
    expect(body, contains('<d:no-auto-merge/>'));
    expect(body, contains('<d:no-checkout/>'));
    expect(response.data, '<multistatus/>');
  });
}
