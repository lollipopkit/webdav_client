import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:xml/xml.dart';

String _multiStatus(String responses, {String ns = ''}) => '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:"$ns>$responses</d:multistatus>
''';

String _response(String href, String props) => '''
<d:response>
  <d:href>$href</d:href>
  <d:propstat>
    <d:prop>$props</d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
</d:response>''';

String _toPath(String href) => decodeHref(href.trim());

void main() {
  group('href decoding', () {
    test('keeps an href that is not valid percent-encoding', () {
      final xml = _multiStatus(_response('/50%.txt', '<d:resourcetype/>'));
      expect(WebdavFile.parseFiles(xml, _toPath).single.path, '/50%.txt');
      expect(parseMultiStatus(xml).single.href, '/50%.txt');
    });

    test('decodes exactly once', () {
      final xml = _multiStatus(
        _response('/dav/x%2541.txt', '<d:resourcetype/>') +
            _response('/dav/50%25.txt', '<d:resourcetype/>'),
      );
      final files = WebdavFile.parseFiles(xml, _toPath);
      expect(files.map((f) => f.path), ['/dav/x%41.txt', '/dav/50%.txt']);
      expect(files.map((f) => f.name), ['x%41.txt', '50%.txt']);
      expect(parseMultiStatus(xml).first.href, '/dav/x%41.txt');
    });

    test('keeps raw non-ASCII text and decodes escapes beside it', () {
      final xml = _multiStatus(
        _response('/dav/文件.txt', '<d:resourcetype/>') +
            _response('/dav/文件%20a%E2%82%AC.txt', '<d:resourcetype/>') +
            _response('/dav/😀%41', '<d:resourcetype/>'),
      );
      expect(WebdavFile.parseFiles(xml, _toPath).map((f) => f.path), [
        '/dav/文件.txt',
        '/dav/文件 a€.txt',
        '/dav/😀A',
      ]);
      expect(parseMultiStatus(xml).first.href, '/dav/文件.txt');
    });

    test('keeps escapes that are not UTF-8', () {
      expect(decodeHref('/dav/%FF.txt'), '/dav/%FF.txt');
      expect(decodeHref('/dav/plain'), '/dav/plain');
    });

    test('trims surrounding whitespace', () {
      final xml = _multiStatus(_response('\n  /dav/f\n', '<d:resourcetype/>'));
      final file = WebdavFile.parseFiles(xml, _toPath).single;
      expect(file.path, '/dav/f');
      expect(file.name, 'f');
      expect(parseMultiStatus(xml).single.href, '/dav/f');
    });
  });

  test('ignores response elements nested inside property values', () {
    final xml = _multiStatus(
      _response(
        '/dav/real',
        '<x:log>${_response('/dav/ghost', '').replaceAll('d:response', 'x:response')}</x:log>',
      ),
      ns: ' xmlns:x="urn:x"',
    );
    expect(WebdavFile.parseFiles(xml, _toPath).map((f) => f.path), ['/dav/real']);
    expect(parseMultiStatus(xml).map((r) => r.href), ['/dav/real']);
  });

  group('WebdavFile.parse', () {
    test('reads well-known properties from the DAV: namespace only', () {
      final xml = _multiStatus(
        _response(
          '/dav/f.txt',
          '<x:displayname>custom</x:displayname>'
              '<d:displayname>real</d:displayname>'
              '<d:resourcetype><x:collection/></d:resourcetype>'
              '<d:getcontentlength>5</d:getcontentlength>',
        ),
        ns: ' xmlns:x="urn:x"',
      );
      final file = WebdavFile.parseFiles(xml, _toPath).single;
      expect(file.name, 'real');
      expect(file.isDir, isFalse);
      expect(file.size, 5);
      expect(file.customProps['urn:x:displayname'], 'custom');
    });

    test('parses creationdate variants', () {
      DateTime? created(String value) => WebdavFile.parseFiles(
            _multiStatus(_response(
              '/f',
              '<d:creationdate>$value</d:creationdate>',
            )),
            _toPath,
          ).single.created?.toUtc();

      final expected = DateTime.utc(2024, 1, 15, 10, 30);
      expect(created('2024-01-15T10:30:00Z'), expected);
      expect(created('2024-01-15t10:30:00z'), expected);
      expect(created('Mon, 15 Jan 2024 10:30:00 GMT'), expected);
      expect(created('2024-02-30T10:00:00Z'), isNull);
      expect(created('2024-01-15T24:00:00Z'), isNull);
      expect(
        created('2016-12-31T23:59:60Z'),
        DateTime.utc(2017),
      );
      expect(created('2016-12-31T23:59:61Z'), isNull);
      expect(created('20240115'), isNull);
      expect(created('2024-01-15 10:30'), isNull);
    });

    test('reads two-digit RFC 850 years per RFC 9110 §5.6.7', () {
      int? year(String yy) => WebdavFile.parseFiles(
            _multiStatus(_response(
              '/f',
              '<d:getlastmodified>Sunday, 01-Jan-$yy 00:00:00 GMT</d:getlastmodified>',
            )),
            _toPath,
          ).single.modified?.toUtc().year;

      final now = DateTime.now().toUtc().year;
      final century = now - now % 100;
      expect(year('${now % 100}'.padLeft(2, '0')), now);
      final future = (now + 60) % 100;
      expect(year('$future'.padLeft(2, '0')), century + future - 100);
    });
  });

  test('response-level fields come from the DAV: namespace only', () {
    final response = parseMultiStatus(_multiStatus(
      '''
