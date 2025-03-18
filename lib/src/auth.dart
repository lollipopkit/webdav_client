import 'dart:convert';
import 'package:webdav_client_plus/src/utils.dart';

/// Auth for WebDAV client
sealed class Auth {
  const Auth();

  /// Get authorization data
  String? authorize(String method, String path) => null;
}

/// NoAuth - No authentication
class NoAuth extends Auth {
  const NoAuth();

  @override
  String? authorize(String method, String path) => null;
}

final class BasicAuth extends Auth {
  final String user;
  final String pwd;

  const BasicAuth({
    required this.user,
    required this.pwd,
  });

  @override
  String authorize(String method, String path) {
    List<int> bytes = utf8.encode('$user:$pwd');
    return 'Basic ${base64Encode(bytes)}';
  }
}

final class BearerAuth extends Auth {
  final String token;

  const BearerAuth({
    required this.token,
  });

  @override
  String authorize(String method, String path) {
    return 'Bearer $token';
  }
}

final class DigestAuth extends Auth {
  final String user;
  final String pwd;

  final DigestParts digestParts;

  // Track nonce count for proper digest implementation
  int _nonceCount = 0;

  DigestAuth({
    required this.user,
    required this.pwd,
    required this.digestParts,
  });

  String? get nonce => digestParts.parts['nonce'];
  String? get realm => digestParts.parts['realm'];
  String? get qop => digestParts.parts['qop'];
  String? get opaque => digestParts.parts['opaque'];
  String? get algorithm => digestParts.parts['algorithm'];
  String? get entityBody => digestParts.parts['entityBody'];
  String? get charset => digestParts.parts['charset'];

  @override
  String authorize(String method, String path) {
    digestParts.uri = Uri.encodeFull(path);
    digestParts.method = method;
    return _getDigestAuthorization();
  }

  String _getDigestAuthorization() {
    // Increment nonce count with each request using the same nonce
    _nonceCount++;

    // Format nonce count as 8 digit hex
    final nc = _nonceCount.toString().padLeft(8, '0');

    final cnonce = computeNonce();
    final ha1 = _computeHA1(cnonce);
    final ha2 = _computeHA2();
    final response = _computeResponse(ha1, ha2, nc, cnonce);

    // Build authorization header according to RFC
    final authHeader = StringBuffer('Digest');
    _addParam(authHeader, 'username', user);
    _addParam(authHeader, 'realm', realm);
    _addParam(authHeader, 'nonce', nonce);
    _addParam(authHeader, 'uri', digestParts.uri);
    _addParam(authHeader, 'response', response);

    if (algorithm?.isNotEmpty == true) {
      _addParam(authHeader, 'algorithm', algorithm, quote: false);
    }

    final qop = this.qop;
    if (qop != null && qop.isNotEmpty) {
      // Choose auth over auth-int if both are offered
      String selectedQop = qop.contains('auth') ? 'auth' : qop;
      _addParam(authHeader, 'qop', selectedQop, quote: false);
      _addParam(authHeader, 'nc', nc, quote: false);
      _addParam(authHeader, 'cnonce', cnonce);
    }

    if (opaque?.isNotEmpty == true) {
      _addParam(authHeader, 'opaque', opaque);
    }

    if (charset?.isNotEmpty == true) {
      _addParam(authHeader, 'charset', charset, quote: false);
    }

    return authHeader.toString().trim();
  }

  // Helper to add parameter to the authorization header
  void _addParam(
    StringBuffer sb,
    String name,
    String? value, {
    bool quote = true,
  }) {
    if (value == null || value.isEmpty) return;

    if (sb.length > 7) {
      // "Digest " is 7 chars
      sb.write(', ');
    } else {
      sb.write(' ');
    }

    sb.write('$name=');
    if (quote) sb.write('"');
    sb.write(value);
    if (quote) sb.write('"');
  }

  String _computeHA1(String cnonce) {
    final alg = algorithm?.toLowerCase();

    if (alg == null || alg == 'md5' || alg == '') {
      return md5Hash('$user:$realm:$pwd');
    } else if (alg == 'md5-sess') {
      String md5Str = md5Hash('$user:$realm:$pwd');
      return md5Hash('$md5Str:$nonce:$cnonce');
    } else if (alg == 'sha-256') {
      return sha256Hash('$user:$realm:$pwd');
    } else if (alg == 'sha-256-sess') {
      final shaStr = sha256Hash('$user:$realm:$pwd');
      return sha256Hash('$shaStr:$nonce:$cnonce');
    }

    // Default to MD5 if algorithm not recognized
    return md5Hash('$user:$realm:$pwd');
  }

  String _computeHA2() {
    final qop = this.qop;

    if (qop == null || qop.isEmpty || qop == 'auth') {
      return _hashByAlgorithm('${digestParts.method}:${digestParts.uri}');
    } else if (qop == 'auth-int' && entityBody?.isNotEmpty == true) {
      final bodyHash = _hashByAlgorithm(entityBody!);
      return _hashByAlgorithm(
          '${digestParts.method}:${digestParts.uri}:$bodyHash');
    }

    // Default to just method and URI
    return _hashByAlgorithm('${digestParts.method}:${digestParts.uri}');
  }

  String _computeResponse(String ha1, String ha2, String nc, String cnonce) {
    final qop = this.qop;

    if (qop == null || qop.isEmpty) {
      return _hashByAlgorithm('$ha1:$nonce:$ha2');
    } else {
      return _hashByAlgorithm('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
    }
  }

  String _hashByAlgorithm(String data) {
    final alg = algorithm?.toLowerCase();

    if (alg != null) {
      if (alg.startsWith('sha-512') || alg == 'sha512') {
        return sha512Hash(data);
      } else if (alg.startsWith('sha-256') || alg == 'sha256') {
        return sha256Hash(data);
      }
    }

    return md5Hash(data);
  }
}

/// DigestParts
class DigestParts {
  DigestParts(String? authHeader) {
    if (authHeader != null) {
      // First, extract the authentication scheme
      String headerData = authHeader;
      if (authHeader.toLowerCase().startsWith('digest')) {
        headerData = authHeader.substring(6).trim();
      }

      // RFC compliant parsing
      _parseAuthHeader(headerData);
    }
  }

  String uri = '';
  String method = '';

  Map<String, String> parts = {
    'nonce': '',
    'realm': '',
    'qop': '',
    'opaque': '',
    'algorithm': '',
    'entityBody': '',
    'charset': '',
  };

  static final headerRegex = RegExp(
    r'(\w+)=(?:"([^"]*)"|([^,]*))',
    caseSensitive: false,
  );
  void _parseAuthHeader(String headerData) {
    final matches = headerRegex.allMatches(headerData);

    for (final match in matches) {
      final key = match.group(1)!.toLowerCase();
      final value = match.group(2) ?? match.group(3) ?? '';
      parts[key] = value.trim();
    }
  }
}
