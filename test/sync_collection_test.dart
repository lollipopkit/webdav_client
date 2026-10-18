import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('syncCollection sends WebDAV Sync REPORT body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? depth;
    String? body;

    server.listen((request) async {
      method = request.method;
      depth = request.headers.value('Depth');
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<multistatus/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.syncCollection(
      '/collection/',
      syncToken: 'token-1',
      limit: 5,
      properties: const ['getetag', 'x:custom'],
      namespaces: const {'x': 'http://example.com/ns'},
    );

    expect(method, 'REPORT');
    expect(depth, '0');
    expect(body, contains('<d:sync-collection'));
    expect(body, contains('<d:sync-token>token-1</d:sync-token>'));
    expect(body, contains('<d:sync-level>1</d:sync-level>'));
    expect(body, contains('<d:nresults>5</d:nresults>'));
    expect(body, contains('<d:getetag/>'));
    expect(body, contains('xmlns:x="http://example.com/ns"'));
    expect(body, contains('<x:custom/>'));
    expect(response.data, '<multistatus/>');
  });

  test('syncCollection emits RFC 6578 infinite sync-level', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? depth;
    String? body;

    server.listen((request) async {
      method = request.method;
      depth = request.headers.value('Depth');
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<multistatus/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await client.syncCollection('/collection/', depth: PropsDepth.infinity);

    expect(method, 'REPORT');
    expect(depth, '0');
    expect(body, contains('<d:sync-level>infinite</d:sync-level>'));
  });
}
