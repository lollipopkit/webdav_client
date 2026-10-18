import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:xml/xml.dart';

void main() {
  late HttpServer server;
  late WebdavClient client;
  late List<HttpHeaders> headers;
  late List<String> bodies;

  setUp(() async {
    headers = [];
    bodies = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      headers.add(request.headers);
      bodies.add(await utf8.decoder.bind(request).join());
      if (request.method == 'LOCK') {
        request.response.headers.set('Lock-Token', '<urn:x-lock:abc>');
      } else {
        request.response.statusCode = 207;
      }
      await request.response.close();
    });
    client = WebdavClient.noAuth(url: 'http://127.0.0.1:${server.port}');
  });

  tearDown(() => server.close(force: true));

  test('refreshLock accepts any absolute URI as a lock token', () async {
    expect(await client.refreshLock('/f', 'urn:x-lock:abc'), 'urn:x-lock:abc');
    expect(headers.single.value('if'), contains('(<urn:x-lock:abc>)'));
  });

  test('lock refresh skips Not conditions in the If header', () async {
    final token = await client.lock(
      '/f',
      refreshLock: true,
      ifHeader: '(Not <urn:x-lock:old> <urn:x-lock:abc>)',
    );
    expect(token, 'urn:x-lock:abc');
  });

  test('basicSearch wraps the query in DAV:searchrequest', () async {
    await client.basicSearch<String>(
      '/',
      '<d:select><d:prop><d:displayname/></d:prop></d:select>',
    );
    final root = XmlDocument.parse(bodies.single).rootElement;
    expect(root.name.local, 'searchrequest');
    expect(root.namespaceUri, 'DAV:');
    expect(root.getElement('basicsearch', namespaceUri: 'DAV:'), isNotNull);
  });
}
