import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

void main() {
  group('NoAuth', () {
    test('authorize returns null', () {
      const auth = NoAuth();
      expect(auth.authorize('GET', '/path'), isNull);
    });

    test('is const', () {
      const a = NoAuth();
      const b = NoAuth();
      expect(identical(a, b), isTrue);
    });
  });

  group('BasicAuth', () {
    test('produces correct base64 header', () {
      const auth = BasicAuth(user: 'admin', pwd: 'secret');
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Basic '));
      expect(result, 'Basic YWRtaW46c2VjcmV0');
    });

    test('handles special characters', () {
      const auth = BasicAuth(user: 'user@domain', pwd: 'p@ss:w0rd!');
      final result = auth.authorize('PUT', '/file');
      expect(result, startsWith('Basic '));
    });

    test('consistent across methods and paths', () {
      const auth = BasicAuth(user: 'u', pwd: 'p');
      final a = auth.authorize('GET', '/a');
      final b = auth.authorize('PUT', '/b');
      expect(a, equals(b));
    });
  });

  group('BearerAuth', () {
    test('produces correct bearer header', () {
      const auth = BearerAuth(token: 'my-jwt-token');
      expect(auth.authorize('GET', '/'), 'Bearer my-jwt-token');
    });

    test('consistent across methods', () {
      const auth = BearerAuth(token: 'tok');
      expect(auth.authorize('GET', '/'), equals(auth.authorize('POST', '/')));
    });
  });

  group('DigestAuth', () {
    test('parses digest parts from WWW-Authenticate header', () {
      const header =
          'Digest realm="test@example.com", nonce="abc123", qop="auth", '
          'opaque="xyz789", algorithm=MD5, charset=UTF-8';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'test@example.com');
      expect(parts.parts['nonce'], 'abc123');
      expect(parts.parts['qop'], 'auth');
      expect(parts.parts['opaque'], 'xyz789');
      expect(parts.parts['algorithm'], 'MD5');
      expect(parts.parts['charset'], 'UTF-8');
    });

    test('DigestParts without Digest prefix', () {
      const header = 'realm="test", nonce="abc"';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'test');
      expect(parts.parts['nonce'], 'abc');
    });

    test('DigestParts with null header', () {
      final parts = DigestParts(null);
      expect(parts.parts['nonce'], '');
      expect(parts.parts['realm'], '');
    });

    test('DigestParts toString', () {
      final parts = DigestParts('realm="test", nonce="abc"');
      final str = parts.toString();
      expect(str, contains('DigestParts'));
      expect(str, contains('test'));
    });

    test('properties delegate to parts map', () {
      const header = 'realm="r", nonce="n", qop="auth", opaque="o", algorithm=md5';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      expect(auth.realm, 'r');
      expect(auth.nonce, 'n');
      expect(auth.qop, 'auth');
      expect(auth.opaque, 'o');
      expect(auth.algorithm, 'md5');
      expect(auth.charset, '');
      expect(auth.userhash, '');
    });

    test('MD5 digest auth produces correct response', () {
      const header = 'realm="testrealm", nonce="testnonce", qop="auth"';
      final parts = DigestParts(header);
      final auth = DigestAuth(
        user: 'admin',
        pwd: 'password',
        digestParts: parts,
      );
      final result = auth.authorize('GET', '/dir/');
      expect(result, startsWith('Digest'));
      expect(result, contains('username="admin"'));
      expect(result, contains('realm="testrealm"'));
      expect(result, contains('nonce="testnonce"'));
      expect(result, contains('uri="/dir/"'));
      expect(result, contains('response="'));
      expect(result, contains('qop=auth'));
      expect(result, contains('nc='));
      expect(result, contains('cnonce="'));
    });

    test('quoted authorization parameters are escaped', () {
      const header = r'realm="quoted\realm", nonce="n\"q"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: r'u"\name', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');

      expect(result, contains(r'username="u\"\\name"'));
      // Per RFC 7616 §3.2.2, \r in a quoted string is an escape of "r"
      // which yields literal "r" (only \\ and \" are special within
      // the quoted-string grammar). So `quoted\realm` → parsed value
      // `quotedrealm`, which when escaped for the Authorization header
      // contains no backslashes to double.
      expect(result, contains(r'realm="quotedrealm"'));
      expect(result, contains(r'nonce="n\"q"'));
    });

    test('MD5 digest without qop', () {
      const header = 'realm="testrealm", nonce="testnonce"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('response="'));
      // no qop/nc/cnonce
      expect(result, isNot(contains('qop=')));
    });

    test('MD5-sess algorithm', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=MD5-sess';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('algorithm=MD5-sess'));
    });

    test('SHA-256 algorithm', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=SHA-256';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('algorithm=SHA-256'));
    });

    test('SHA-256-sess algorithm', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=SHA-256-sess';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('algorithm=SHA-256-sess'));
    });

    test('SHA-512 algorithm via _hashByAlgorithm', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=SHA-512';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('algorithm=SHA-512'));
    });

    test('SHA-512-256 variant via _hashByAlgorithm', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=SHA-512-256';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      final values = _parseDigestAuthorization(result);

      String h(String value) =>
          crypto.sha512256.convert(utf8.encode(value)).toString();
      final ha1 = h('u:r:p');
      final ha2 = h('GET:/');
      final expected = h(
        '$ha1:n:${values['nc']}:${values['cnonce']}:auth:$ha2',
      );

      expect(result, startsWith('Digest'));
      expect(values['algorithm'], 'SHA-512-256');
      expect(values['response'], expected);
    });

    test('SHA-512-256-sess hashes HA1 with the session algorithm', () {
      const header =
          'realm="r", nonce="n", qop="auth", algorithm=SHA-512-256-sess';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      final values = _parseDigestAuthorization(result);

      String h(String value) =>
          crypto.sha512256.convert(utf8.encode(value)).toString();
      final baseHa1 = h('u:r:p');
      final ha1 = h('$baseHa1:n:${values['cnonce']}');
      final ha2 = h('GET:/');
      final expected = h(
        '$ha1:n:${values['nc']}:${values['cnonce']}:auth:$ha2',
      );

      expect(values['algorithm'], 'SHA-512-256-sess');
      expect(values['response'], expected);
    });

    test('auth-int qop with entityBody', () {
      const header = 'realm="r", nonce="n", qop="auth-int"';
      final parts = DigestParts(header);
      parts.parts['entityBody'] = 'request-body-hash';
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('PUT', '/file');
      expect(result, startsWith('Digest'));
      expect(result, contains('qop=auth-int'));
    });

    test('qop option list uses selected token in response hash', () {
      const header = 'realm="r", nonce="n", qop="Auth,Auth-Int"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/resource');
      final values = _parseDigestAuthorization(result);

      final ha1 = _md5('u:r:p');
      final ha2 = _md5('GET:/resource');
      final expected = _md5(
        '$ha1:n:${values['nc']}:${values['cnonce']}:auth:$ha2',
      );

      expect(values['qop'], 'auth');
      expect(values['response'], expected);
    });

    test('auth-int qop without entityBody hashes an empty entity body', () {
      const header = 'realm="r", nonce="n", qop="auth-int"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      final values = _parseDigestAuthorization(result);

      final ha1 = _md5('u:r:p');
      final emptyBodyHash = _md5('');
      final ha2 = _md5('GET:/:$emptyBodyHash');
      final expected = _md5(
        '$ha1:n:${values['nc']}:${values['cnonce']}:auth-int:$ha2',
      );

      expect(values['qop'], 'auth-int');
      expect(values['response'], expected);
    });

    test('unrecognized algorithm defaults to MD5', () {
      const header = 'realm="r", nonce="n", qop="auth", algorithm=UNKNOWN';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      expect(result, contains('algorithm=UNKNOWN'));
    });

    test('empty algorithm defaults to MD5', () {
      const header = 'realm="r", nonce="n", algorithm=""';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, startsWith('Digest'));
      // empty algorithm should not be included
      expect(result, isNot(contains('algorithm=')));
    });

    test('nonce count increments', () {
      const header = 'realm="r", nonce="n", qop="auth"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final r1 = auth.authorize('GET', '/a');
      expect(r1, contains('nc=00000001'));
      final r2 = auth.authorize('GET', '/b');
      expect(r2, contains('nc=00000002'));
    });

    test('opaque is included in response', () {
      const header = 'realm="r", nonce="n", qop="auth", opaque="abcdef"';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, contains('opaque="abcdef"'));
    });

    test('charset is included when present', () {
      const header = 'realm="r", nonce="n", qop="auth", charset=UTF-8';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, contains('charset=UTF-8'));
    });

    test('userhash hashes username per RFC 7616', () {
      const header = 'realm="r", nonce="n", qop="auth", userhash=true';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      final values = _parseDigestAuthorization(result);

      expect(values['username'], _md5('u:r'));
      expect(values['userhash'], 'true');
    });

    test('empty opaque and charset are not included', () {
      const header = 'realm="r", nonce="n", qop="auth", opaque="", charset=""';
      final parts = DigestParts(header);
      final auth = DigestAuth(user: 'u', pwd: 'p', digestParts: parts);
      final result = auth.authorize('GET', '/');
      expect(result, isNot(contains('opaque=')));
      expect(result, isNot(contains('charset=')));
    });
  });

  group('DigestParts header parsing', () {
    test('parses unquoted values', () {
      const header = 'realm=test, nonce=abc123, qop=auth';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'test');
      expect(parts.parts['nonce'], 'abc123');
      expect(parts.parts['qop'], 'auth');
    });

    test('parses mixed quoted and unquoted', () {
      const header = 'realm="quoted realm", nonce=unquoted, algorithm=MD5';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'quoted realm');
      expect(parts.parts['nonce'], 'unquoted');
      expect(parts.parts['algorithm'], 'MD5');
    });

    test('parses quoted commas and escaped quoted-pairs', () {
      const header =
          r'realm="example, inc.", nonce="abc\"123", opaque="a\\b"';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'example, inc.');
      expect(parts.parts['nonce'], 'abc"123');
      expect(parts.parts['opaque'], r'a\b');
    });

    test('handles Digest prefix case-insensitively', () {
      const header = 'DIGEST realm="test", nonce="abc"';
      final parts = DigestParts(header);
      expect(parts.parts['realm'], 'test');
    });

    test('empty header creates default parts', () {
      final parts = DigestParts('');
      expect(parts.parts['nonce'], '');
      expect(parts.parts['realm'], '');
    });
  });
}

String _md5(String value) => crypto.md5.convert(utf8.encode(value)).toString();

Map<String, String> _parseDigestAuthorization(String header) {
  final values = <String, String>{};
  final payload = header.replaceFirst(RegExp(r'^Digest\s+'), '');
  final regex = RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]+))');
  for (final match in regex.allMatches(payload)) {
    values[match.group(1)!] = match.group(2) ?? match.group(3) ?? '';
  }
  return values;
}
