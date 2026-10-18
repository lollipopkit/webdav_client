import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('report sends XML body with depth header', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? depth;
    String? contentType;
    String? body;

    server.listen((request) async {
      method = request.method;
      depth = request.headers.value('Depth');
      contentType = request.headers.contentType?.mimeType;
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.multiStatus
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<ok/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.report(
      '/calendars/user/',
      '<calendar-query/>',
      depth: PropsDepth.one,
    );

    expect(method, 'REPORT');
    expect(depth, '1');
    expect(contentType, 'application/xml');
    expect(body, '<calendar-query/>');
    expect(response.data, '<ok/>');
  });

  test('report can request byte responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      await request.drain();
      request.response
        ..statusCode = HttpStatus.ok
        ..add([1, 2, 3]);
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.report<List<int>>(
      '/report',
      '<report/>',
      responseType: ResponseType.bytes,
    );

    expect(response.data, [1, 2, 3]);
  });

  test('acl sends XML body without depth header', () async {
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
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<ok/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.acl('/resource', '<acl/>');

    expect(method, 'ACL');
    expect(depth, isNull);
    expect(body, '<acl/>');
    expect(response.data, '<ok/>');
  });

  test('search sends XML body and custom headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? method;
    String? depth;
    String? custom;
    String? body;

    server.listen((request) async {
      method = request.method;
      depth = request.headers.value('Depth');
      custom = request.headers.value('X-Search-Dialect');
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<result/>');
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final response = await client.search(
      '/',
      '<basicsearch/>',
      depth: PropsDepth.infinity,
      headers: const {'X-Search-Dialect': 'DAV:basicsearch'},
    );

    expect(method, 'SEARCH');
    expect(depth, 'infinity');
    expect(custom, 'DAV:basicsearch');
    expect(body, '<basicsearch/>');
    expect(response.data, '<result/>');
  });
}
