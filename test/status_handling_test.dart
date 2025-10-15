import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('ping accepts any successful 2xx response from OPTIONS', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'OPTIONS' && request.uri.path == '/') {
        request.response.statusCode = HttpStatus.noContent;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await expectLater(client.ping(), completes);
  });

  test('options returns DAV capabilities advertised by server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'OPTIONS' && request.uri.path == '/') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set('DAV', '1, 3, access-control')
          ..headers.set('Allow', 'OPTIONS, PROPFIND');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final features = await client.options();
    expect(features, equals(['1', '3', 'access-control']));
  });

  test('request helper reuses base URL and forwards headers/body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? capturedPath;
    String? capturedDepth;
    String? capturedBody;

    server.listen((request) async {
      if (request.method == 'REPORT') {
        capturedPath = request.uri.path;
        capturedDepth = request.headers.value('depth');
        capturedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write('<ok/>');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}/remote.php/dav/files/alice',
    );

    final response = await client.request<String>(
      'REPORT',
      target: '/reports/activity',
      headers: {'Depth': '1'},
      data: '<request/>',
      configure: (options) => options.responseType = ResponseType.plain,
    );

    expect(response.data, '<ok/>');
    expect(capturedPath, '/remote.php/dav/files/alice/reports/activity');
    expect(capturedDepth, '1');
    expect(capturedBody, '<request/>');
  });

  test('PROPFIND tolerates HTTP 200 responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'PROPFIND' && request.uri.path == '/propfind-200') {
        await request.drain();
        const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/propfind-200</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>propfind-200</d:displayname>
        <d:getetag>"12345"</d:getetag>
        <d:getcontentlength>5</d:getcontentlength>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    final props = await client.readProps('/propfind-200');
    expect(props, isNotNull);
    expect(props!.name, 'propfind-200');
    expect(props.eTag, '"12345"');
  });

  test('PROPPATCH accepts 204 No Content success responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'PROPPATCH' &&
          request.uri.path == '/proppatch-204') {
        await request.drain();
        request.response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'PROPFIND' &&
          request.uri.path == '/proppatch-204') {
        // Some clients might verify properties after setting them.
        await request.drain();
        const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/proppatch-204</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Updated</d:displayname>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await expectLater(
      client.setProps('/proppatch-204', {'d:displayname': 'Updated'}),
      completes,
    );
  });

  test('COPY surfaces 4xx statuses reported via Multi-Status', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'COPY' && request.uri.path == '/locked-source') {
        await request.drain();
        const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/locked-dest</d:href>
    <d:status>HTTP/1.1 423 Locked</d:status>
  </d:response>
</d:multistatus>
''';
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await expectLater(
      () => client.copy('/locked-source', '/locked-dest'),
      throwsA(
        isA<WebdavException>().having(
          (error) => error.message,
          'message',
          contains('423'),
        ),
      ),
    );
  });

  test('DELETE surfaces member failures from Multi-Status responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    server.listen((request) async {
      if (request.method == 'DELETE' &&
          request.uri.path == '/broken-folder/') {
        await request.drain();
        const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/broken-folder/file.txt</d:href>
    <d:status>HTTP/1.1 423 Locked</d:status>
  </d:response>
</d:multistatus>
''';
        request.response
          ..statusCode = 207
          ..headers.contentType =
              ContentType('application', 'xml', charset: 'utf-8')
          ..write(body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    await expectLater(
      () => client.removeAll('/broken-folder/'),
      throwsA(
        isA<WebdavException>().having(
          (error) => error.message,
          'message',
          contains('423'),
        ),
      ),
    );
  });

  test('COPY reuses caller-provided absolute Destination URIs verbatim',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? capturedDestination;
    server.listen((request) async {
      if (request.method == 'COPY') {
        capturedDestination = request.headers.value('destination');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final authority = 'http://${server.address.host}:${server.port}';
    final client = WebdavClient.noAuth(
      url: '$authority/remote.php/dav/files/alice',
    );

    final absoluteDest = '$authority/external/library/asset.txt';
    await client.copy('/source.txt', absoluteDest);

    expect(capturedDestination, absoluteDest);
  });

  test('COPY resolves absolute-path Destinations against the base authority',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? capturedDestination;
    server.listen((request) async {
      if (request.method == 'COPY') {
        capturedDestination = request.headers.value('destination');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final authority = 'http://${server.address.host}:${server.port}';
    final client = WebdavClient.noAuth(
      url: '$authority/remote.php/dav/files/alice',
    );

    const absolutePath = '/remote.php/dav/files/alice/target.txt';
    await client.copy('/source.txt', absolutePath);

    expect(
      capturedDestination,
      '$authority$absolutePath',
    );
  });

  test('COPY forwards custom If headers for lock tokens', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? capturedIfHeader;
    server.listen((request) async {
      if (request.method == 'COPY') {
        capturedIfHeader = request.headers.value('if');
        await request.drain();
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}',
    );

    const ifHeader =
        '<http://example.com/destination> (<opaquelocktoken:1234>)';
    await client.copy('/source.txt', '/destination.txt', ifHeader: ifHeader);

    expect(capturedIfHeader, equals(ifHeader));
  });

  test('DELETE forwards custom If headers for lock tokens', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => server.close(force: true));

    String? capturedIfHeader;
    server.listen((request) async {
      if (request.method == 'DELETE' && request.uri.path == '/locked.txt') {
        capturedIfHeader = request.headers.value('if');
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

    const ifHeader = '<http://example.com/locked.txt> (<opaquelocktoken:abcd>)';
    await client.remove('/locked.txt', ifHeader: ifHeader);

    expect(capturedIfHeader, equals(ifHeader));
  });
}