<d:response>
  <d:href>/dav/f</d:href>
  <x:status>HTTP/1.1 500 Internal Server Error</x:status>
  <x:responsedescription>foreign</x:responsedescription>
  <d:status>HTTP/1.1 200 OK</d:status>
</d:response>''',
      ns: ' xmlns:x="urn:x"',
    )).single;
    expect(response.statusCode, 200);
    expect(response.responseDescription, isNull);
  });

  test('absolute URLs are recognised whatever the scheme case', () {
    expect(
      resolveAgainstBaseUrl('http://h/dav/', 'HTTP://other/x'),
      'http://other/x',
    );
  });

  group('missing or invalid status counts as a failure', () {
    test('in a propstat', () {
      final failures = parsePropPatchFailureMessages(_multiStatus('''
<d:response>
  <d:href>/dav/f</d:href>
  <d:propstat><d:prop><d:displayname/></d:prop></d:propstat>
  <d:propstat>
    <d:prop><d:getetag/></d:prop>
    <d:status>bogus</d:status>
  </d:propstat>
</d:response>'''));
      expect(failures, hasLength(2));
      expect(failures[0], contains('missing status'));
      expect(failures[1], contains('invalid status "bogus"'));
    });

    test('in a response without propstats', () {
      final failures = parseMultiStatusFailureMessages(_multiStatus('''
<d:response><d:href>/dav/a</d:href></d:response>
<d:response>
  <d:href>/dav/b</d:href>
  <d:status>HTTP/1.1 204 No Content</d:status>
</d:response>'''));
      expect(failures.single, 'Failed to process /dav/a: missing status');
    });
  });

  test('PROPPATCH reports response-level failures', () {
    final failures = parsePropPatchFailureMessages(_multiStatus('''
<d:response>
  <d:href>/dav/f</d:href>
  <d:status>HTTP/1.1 423 Locked</d:status>
