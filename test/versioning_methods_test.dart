import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  Future<(String method, String? custom)> capture(
    Future<void> Function(WebdavClient client) action,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? custom;

    server.listen((request) async {
      method = request.method;
      custom = request.headers.value('X-Version-Test');
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'plain')
        ..write('ok');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );
    await action(client);
    return (method!, custom);
  }

  test('versionControl sends VERSION-CONTROL', () async {
    final result = await capture((client) async {
      await client.versionControl(
        '/file.txt',
        headers: const {'X-Version-Test': 'yes'},
      );
    });

    expect(result, ('VERSION-CONTROL', 'yes'));
  });

  test('checkout, checkin and uncheckout send RFC 3253 methods', () async {
    expect(
      await capture((client) => client.checkout('/file.txt')),
      ('CHECKOUT', null),
    );
    expect(
      await capture((client) => client.checkin('/file.txt')),
      ('CHECKIN', null),
    );
    expect(
      await capture((client) => client.uncheckout('/file.txt')),
      ('UNCHECKOUT', null),
    );
  });

  test('versioning helpers return plain response bodies', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'plain')
        ..write('checked');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.checkout('/file.txt');
    expect(response.data, 'checked');
    expect(response.requestOptions.responseType, ResponseType.plain);
  });
}
