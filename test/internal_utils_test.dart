import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/hash_utils.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/src/internal/property_resolution.dart';
import 'package:webdav_client_plus/src/internal/xml_utils.dart';

void main() {
  group('parseStatusLine', () {
    test('reads the code of an HTTP status-line', () {
      expect(parseStatusLine('HTTP/1.1 200 OK'), 200);
      expect(parseStatusLine(' HTTP/2 404 '), 404);
      expect(parseStatusLine('HTTP/1.1 207'), 207);
    });

    test('rejects text that is not a status-line', () {
      expect(parseStatusLine('error 200'), isNull);
      expect(parseStatusLine('HTTP/1.1 4040'), isNull);
      expect(parseStatusLine('No-Code-Here'), isNull);
      expect(parseStatusLine(''), isNull);
    });
  });

  group('hash_utils', () {
    test('sha512Hash produces correct digest', () {
      final hash = sha512Hash('hello');
      expect(hash.length, 128);
      expect(
        hash,
        equals(
          '9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca7'
          '2323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043',
        ),
      );
    });

    test('computeNonce returns 16 character hex string', () {
      final nonce = computeNonce();
      expect(nonce.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(nonce), isTrue);
    });

    test('computeNonce returns different values', () {
      final a = computeNonce();
      final b = computeNonce();
      expect(a, isNot(equals(b)));
    });
  });

  group('path_utils edge cases', () {
    test('joinPath both empty returns /', () {
      expect(joinPath('', ''), '/');
    });

    test('resolveAgainstBaseUrl with empty target returns base', () {
      final result = resolveAgainstBaseUrl('http://localhost/a/b', '');
      expect(result, 'http://localhost/a/b');
    });

    test('resolveAgainstBaseUrl with network-path reference', () {
      final result =
          resolveAgainstBaseUrl('http://localhost/a', '//other.com/path');
      expect(result, 'http://other.com/path');
    });

    test('resolveAgainstBaseUrl with network-path and empty scheme', () {
      // scheme-less base + // prefix
      final result = resolveAgainstBaseUrl('localhost/a', '//other.com/path');
      expect(result, contains('//other.com/path'));
    });
  });

  group('property_resolution edge cases', () {
    test('empty property name throws', () {
      expect(
        () => resolvePropertyNames(['']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('property with trailing colon throws', () {
      expect(
        () => resolvePropertyNames(['d:']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Clark notation with empty namespace is treated as plain name', () {
      // `{}` doesn't match Clark regex (requires 1+ chars inside braces)
      // so it falls through to default prefix assignment
      final result = resolvePropertyNames(['{}localname']);
      expect(result.properties.first.namespaceUri, 'DAV:');
      expect(result.properties.first.qualifiedName, 'd:{}localname');
    });

    test('auto-assigns prefix for unknown Clark notation namespace', () {
      final result = resolvePropertyNames(['{http://custom.ns}myprop']);
      expect(result.properties.first.prefix, startsWith('ns'));
      expect(result.properties.first.qualifiedName, contains(':myprop'));
      expect(
        result.namespaces[result.properties.first.prefix],
        'http://custom.ns',
      );
    });

    test('empty namespace value in namespaceMap is ignored', () {
      final result = resolvePropertyNames(
        ['displayname'],
        namespaceMap: {'': ''},
      );
      expect(result.properties.first.qualifiedName, 'd:displayname');
    });
  });
}
