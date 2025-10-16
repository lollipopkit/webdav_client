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

  test('propfind accepts other successful propstat codes', () {
    final files = WebdavFile.parseFiles('/', _propFind204);
    expect(files.single.name, 'no-content.txt');
  });

  test('custom properties preserve nested and empty values', () {
    final files = WebdavFile.parseFiles('/', _customPropFindRaw);
    final entry = files.single;

    final metaValue = entry.customProps['http://example.com/custom:meta'];
    expect(
      _normalizeXml(metaValue),
      equals(_normalizeXml(
          '<custom:meta><custom:child>value</custom:child></custom:meta>')),
    );
    expect(
      entry.customProps['http://example.com/custom:empty'],
      isEmpty,
    );
    final labelValue = entry.customProps['http://example.com/custom:label'];
    expect(
      _normalizeXml(labelValue),
      equals(_normalizeXml('<custom:label xml:lang="en">Hello</custom:label>')),
    );
  });

  test('parseFiles skips collection self entry regardless of response order',
      () {
    final files = WebdavFile.parseFiles('/collection/', _collectionOutOfOrder);
    expect(
      files.map((file) => file.path).toList(),
      equals(['/collection/item.txt']),
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

const _propFind204 = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/test%20dir/no-content.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>no-content.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 204 No Content</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
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

const _collectionOutOfOrder = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/collection/item.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>item.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/collection/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype>
          <d:collection/>
        </d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

String _normalizeXml(String? xml) {
  if (xml == null) return '';
  return xml.replaceAll(RegExp(r'>\s+<'), '><').trim();
}
