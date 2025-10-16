import 'package:test/test.dart';
import 'package:webdav_client_plus/src/client/client.dart';
import 'package:xml/xml.dart';

void main() {
  group('parseMultiStatus', () {
    test('captures propstat properties with status codes', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/ok.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag"</d:getetag>
        <oc:permissions>RDNVW</oc:permissions>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final responses = parseMultiStatus(xml);
      expect(responses, hasLength(1));

      final response = responses.single;
      expect(response.href, '/ok.txt');
      expect(response.statusCode, isNull);
      expect(response.propstats, hasLength(1));

      final propstat = response.propstats.single;
      expect(propstat.statusCode, 200);
      expect(
        propstat.properties['{DAV:}getetag']?.innerText,
        '"etag"',
      );
      expect(
        propstat.properties['{http://owncloud.org/ns}permissions']?.innerText,
        'RDNVW',
      );
    });

    test('captures top-level failure statuses without propstat blocks', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/missing.txt</d:href>
    <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:response>
</d:multistatus>
''';

      final responses = parseMultiStatus(xml);
      expect(responses, hasLength(1));

      final response = responses.single;
      expect(response.href, '/missing.txt');
      expect(response.statusCode, 404);
      expect(response.rawStatus, contains('404'));
      expect(response.propstats, isEmpty);
    });

    test('captures DAV error metadata and location hints', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/locked.txt</d:href>
    <d:status>HTTP/1.1 423 Locked</d:status>
    <d:error>
      <d:lock-token-submitted/>
    </d:error>
    <d:responsedescription>The resource is currently locked.</d:responsedescription>
    <d:location>
      <d:href>/locks/info</d:href>
    </d:location>
  </d:response>
</d:multistatus>
''';

      final responses = parseMultiStatus(xml);
      final response = responses.single;
      expect(response.error, isNotNull);
      expect(
          response.error!.findElements('lock-token-submitted', namespace: '*'),
          isNotEmpty);
      expect(response.responseDescription, 'The resource is currently locked.');
      expect(response.locationHref, '/locks/info');
    });
  });

  group('parseMultiStatusToMap', () {
    test('indexes properties by href and status code', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/doc.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag"</d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final map = parseMultiStatusToMap(xml);
      expect(map.keys, contains('/doc.txt'));
      final props = map['/doc.txt']![200]!;
      expect(props['{DAV:}getetag']?.innerText, '"etag"');
    });

    test('captures overall statuses without propstat blocks', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/deleted.txt</d:href>
    <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:response>
</d:multistatus>
''';

      final map = parseMultiStatusToMap(xml);
      expect(map['/deleted.txt']![404], isEmpty);
    });
  });
}
