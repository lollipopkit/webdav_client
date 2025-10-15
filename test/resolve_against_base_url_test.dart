import 'package:test/test.dart';
import 'package:webdav_client_plus/src/utils.dart';

void main() {
  group('resolveAgainstBaseUrl', () {
    const base =
        'https://example.com/remote.php/dav/files/alice'; // trailing slash intentionally absent

    test('handles relative paths by appending to base', () {
      final resolved = resolveAgainstBaseUrl(base, 'Documents/report.txt');
      expect(
        resolved,
        equals(
            'https://example.com/remote.php/dav/files/alice/Documents/report.txt'),
      );
    });

    test('treats leading slash paths as relative to base collection', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        '/shared/notes.txt',
      );
      expect(
        resolved,
        equals(
          'https://example.com/remote.php/dav/files/alice/shared/notes.txt',
        ),
      );
    });

    test('returns absolute URIs verbatim after normalization', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        'https://cdn.example.org/storage/Media%20Library/video.mp4',
      );
      expect(
        resolved,
        equals('https://cdn.example.org/storage/Media%20Library/video.mp4'),
      );
    });

    test('avoids duplicating base path for collection-qualified targets', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        '/remote.php/dav/files/alice/target.txt',
      );
      expect(
        resolved,
        equals(
          'https://example.com/remote.php/dav/files/alice/target.txt',
        ),
      );
    });

    test('retains query strings supplied with absolute paths', () {
      final resolved = resolveAgainstBaseUrl(
        '$base/',
        '/file.txt?download=1',
      );
      expect(
        resolved,
        equals(
          'https://example.com/remote.php/dav/files/alice/file.txt?download=1',
        ),
      );
    });
  });
}
