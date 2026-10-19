import 'dart:io';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// Elements from other namespaces that share a DAV: local name must be
/// ignored.
void main() {
  late HttpServer server;
  late String body;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain();
      request.response.statusCode = request.method == 'LOCK' ? 200 : 207;
      request.response.headers.contentType = ContentType('application', 'xml');
      request.response.write(body);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  WebdavClient client() =>
      WebdavClient.noAuth(url: 'http://${server.address.host}:${server.port}');

  String propResponse(String prop) =>
      '''
<d:multistatus xmlns:d="DAV:" xmlns:x="urn:x">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>$prop</d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

  test('supportedReports reads DAV:supported-report/DAV:report', () async {
    body = propResponse('''
<d:supported-report-set>
  <x:report><x:bogus/></x:report>
  <d:supported-report>
    <x:report><x:bogus/></x:report>
    <d:report><d:expand-property/></d:report>
  </d:supported-report>
</d:supported-report-set>''');

    expect(await client().supportedReports(), ['d:expand-property']);
  });

  test('supportedLiveProperties unwraps DAV:name and DAV:prop', () async {
    body = propResponse('''
<d:supported-live-property-set>
  <x:supported-live-property><x:bogus/></x:supported-live-property>
  <d:supported-live-property><d:name><d:comment/></d:name></d:supported-live-property>
  <d:supported-live-property><d:prop><d:getetag/></d:prop></d:supported-live-property>
  <d:supported-live-property><x:name><x:custom/></x:name></d:supported-live-property>
</d:supported-live-property-set>''');

    expect(await client().supportedLiveProperties(), [
      'd:comment',
      'd:getetag',
      'x:name',
    ]);
  });

  test('ACL helpers read only DAV: children', () async {
    body = propResponse('''
<d:acl>
  <x:ace/>
  <d:ace><d:principal><d:all/></d:principal></d:ace>
</d:acl>
<d:current-user-privilege-set>
  <x:privilege><x:bogus/></x:privilege>
  <d:privilege><d:read/></d:privilege>
</d:current-user-privilege-set>
<d:supported-method-set>
  <x:supported-method name="BOGUS"/>
  <d:supported-method name="GET"/>
</d:supported-method-set>''');

    expect(await client().accessControlList(), hasLength(1));
    expect(await client().currentUserPrivilegeSet(), ['d:read']);
    expect(await client().supportedMethods(), ['GET']);
  });

  test('lock reads the token from DAV:locktoken', () async {
    body = '''
<d:prop xmlns:d="DAV:" xmlns:x="urn:x">
  <d:lockdiscovery>
    <d:activelock>
      <x:locktoken><d:href>opaquelocktoken:bogus</d:href></x:locktoken>
      <d:locktoken><d:href>opaquelocktoken:real</d:href></d:locktoken>
    </d:activelock>
  </d:lockdiscovery>
</d:prop>''';

    expect(await client().lock('/file.txt'), 'opaquelocktoken:real');
  });

  test('207 errors match only DAV: preconditions', () {
    WebdavException<String> error(String xml) => WebdavException.fromResponse(
      Response<String>(
        requestOptions: RequestOptions(),
        statusCode: 207,
        data: xml,
      ),
    );

    expect(
      error(
        '<d:error xmlns:d="DAV:"><d:no-conflicting-lock/></d:error>',
      ).message,
      'The resource has a conflicting lock',
    );
    expect(
      error(
        '<d:error xmlns:d="DAV:" xmlns:x="urn:x">'
        '<x:no-conflicting-lock/></d:error>',
      ).message,
      isNot('The resource has a conflicting lock'),
    );
  });
}
