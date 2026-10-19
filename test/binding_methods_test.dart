import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  Future<(String method, String body, String? overwrite)> capture(
    Future<void> Function(WebdavClient client) action, {
    WebdavOptions options = const WebdavOptions(),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? body;
    String? overwrite;

    server.listen((request) async {
      method = request.method;
      overwrite = request.headers.value('Overwrite');
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<ok/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
      options: options,
    );
    await action(client);
    return (method!, body!, overwrite);
  }

  test('bind builds RFC 5842 body', () async {
    final result = await capture((client) async {
      await client.bind('/collection/', segment: 'alias.txt', href: '/src.txt');
    }, options: const WebdavOptions(pathMode: PathMode.legacy));

    expect(result.$1, 'BIND');
    expect(result.$2, contains('<d:bind'));
    expect(result.$2, contains('<d:segment>alias.txt</d:segment>'));
    expect(result.$2, contains('<d:href>/src.txt</d:href>'));
  });

  test('unbind builds RFC 5842 body', () async {
    final result = await capture((client) async {
      await client.unbind('/collection/', segment: 'alias.txt');
    });

    expect(result.$1, 'UNBIND');
    expect(result.$2, contains('<d:unbind'));
    expect(result.$2, contains('<d:segment>alias.txt</d:segment>'));
  });

  test('rebind builds RFC 5842 body and overwrite header', () async {
    final result = await capture((client) async {
      await client.rebind(
        '/collection/',
        segment: 'alias.txt',
        href: '/src.txt',
        overwrite: true,
      );
    }, options: const WebdavOptions(pathMode: PathMode.legacy));

    expect(result.$1, 'REBIND');
    expect(result.$2, contains('<d:rebind'));
    expect(result.$2, contains('<d:href>/src.txt</d:href>'));
    expect(result.$3, 'T');
  });
}
