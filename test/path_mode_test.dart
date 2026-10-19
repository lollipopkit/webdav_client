import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _base = 'https://example.com/remote.php/dav/files/alice';

String _resolve(String target) =>
    resolveTarget(_base, target, PathMode.baseRelative);

void main() {
  group('resolveTarget in baseRelative mode', () {
    test('treats paths with and without a leading slash alike', () {
      const expected = '$_base/remote.php/a.txt';
      expect(_resolve('/remote.php/a.txt'), expected);
      expect(_resolve('remote.php/a.txt'), expected);
    });

    test('encodes every character of a segment', () {
      expect(_resolve('/50%/a b?#ü.txt'), '$_base/50%25/a%20b%3F%23%C3%BC.txt');
    });

    test('maps the base to its collection URL', () {
      expect(_resolve(''), '$_base/');
      expect(_resolve('/'), '$_base/');
    });

    test('keeps a trailing slash and resolves dot segments', () {
      expect(_resolve('/a/./b/../c/'), '$_base/a/c/');
      expect(_resolve('/a/b/..'), '$_base/a/');
    });

    test('rejects paths above the base', () {
      expect(() => _resolve('/..'), throwsArgumentError);
      expect(() => _resolve('a/../../bob'), throwsArgumentError);
    });

    test('passes absolute URLs through', () {
      expect(
        _resolve('https://cdn.example.org/a%20b'),
        'https://cdn.example.org/a%20b',
      );
    });
  });

  group('hrefToTarget', () {
    test('decodes hrefs inside the base', () {
      expect(
        hrefToTarget(_base, '/remote.php/dav/files/alice/50%25/a%20b/'),
        '/50%/a b/',
      );
      expect(hrefToTarget(_base, '/remote.php/dav/files/alice'), '/');
      expect(hrefToTarget(_base, '$_base/x'), '/x');
    });

    test('keeps the URL for hrefs a path cannot express', () {
      expect(
        hrefToTarget(_base, '/remote.php/dav/principals/alice/'),
        'https://example.com/remote.php/dav/principals/alice/',
      );
      expect(
        hrefToTarget(_base, 'https://other.example.com/remote.php/dav/'),
        'https://other.example.com/remote.php/dav/',
      );
      expect(
        hrefToTarget(_base, '/remote.php/dav/files/alice/a%2Fb'),
        '$_base/a%2Fb',
      );
      expect(
        hrefToTarget(_base, '/remote.php/dav/files/alice/%FF'),
        '$_base/%FF',
      );
    });

    test('treats a URL without a path as the server root', () {
      expect(hrefToTarget('https://example.com', 'https://example.com'), '/');
      expect(hrefToTarget(_base, 'https://example.com'), 'https://example.com');
    });

    test('resolves relative hrefs against the request URL', () {
      expect(
        hrefToTarget(_base, 'b.txt', requestUrl: '$_base/dir/'),
        '/dir/b.txt',
      );
    });

    test('round-trips through resolveTarget', () {
      for (final path in ['/a b/', '/50%', '/q?x#y', '/ü/€.txt']) {
        expect(hrefToTarget(_base, _resolve(path)), path);
      }
      for (final href in ['$_base/a%2Fb', 'https://example.com/x']) {
        expect(hrefToTarget(_base, _resolve(href)), href);
      }
    });
  });

  group('client in baseRelative mode', () {
    late HttpServer server;
    late List<String> requests;
    late List<String> requestBodies;
    late String Function(HttpRequest request) body;
    late int Function(HttpRequest request) status;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requests = <String>[];
      requestBodies = <String>[];
      status = (_) => 207;
      server.listen((request) async {
        requests.add('${request.method} ${request.uri}');
        requestBodies.add(await utf8.decoder.bind(request).join());
        request.response.statusCode = status(request);
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write(body(request));
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    WebdavClient client() => WebdavClient.noAuth(
      url: 'http://${server.address.host}:${server.port}/dav/alice',
    );

    String multistatus(List<(String, String)> entries) =>
        '''
<d:multistatus xmlns:d="DAV:">
${entries.map((e) => '''
  <d:response>
    <d:href>${e.$1}</d:href>
    <d:propstat>
      <d:prop>${e.$2}</d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>''').join()}
</d:multistatus>''';

    test(
      'readDir reports base-relative paths that can be passed back',
      () async {
        body = (_) => multistatus([
          (
            '/dav/alice/50%25%20done/',
            '<d:resourcetype><d:collection/></d:resourcetype>',
          ),
          ('/dav/alice/50%25%20done/a%23b.txt', '<d:resourcetype/>'),
        ]);

        final files = await client().readDir('/50% done');

        expect(files.map((f) => f.path), ['/50% done/a#b.txt']);
        expect(files.single.name, 'a#b.txt');

        body = (_) => multistatus([
          ('/dav/alice/50%25%20done/a%23b.txt', '<d:resourcetype/>'),
        ]);
        final file = await client().readProps(files.single.path);

        expect(file?.path, '/50% done/a#b.txt');
        expect(requests.last, 'PROPFIND /dav/alice/50%25%20done/a%23b.txt');
      },
    );

    test('discovery helpers report hrefs outside the base as URLs', () async {
      body = (_) => multistatus([
        (
          '/dav/alice/',
          '<d:current-user-principal><d:href>/principals/alice/</d:href>'
              '</d:current-user-principal>',
        ),
      ]);

      expect(
        await client().currentUserPrincipal(),
        'http://${server.address.host}:${server.port}/principals/alice/',
      );
    });

    test('mkdirAll creates missing collections inside the base only', () async {
      body = (_) => '';
      status = (request) => requests.length == 1 ? 409 : 201;

      await client().mkdirAll('/a b/c');

      expect(requests, [
        'MKCOL /dav/alice/a%20b/c/',
        'MKCOL /dav/alice/a%20b/',
        'MKCOL /dav/alice/a%20b/c/',
      ]);
    });

    test('rejects paths above the base before sending a request', () async {
      body = (_) => '';
      await expectLater(client().read('/../bob/secret'), throwsArgumentError);
      expect(requests, isEmpty);
    });

    test('reports malformed hrefs as WebdavException', () async {
      const bad = 'http://[bad/x';
      body = (_) => multistatus([
        (
          '/dav/alice/',
          '<d:current-user-principal><d:href>$bad</d:href>'
              '</d:current-user-principal>',
        ),
        (bad, '<d:resourcetype/>'),
      ]);

      await expectLater(client().readDir('/'), throwsA(isA<WebdavException>()));
      await expectLater(
        client().currentUserPrincipal(),
        throwsA(isA<WebdavException>()),
      );
    });

    test('bind sends the source path as an absolute URL', () async {
      body = (_) => '';
      status = (_) => 201;

      await client().bind('/dir', segment: 'alias', href: '/a b.txt');

      expect(requests.single, 'BIND /dav/alice/dir');
      expect(
        requestBodies.single,
        contains(
          '<d:href>http://${server.address.host}:${server.port}'
          '/dav/alice/a%20b.txt</d:href>',
        ),
      );
    });
  });
}
