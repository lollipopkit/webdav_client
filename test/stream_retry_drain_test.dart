import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('stream redirect drains the first response before retrying', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    var firstResponseDone = false;

    server.listen((request) async {
      if (request.uri.path == '/source') {
        request.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set('Location', '/target')
          ..write('redirect body');
        await request.response.close();
        firstResponseDone = true;
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('target body');
        await request.response.close();
      }
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.request<ResponseBody>(
      'GET',
      target: '/source',
      configure: (options) => options.responseType = ResponseType.stream,
    );
    await response.data!.stream.drain<void>();

    expect(firstResponseDone, isTrue);
    expect(response.statusCode, HttpStatus.ok);
  });
}
