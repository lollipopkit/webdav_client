import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('request resolves relative redirect locations against source URI',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? targetPath;

    server.listen((request) async {
      await request.drain();
      if (request.uri.path == '/dir/source') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', 'target');
      } else {
        targetPath = request.uri.path;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('target');
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.request<String>(
      'GET',
      target: '/dir/source',
      configure: (options) => options.responseType = ResponseType.plain,
    );

    expect(response.data, 'target');
    expect(targetPath, '/dir/target');
  });

  test('empty redirect Location is returned without following', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    var count = 0;

    server.listen((request) async {
      count++;
      await request.drain();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('Location', '   ');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.request<String>(
      'GET',
      target: '/loop',
      configure: (options) => options.responseType = ResponseType.plain,
    );
    expect(response.statusCode, HttpStatus.found);
    expect(count, 1);
  });

  test('request fails after too many redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('Location', request.uri.toString());
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await expectLater(
      client.request<String>(
        'GET',
        target: '/loop',
        configure: (options) => options.responseType = ResponseType.plain,
      ),
      throwsA(isA<WebdavException>()),
    );
  });

  test(
      'authenticated request does not automatically follow cross-origin redirects',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    var count = 0;

    server.listen((request) async {
      count++;
      await request.drain();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('Location', 'http://example.org/target');
      await request.response.close();
    });

    final client = WebdavClient.basicAuth(
      url: 'http://${server.address.host}:${server.port}',
      user: 'user',
      pwd: 'pass',
    );

    final response = await client.request<String>(
      'GET',
      target: '/source',
      configure: (options) => options.responseType = ResponseType.plain,
    );

    expect(response.statusCode, HttpStatus.found);
    expect(count, 1);
  });

  test('NoAuth read follows cross-origin download redirects', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await source.close(force: true);
      await target.close(force: true);
    });

    String? targetPath;

    source.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          'Location',
          'http://${target.address.host}:${target.port}/object.bin',
        );
      await request.response.close();
    });

    target.listen((request) async {
      targetPath = request.uri.path;
      request.response
        ..statusCode = HttpStatus.ok
        ..add([7, 8, 9]);
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${source.address.host}:${source.port}',
    );

    final bytes = await client.read('/download');

    expect(targetPath, '/object.bin');
    expect(bytes, [7, 8, 9]);
  });

  test('cross-origin NoAuth redirect strips sensitive caller headers',
      () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await source.close(force: true);
      await target.close(force: true);
    });

    String? authorization;
    String? cookie;
    String? proxyAuthorization;
    String? safeHeader;

    source.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          'Location',
          'http://${target.address.host}:${target.port}/object.bin',
        );
      await request.response.close();
    });

    target.listen((request) async {
      authorization = request.headers.value('Authorization');
      cookie = request.headers.value('Cookie');
      proxyAuthorization = request.headers.value('Proxy-Authorization');
      safeHeader = request.headers.value('X-Trace');
      request.response
        ..statusCode = HttpStatus.ok
        ..add([1]);
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${source.address.host}:${source.port}',
    );

    await client.read(
      '/download',
      headers: const {
        'Authorization': 'Bearer caller',
        'Cookie': 'sid=secret',
        'Proxy-Authorization': 'Basic proxy',
        'X-Trace': 'keep',
      },
    );

    expect(authorization, isNull);
    expect(cookie, isNull);
    expect(proxyAuthorization, isNull);
    expect(safeHeader, 'keep');
  });

  test('request converts 303 redirects to GET without body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? redirectedMethod;
    String? redirectedBody;

    server.listen((request) async {
      if (request.uri.path == '/submit') {
        await request.drain();
        request.response
          ..statusCode = HttpStatus.seeOther
          ..headers.set('Location', '/result');
      } else {
        redirectedMethod = request.method;
        redirectedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('done');
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.request<String>(
      'POST',
      target: '/submit',
      data: 'body',
      configure: (options) => options.responseType = ResponseType.plain,
    );

    expect(response.data, 'done');
    expect(redirectedMethod, 'GET');
    expect(redirectedBody, isEmpty);
  });

  test('request follows temporary redirects with Location header', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    var count = 0;
    server.listen((request) async {
      await request.drain();
      count++;
      if (request.uri.path == '/source') {
        request.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set('Location', '/target');
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'plain')
          ..write('target');
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.request<String>(
      'GET',
      target: '/source',
      configure: (options) => options.responseType = ResponseType.plain,
    );

    expect(response.data, 'target');
    expect(count, 2);
  });
}
