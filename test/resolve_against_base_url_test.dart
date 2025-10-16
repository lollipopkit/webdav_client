import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';

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

    test(
        'keeps leading slash paths within the collection prefix per RFC 4918 §8.3',
        () {
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

    test('resolves "/" to the same collection prefix with trailing slash', () {
      final resolved = resolveAgainstBaseUrl(base, '/');
      expect(
        resolved,
        equals('https://example.com/remote.php/dav/files/alice/'),
      );
    });

    test('falls back to provided absolute path when prefix mismatches', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        '/remote.php/dav/files/bob/doc.txt',
      );
      expect(
        resolved,
        equals('https://example.com/remote.php/dav/files/bob/doc.txt'),
      );
    });

    test('normalizes dot segments while preserving base prefix', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        '../Archive/../docs/report.txt',
      );
      expect(
        resolved,
        equals(
          'https://example.com/remote.php/dav/files/docs/report.txt',
        ),
      );
    });

    test('adopts network-path references with base scheme', () {
      final resolved = resolveAgainstBaseUrl(
        base,
        '//cdn.example.org/assets/logo.png',
      );
      expect(
        resolved,
        equals('https://cdn.example.org/assets/logo.png'),
      );
    });
  });
}
