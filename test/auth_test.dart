import 'package:test/test.dart';
import 'package:webdav_client_plus/src/utils.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  group('NoAuth', () {
    test('null', () {
      const auth = NoAuth();
      expect(auth.authorize('GET', '/path'), isNull);
    });
  });

  group('BasicAuth', () {
    test('normal', () {
      const auth = BasicAuth(user: 'username', pwd: 'password');
      final authHeader = auth.authorize('GET', '/path');
      expect(authHeader, 'Basic dXNlcm5hbWU6cGFzc3dvcmQ=');
    });

    test('special', () {
      const auth = BasicAuth(user: 'user:name', pwd: 'pass@word');
      final authHeader = auth.authorize('GET', '/path');
      expect(authHeader, 'Basic dXNlcjpuYW1lOnBhc3NAd29yZA==');
    });
  });

  group('BearerAuth', () {
    test('normal', () {
      const auth = BearerAuth(token: 'abc123token');
      final authHeader = auth.authorize('GET', '/path');
      expect(authHeader, 'Bearer abc123token');
    });
  });

  group('DigestAuth', () {
    test('parse', () {
      const authHeader = 'Digest '
          'realm="testrealm@host.com", '
          'qop="auth,auth-int", '
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
          'opaque="5ccc069c403ebaf9f0171e9517f40e41"';

      final parts = DigestParts(authHeader);

      expect(parts.parts['realm'], 'testrealm@host.com');
      expect(parts.parts['qop'], 'auth,auth-int');
      expect(parts.parts['nonce'], 'dcd98b7102dd2f0e8b11d0f600bfb0c093');
      expect(parts.parts['opaque'], '5ccc069c403ebaf9f0171e9517f40e41');
    });

    test('md5', () {
      const authHeader = 'Digest '
          'realm="testrealm@host.com", '
          'qop="auth", '
          'algorithm=MD5, '
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
          'opaque="5ccc069c403ebaf9f0171e9517f40e41"';

      final parts = DigestParts(authHeader);
      final auth = DigestAuth(
        user: 'Mufasa',
        pwd: 'Circle of Life',
        digestParts: parts,
      );

      final response = auth.authorize('GET', '/dir/index.html');

      expect(response, contains('Digest'));
      expect(response, contains('username="Mufasa"'));
      expect(response, contains('realm="testrealm@host.com"'));
      expect(response, contains('uri="/dir/index.html"'));
      expect(response, contains('algorithm=MD5'));
      expect(response, contains('qop=auth'));
      expect(response, contains('nc=00000001'));
      expect(response, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
    });

    test('nonce count', () {
      const authHeader = 'Digest '
          'realm="testrealm@host.com", '
          'qop="auth", '
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"';

      final parts = DigestParts(authHeader);
      final auth = DigestAuth(
        user: 'user',
        pwd: 'password',
        digestParts: parts,
      );

      final response1 = auth.authorize('GET', '/path');
      final response2 = auth.authorize('GET', '/path');

      expect(response1, contains('nc=00000001'));
      expect(response2, contains('nc=00000002'));
    });

    test('diff http', () {
      const authHeader = 'Digest '
          'realm="testrealm@host.com", '
          'qop="auth", '
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"';

      final parts = DigestParts(authHeader);
      final auth = DigestAuth(
        user: 'user',
        pwd: 'password',
        digestParts: parts,
      );

      final getResponse = auth.authorize('GET', '/path');
      final postResponse = auth.authorize('POST', '/path');

      expect(getResponse, isNot(equals(postResponse)));
    });

    test('empty or malformed', () {
      final emptyParts = DigestParts(null);
      expect(emptyParts.parts['nonce'], '');
      expect(emptyParts.parts['realm'], '');

      final malformedParts = DigestParts('Digest invalid format');
      expect(malformedParts.parts['nonce'], '');
    });
  });

  group('Utility functions', () {
    test('_md5Hash should produce correct hash', () {
      expect(md5Hash('test'), '098f6bcd4621d373cade4e832627b4f6');
    });

    test('_sha256Hash should produce correct hash', () {
      expect(
        sha256Hash('test'),
        '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      );
    });

    test('_computeNonce should return 16 characters', () {
      final nonce = computeNonce();
      expect(nonce.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(nonce), isTrue);
    });
  });
}
