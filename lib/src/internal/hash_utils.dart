import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Compute an MD5 hash for [data] and return the lowercase hex digest.
String md5Hash(String data) {
  final digest = crypto.md5.convert(utf8.encode(data));
  return hex.encode(digest.bytes);
}

/// Compute a SHA-256 hash for [data] and return the lowercase hex digest.
String sha256Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha256.convert(bytes);
  return digest.toString();
}

/// Compute a SHA-512 hash for [data] and return the lowercase hex digest.
String sha512Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha512.convert(bytes);
  return digest.toString();
}

/// Produce a cryptographically secure nonce for Digest authentication.
String computeNonce() {
  final rnd = Random.secure();
  final values = List<int>.generate(16, (i) => rnd.nextInt(256));
  return hex.encode(values).substring(0, 16);
}
