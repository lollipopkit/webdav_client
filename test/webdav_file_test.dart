import 'package:test/test.dart';
import 'package:webdav_client_plus/src/models/webdav_file.dart';

void main() {
  group('WebdavFile.parseFiles', () {
    test('parses file with all standard properties', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontenttype>text/plain</d:getcontenttype>
        <d:getetag>"abc123"</d:getetag>
        <d:getcontentlength>1024</d:getcontentlength>
        <d:creationdate>2024-01-15T10:30:00Z</d:creationdate>
        <d:getlastmodified>Mon, 15 Jan 2024 10:30:00 GMT</d:getlastmodified>
        <d:displayname>file.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml);
      expect(files.length, 1);
      final f = files.first;
      expect(f.name, 'file.txt');
      expect(f.path, '/dir/file.txt');
      expect(f.isDir, isFalse);
      expect(f.mimeType, 'text/plain');
      expect(f.eTag, '"abc123"');
      expect(f.size, 1024);
      expect(f.created, isNotNull);
      expect(f.modified, isNotNull);
      expect(f.modified!.isUtc, isFalse); // converted to local
    });

    test('parses collection with resourcetype', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/subdir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>subdir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml);
      expect(files.length, 1);
      expect(files.first.isDir, isTrue);
      expect(files.first.size, isNull);
    });

    test('skipSelf=false returns self entry', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.name, 'dir');
    });

    test('skipSelf=true filters collection self entry', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:displayname>dir</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dir/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>file.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml, skipSelf: true);
      expect(files.length, 1);
      expect(files.first.name, 'file.txt');
    });

    test('skipSelf matches a base URL path encoded differently', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/a%28b%29/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>https://example.com/remote.php/dav/a%28b%29/file.txt</d:href>
    <d:propstat>
      <d:prop><d:resourcetype/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles(
        'https://example.com/remote.php/dav/a(b)/',
        xml,
      );
      expect(files.map((f) => f.name), ['file.txt']);
    });

    test('skips response without href', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:propstat>
      <d:prop><d:displayname>no-href</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files, isEmpty);
    });

    test('skips response without successful propstat', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/fail.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname>fail</d:displayname></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files, isEmpty);
    });

    test('skips propstat without status element', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/no-status.txt</d:href>
    <d:propstat>
      <d:prop><d:displayname>no-status</d:displayname></d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files, isEmpty);
    });

    test('skips propstat without prop element', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/no-prop.txt</d:href>
    <d:propstat>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files, isEmpty);
    });

    test('falls back to path-based name when displayname absent', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/files/hidden.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.name, 'hidden.txt');
    });

    test('empty displayname falls back to path name', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/empty-name.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname></d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.name, 'empty-name.txt');
    });

    test('parses quota properties', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:quota-used-bytes>5000</d:quota-used-bytes>
        <d:quota-available-bytes>10000</d:quota-available-bytes>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.quotaUsedBytes, 5000);
      expect(files.first.quotaAvailableBytes, 10000);
    });

    test('parses custom properties', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/dir/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <oc:permissions>RDNVCK</oc:permissions>
        <oc:id>abc123</oc:id>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml);
      expect(files.length, 1);
      expect(files.first.customProps, contains('http://owncloud.org/ns:permissions'));
      expect(files.first.customProps['http://owncloud.org/ns:permissions'], 'RDNVCK');
      expect(files.first.customProps['http://owncloud.org/ns:id'], 'abc123');
    });

    test('parses custom properties with complex content as XML string', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/dir/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <nc:complex-prop key="val">inner</nc:complex-prop>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/dir/', xml);
      expect(files.length, 1);
      final val = files.first.customProps['http://nextcloud.org/ns:complex-prop'];
      expect(val, isNotNull);
      expect(val, contains('inner'));
    });

    test('parses RFC 4918 207 Multi-Status with non-standard propstat code', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dir/ok-file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>ok-file.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 207 Multi-Status</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      // 207 is in 200-300 range, should be parsed as successful
      final files = WebdavFile.parseFiles('/dir/', xml);
      expect(files.length, 1);
      expect(files.first.name, 'ok-file.txt');
    });

    test('parses URL-encoded href', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/files/hello%20world.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:displayname>hello world.txt</d:displayname>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.path, '/files/hello world.txt');
    });

    test('toString returns descriptive string', () {
      const f = WebdavFile(
        path: '/a.txt',
        isDir: false,
        name: 'a.txt',
        size: 100,
      );
      expect(f.toString(), contains('/a.txt'));
      expect(f.toString(), contains('a.txt'));
      expect(f.toString(), contains('100'));
    });

    test('trims numeric property values before parsing', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength> 123 </d:getcontentlength>
        <d:quota-used-bytes> 10 </d:quota-used-bytes>
        <d:quota-available-bytes> 90 </d:quota-available-bytes>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.single.size, 123);
      expect(files.single.quotaUsedBytes, 10);
      expect(files.single.quotaAvailableBytes, 90);
    });

    test('parses obsolete HTTP-date formats from getlastmodified', () {
      const rfc850Xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/rfc850.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getlastmodified>Sunday, 06-Nov-94 08:49:37 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      const asctimeXml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/asctime.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getlastmodified>Sun Nov  6 08:49:37 1994</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

      final rfc850 = WebdavFile.parseFiles('/', rfc850Xml, skipSelf: false);
      final asctime = WebdavFile.parseFiles('/', asctimeXml, skipSelf: false);

      expect(rfc850.single.modified, isNotNull);
      expect(asctime.single.modified, isNotNull);
    });

    test('handles invalid date gracefully', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/file.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:creationdate>not-a-date</d:creationdate>
        <d:getlastmodified>not-an-http-date</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final files = WebdavFile.parseFiles('/', xml, skipSelf: false);
      expect(files.length, 1);
      expect(files.first.created, isNull);
      expect(files.first.modified, isNull);
    });
  });
}
