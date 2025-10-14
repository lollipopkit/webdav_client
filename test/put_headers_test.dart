import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:webdav_client_plus/src/client.dart';

void main() {
  group('buildPutHeaders', () {
    test('sets defaults for content-length and content-type', () {
      final headers = buildPutHeaders(contentLength: 128);

      expect(headers[Headers.contentLengthHeader], equals('128'));
      expect(headers[Headers.contentTypeHeader],
          equals('application/octet-stream'));
    });

    test('allows callers to override defaults case-insensitively', () {
      final headers = buildPutHeaders(
        contentLength: 256,
        additionalHeaders: {
          'Content-Type': 'text/plain',
          'If-Match': '"etag"',
        },
      );

      expect(headers[Headers.contentLengthHeader], equals('256'));
      expect(headers[Headers.contentTypeHeader], equals('text/plain'));
      expect(headers['If-Match'], equals('"etag"'));
    });
  });
}
