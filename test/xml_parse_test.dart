import 'package:test/test.dart';
import 'package:webdav_client/src/xml.dart';

void main() {
  test('propfind', () {
    final files = WebdavXml.toFiles('/', _propFindRaw);
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