</d:response>'''));
    expect(failures.single, contains('423'));
  });

  group('against a server', () {
    late HttpServer server;
    late WebdavClient client;
    late List<String> bodies;
    late String Function(HttpRequest) reply;

    setUp(() async {
      bodies = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        bodies.add(await utf8.decoder.bind(request).join());
        final body = reply(request);
        request.response
          ..statusCode = request.method == 'LOCK' ? 200 : 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write(body);
        await request.response.close();
      });
      client = WebdavClient.noAuth(url: 'http://127.0.0.1:${server.port}/dav');
    });

    tearDown(() => server.close(force: true));

    test('propFind matches the target under a base path at Depth 1', () async {
      reply = (_) => _multiStatus(
            _response('/dav/dir/', '<d:displayname>dir</d:displayname>') +
                _response('/dav/dir/a', '<d:displayname>a</d:displayname>'),
          );
      final client = WebdavClient.noAuth(
        url: 'http://127.0.0.1:${server.port}/dav',
        options: const WebdavOptions(pathMode: PathMode.legacy),
      );
      for (final path in ['/dir', '/dir/', '/dav/dir']) {
        final props = await client.propFind(path, depth: PropsDepth.one);
        expect(props['{DAV:}displayname']?.innerText, 'dir', reason: path);
      }
    });

    test('propFind tells an encoded % apart from its decoded form', () async {
      reply = (_) => _multiStatus(
            _response('/dav/a%20b', '<d:displayname>space</d:displayname>') +
                _response(
                  '/dav/a%2520b',
                  '<d:displayname>percent</d:displayname>',
                ),
          );
      final client = WebdavClient.noAuth(
        url: 'http://127.0.0.1:${server.port}/dav',
        options: const WebdavOptions(pathMode: PathMode.legacy),
      );
      final props = await client.propFind('/a%2520b', depth: PropsDepth.one);
      expect(props['{DAV:}displayname']?.innerText, 'percent');
    });

    test('propFind ignores an absolute href on another origin', () async {
      reply = (_) => _multiStatus(
            _response('http://other.invalid/dav/dir/', '<d:displayname/>') +
                _response(
                  'HTTP://127.0.0.1:${server.port}/dav/dir/',
                  '<d:displayname>dir</d:displayname>',
                ),
          );
      final props = await client.propFind('/dir', depth: PropsDepth.one);
      expect(props['{DAV:}displayname']?.innerText, 'dir');

      reply = (_) => _multiStatus(
            _response('http://other.invalid/dav/dir/', '<d:displayname/>'),
          );
      expect(await client.propFind('/dir'), isEmpty);
    });

    test('propFind ignores a sole entry for another resource', () async {
      reply = (_) => _multiStatus(
            _response('/dav/other', '<d:displayname>other</d:displayname>'),
          );
      expect(await client.propFind('/dir'), isEmpty);
    });

    test('modifyProps gives set and remove namespaces distinct prefixes',
        () async {
      reply = (_) => _multiStatus('');
      await client.modifyProps(
        '/f',
        setProps: {'{urn:a}x': '1'},
        removeProps: ['{urn:b}y'],
      );
      final doc = XmlDocument.parse(bodies.single);
      final set = doc.findAllElements('x', namespaceUri: 'urn:a');
      final remove = doc.findAllElements('y', namespaceUri: 'urn:b');
      expect(set, hasLength(1));
      expect(remove, hasLength(1));
    });

    test('setProps throws on a response-level failure', () async {
      reply = (_) => _multiStatus('''
<d:response>
  <d:href>/dav/f</d:href>
  <d:status>HTTP/1.1 423 Locked</d:status>
</d:response>''');
      expect(
        client.setProps('/f', {'d:displayname': 'x'}),
        throwsA(isA<WebdavException>()),
      );
    });

    group('a 207 whose root is not DAV:multistatus', () {
      setUp(() => reply = (_) => '<x:other xmlns:x="urn:x"/>');

      test('fails COPY instead of reporting success', () async {
        await expectLater(
          client.copy('/a', '/b'),
          throwsA(isA<WebdavException>().having(
            (e) => e.message,
            'message',
            contains('Expected a DAV:multistatus root'),
          )),
        );
      });

      test('fails readDir instead of listing nothing', () async {
        await expectLater(
          client.readDir('/'),
          throwsA(isA<WebdavException>()),
        );
      });
    });

    test('COPY fails on a Multi-Status naming no member', () async {
      // RFC 4918 §9.8.5: a COPY 207 reports errors that stopped the copy.
      reply = (_) => _multiStatus('');
      await expectLater(
        client.copy('/a', '/b'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('COPY reported Multi-Status without any member'),
        )),
      );
    });

    group('Depth 0 responses listing other resources', () {
      setUp(() => reply = (_) => _multiStatus(
            _response(
              '/dav/other',
              '<d:quota-used-bytes>1</d:quota-used-bytes>'
                  '<d:quota-available-bytes>1</d:quota-available-bytes>',
            ) +
                _response(
                  '/dav/',
                  '<d:quota-used-bytes>5</d:quota-used-bytes>'
                      '<d:quota-available-bytes>7</d:quota-available-bytes>',
                ),
          ));

      test('readProps returns the requested resource', () async {
        final file = await client.readProps('/');
        expect(file?.path, '/');
      });

      test('quotaBytes reads the requested resource', () async {
        expect(await client.quotaBytes(), (5, 7));
      });
    });

    test('lock reports a malformed body as WebdavException', () async {
      reply = (_) => 'not-xml';
      await expectLater(
        client.lock('/f'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('Unable to parse LOCK response'),
        )),
      );
    });

    test('lock trims a token read from the body', () async {
      reply = (_) => '''
<?xml version="1.0" encoding="utf-8"?>
<d:prop xmlns:d="DAV:"><d:lockdiscovery><d:activelock>
  <d:locktoken>
    <d:href>
      urn:uuid:abc
    </d:href>
  </d:locktoken>
</d:activelock></d:lockdiscovery></d:prop>''';
      expect(await client.lock('/f'), 'urn:uuid:abc');
    });
  });
}
