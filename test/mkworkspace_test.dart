import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('mkworkspace sends MKWORKSPACE with optional source href', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? body;

    server.listen((request) async {
      method = request.method;
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<created/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
      options: const WebdavOptions(pathMode: PathMode.legacy),
    );

    final response = await client.mkworkspace(
      '/workspace',
      sourceHref: '/versions/1',
    );

    expect(method, 'MKWORKSPACE');
    expect(body, contains('<d:mkworkspace'));
    expect(body, contains('<d:href>/versions/1</d:href>'));
    expect(response.data, '<created/>');
  });
}
