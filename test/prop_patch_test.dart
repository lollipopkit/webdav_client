import 'package:test/test.dart';
import 'package:webdav_client_plus/src/client.dart';

void main() {
  group('parsePropPatchFailureMessages', () {
    test('returns empty list when all propstat entries succeed', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/ok.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag"</d:getetag>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, isEmpty);
    });

    test('captures failing propstat entries for diagnostics', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/failed.txt</d:href>
    <d:propstat>
      <d:prop>
        <custom:prop xmlns:custom="http://example.com/custom"/>
      </d:prop>
      <d:status>HTTP/1.1 423 Locked</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final failures = parsePropPatchFailureMessages(xml);
      expect(failures, hasLength(1));
      expect(
        failures.single,
        contains('Failed to update properties for /failed.txt'),
      );
      expect(failures.single, contains('423 Locked'));
      expect(failures.single, contains('custom:prop'));
    });
  });
}
