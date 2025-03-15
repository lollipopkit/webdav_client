import 'dart:convert';
import 'dart:math';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:webdav_client_plus/src/md5.dart';

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

  DigestParts digestParts;

  // Track nonce count for proper digest implementation
  int _nonceCount = 0;

  DigestAuth({
    required this.user,
    required this.pwd,
    required this.digestParts,
  });

  String? get nonce => this.digestParts.parts['nonce'];
  String? get realm => this.digestParts.parts['realm'];
  String? get qop => this.digestParts.parts['qop'];
  String? get opaque => this.digestParts.parts['opaque'];
  String? get algorithm => this.digestParts.parts['algorithm'];
  String? get entityBody => this.digestParts.parts['entityBody'];
  String? get charset => this.digestParts.parts['charset'];

  @override
  String authorize(String method, String path) {
    this.digestParts.uri = Uri.encodeFull(path);
    this.digestParts.method = method;
    return this._getDigestAuthorization();
  }

  String _getDigestAuthorization() {
    // Increment nonce count with each request using the same nonce
    _nonceCount++;

    // Format nonce count as 8 digit hex
    String nc = _nonceCount.toString().padLeft(8, '0');

    String cnonce = _computeNonce();
    String ha1 = _computeHA1(cnonce);
    String ha2 = _computeHA2();
    String response = _computeResponse(ha1, ha2, nc, cnonce);

    // Build authorization header according to RFC
    StringBuffer authHeader = StringBuffer('Digest');
    _addParam(authHeader, 'username', user);
    _addParam(authHeader, 'realm', realm);
    _addParam(authHeader, 'nonce', nonce);
    _addParam(authHeader, 'uri', digestParts.uri);
    _addParam(authHeader, 'response', response);

    if (algorithm?.isNotEmpty == true) {
      _addParam(authHeader, 'algorithm', algorithm, false);
    }

    final qop = this.qop;
    if (qop != null && qop.isNotEmpty) {
      // Choose auth over auth-int if both are offered
      String selectedQop = qop.contains('auth') ? 'auth' : qop;
      _addParam(authHeader, 'qop', selectedQop, false);
      _addParam(authHeader, 'nc', nc, false);
      _addParam(authHeader, 'cnonce', cnonce);
    }

    if (opaque?.isNotEmpty == true) {
      _addParam(authHeader, 'opaque', opaque);
    }

    if (charset?.isNotEmpty == true) {
      _addParam(authHeader, 'charset', charset, false);
    }

    return authHeader.toString().trim();
  }

  // Helper to add parameter to the authorization header
  void _addParam(StringBuffer sb, String name, String? value,
      [bool quote = true]) {
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
    String? alg = this.algorithm?.toLowerCase();

    if (alg == null || alg == 'md5' || alg == '') {
      return _md5Hash('$user:$realm:$pwd');
    } else if (alg == 'md5-sess') {
      String md5Str = _md5Hash('$user:$realm:$pwd');
      return _md5Hash('$md5Str:$nonce:$cnonce');
    } else if (alg == 'sha-256') {
      return _sha256Hash('$user:$realm:$pwd');
    } else if (alg == 'sha-256-sess') {
      String shaStr = _sha256Hash('$user:$realm:$pwd');
      return _sha256Hash('$shaStr:$nonce:$cnonce');
    }

    // Default to MD5 if algorithm not recognized
    return _md5Hash('$user:$realm:$pwd');
  }

  String _computeHA2() {
    String? qop = this.qop;

    if (qop == null || qop.isEmpty || qop == 'auth') {
      return _hashByAlgorithm(
          '${this.digestParts.method}:${this.digestParts.uri}');
    } else if (qop == 'auth-int' && this.entityBody?.isNotEmpty == true) {
      String bodyHash = _hashByAlgorithm(this.entityBody!);
      return _hashByAlgorithm(
          '${this.digestParts.method}:${this.digestParts.uri}:$bodyHash');
    }

    // Default to just method and URI
    return _hashByAlgorithm(
        '${this.digestParts.method}:${this.digestParts.uri}');
  }

  String _computeResponse(String ha1, String ha2, String nc, String cnonce) {
    String? qop = this.qop;

    if (qop == null || qop.isEmpty) {
      return _hashByAlgorithm('$ha1:$nonce:$ha2');
    } else {
      return _hashByAlgorithm('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
    }
  }

  String _hashByAlgorithm(String data) {
    String? alg = this.algorithm?.toLowerCase();

    if (alg != null && (alg.startsWith('sha-256') || alg == 'sha256')) {
      return _sha256Hash(data);
    }

    // Default to MD5
    return _md5Hash(data);
  }

  String _sha256Hash(String data) {
    var bytes = utf8.encode(data);
    var digest = crypto.sha256.convert(bytes);
    return digest.toString();
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

  void _parseAuthHeader(String headerData) {
    // Handle quoted strings with possible escaped quotes
    bool inQuotes = false;
    bool escaped = false;
    StringBuffer currentParam = StringBuffer();
    StringBuffer currentValue = StringBuffer();
    bool collectingName = true;
    String currentName = '';

    for (int i = 0; i < headerData.length; i++) {
      String char = headerData[i];

      if (escaped) {
        if (collectingName) {
          currentParam.write(char);
        } else {
          currentValue.write(char);
        }
        escaped = false;
        continue;
      }

      if (char == '\\') {
        escaped = true;
        continue;
      }

      if (char == '"') {
        inQuotes = !inQuotes;
        if (!collectingName) {
          // Don't include the quotes in the value
          continue;
        }
      }

      if (!inQuotes && char == '=') {
        collectingName = false;
        currentName = currentParam.toString().trim();
        currentParam.clear();
        continue;
      }

      if (!inQuotes && (char == ',' || i == headerData.length - 1)) {
        // If this is the last character, include it
        if (i == headerData.length - 1 && char != ',') {
          if (collectingName) {
            currentParam.write(char);
          } else {
            currentValue.write(char);
          }
        }

        // End of a parameter
        if (!collectingName && currentName.isNotEmpty) {
          String value = currentValue.toString().trim();
          parts[currentName.toLowerCase()] = value;
        }

        // Reset for next parameter
        collectingName = true;
        currentName = '';
        currentParam.clear();
        currentValue.clear();
        continue;
      }

      // Add character to current buffer
      if (collectingName) {
        currentParam.write(char);
      } else {
        currentValue.write(char);
      }
    }
  }
}

String _md5Hash(String data) {
  final hasher = new MD5()..add(Utf8Encoder().convert(data));
  var bytes = hasher.close();
  var result = new StringBuffer();
  for (var part in bytes) {
    result.write('${part < 16 ? '0' : ''}${part.toRadixString(16)}');
  }
  return result.toString();
}

String _computeNonce() {
  final rnd = Random.secure();
  final values = List<int>.generate(16, (i) => rnd.nextInt(256));
  return hex.encode(values).substring(0, 16);
}
