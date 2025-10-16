import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  test('propfind', () {
    final files = WebdavFile.parseFiles('/', _propFindRaw);
    expect(files.length, 1);
    final first = files[0];
    expect(first.path, '/test dir/README.md');
    expect(first.isDir, false);
    expect(first.name, 'README.md');
    expect(first.mimeType, null);
    expect(first.size, 3989);
    expect(first.eTag, null);
    expect(first.created, null);
    expect(first.modified, DateTime(2025, 3, 16, 1, 37, 28));
  });

  test('custom properties preserve nested and empty values', () {
    final files = WebdavFile.parseFiles('/', _customPropFindRaw);
    final entry = files.single;

    expect(
      entry.customProps['http://example.com/custom:meta'],
      equals('<custom:meta><custom:child>value</custom:child></custom:meta>'),
    );
    expect(
      entry.customProps['http://example.com/custom:empty'],
      isEmpty,
    );
    expect(
      entry.customProps['http://example.com/custom:label'],
      equals('<custom:label xml:lang="en">Hello</custom:label>'),
    );
  });
}

const _propFindRaw = '''
<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:">
<D:response>
<D:href>/test%20dir/README.md</D:href>
<D:propstat>
<D:prop>
<D:displayname>README.md</D:displayname>
<D:getcontentlength>3989</D:getcontentlength>
<D:getlastmodified>Sat, 15 Mar 2025 17:37:28 GMT</D:getlastmodified>
<D:resourcetype></D:resourcetype>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
</D:response>
</D:multistatus>
''';

const _customPropFindRaw = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:custom="http://example.com/custom">
  <d:response>
    <d:href>/data/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <custom:meta>
          <custom:child>value</custom:child>
        </custom:meta>
        <custom:empty/>
        <custom:label xml:lang="en">Hello</custom:label>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
