import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  group('WebdavException.fromResponse', () {
    Response<T> makeResponse<T>(
      int? code, {
      String? message,
      T? data,
    }) {
      return Response<T>(
        statusCode: code,
        statusMessage: message,
        data: data,
        requestOptions: RequestOptions(path: '/test'),
      );
    }

    test('generic error without message', () {
      final resp = makeResponse<String>(500, message: 'Server Error');
      final e = WebdavException.fromResponse(resp);
      expect(e.statusCode, 500);
      expect(e.message, 'WebDAV operation failed');
      expect(e.response, resp);
    });

    test('generic error with custom message', () {
      final resp = makeResponse<String>(500);
      final e = WebdavException.fromResponse(resp, 'Custom msg');
      expect(e.message, 'Custom msg');
    });

    test('207 Multi-Status with lock-token-submitted error', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/locked</d:href>
    <d:status>HTTP/1.1 423 Locked</d:status>
    <d:error><d:lock-token-submitted/></d:error>
  </d:response>
</d:multistatus>
''';
      final resp = makeResponse<String>(207, data: xml);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('lock token'));
    });

    test('207 Multi-Status with no-conflicting-lock error', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/conflict</d:href>
    <d:error><d:no-conflicting-lock/></d:error>
  </d:response>
</d:multistatus>
''';
      final resp = makeResponse<String>(207, data: xml);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('conflicting lock'));
    });

    test('207 Multi-Status with generic error element', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/fail</d:href>
    <d:error><d:valid-resourcetype/></d:error>
  </d:response>
</d:multistatus>
''';
      final resp = makeResponse<String>(207, data: xml);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('MultiStatus error'));
      expect(e.message, contains('d:valid-resourcetype'));
    });

    test('207 Multi-Status without error elements', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/ok</d:href>
    <d:propstat>
      <d:prop><d:displayname>ok</d:displayname></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final resp = makeResponse<String>(207, data: xml);
      final e = WebdavException.fromResponse(resp);
      // No error element or failure status → uses generic message
      expect(e.message, 'WebDAV operation failed');
    });

    test('207 Multi-Status propstat failures are surfaced', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/fail</d:href>
    <d:propstat>
      <d:prop><d:displayname /></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';
      final resp = makeResponse<String>(207, data: xml);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('/fail'));
      expect(e.message, contains('403 Forbidden'));
    });

    test('207 Multi-Status with invalid XML falls back', () {
      final resp = makeResponse<String>(207, data: 'not-xml');
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Multi-Status response with errors');
    });

    test('207 Multi-Status with non-String data', () {
      final resp = makeResponse<int>(207, data: 42);
      final e = WebdavException.fromResponse(resp);
      expect(e.statusCode, 207);
    });

    test('422 Unprocessable Entity', () {
      final resp = makeResponse<void>(422);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('Unprocessable Entity'));
    });

    test('423 Locked', () {
      final resp = makeResponse<void>(423);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Resource is locked');
    });

    test('424 Failed Dependency', () {
      final resp = makeResponse<void>(424);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('Failed dependency'));
    });

    test('507 Insufficient Storage', () {
      final resp = makeResponse<void>(507);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Insufficient storage');
    });

    test('508 Loop Detected', () {
      final resp = makeResponse<void>(508);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('Loop detected'));
    });

    test('401 Authentication required', () {
      final resp = makeResponse<void>(401);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Authentication required');
    });

    test('403 Access forbidden', () {
      final resp = makeResponse<void>(403);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Access forbidden');
    });

    test('404 Resource not found', () {
      final resp = makeResponse<void>(404);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, 'Resource not found');
    });

    test('409 Conflict', () {
      final resp = makeResponse<void>(409);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('Conflict'));
    });

    test('412 Precondition failed', () {
      final resp = makeResponse<void>(412);
      final e = WebdavException.fromResponse(resp);
      expect(e.message, contains('Precondition failed'));
    });
  });

  group('WebdavException.toString', () {
    test('includes message, status and data', () {
      final resp = Response<String>(
        statusCode: 404,
        statusMessage: 'Not Found',
        data: 'missing file',
        requestOptions: RequestOptions(path: '/test'),
      );
      final e = WebdavException(
        message: 'Test error',
        statusCode: 404,
        statusMessage: 'Not Found',
        response: resp,
      );
      final str = e.toString();
      expect(str, contains('Test error'));
      expect(str, contains('404'));
      expect(str, contains('Not Found'));
      expect(str, contains('missing file'));
    });

    test('handles null fields', () {
      final e = WebdavException(message: 'No details');
      final str = e.toString();
      expect(str, contains('unknown'));
    });
  });
}
