import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;

String joinPath(String path0, String path1) {
  while (path0.isNotEmpty && path0.endsWith('/')) {
    path0 = path0.substring(0, path0.length - 1);
  }

  while (path1.isNotEmpty && path1.startsWith('/')) {
    path1 = path1.substring(1);
  }

  if (path0.isEmpty && path1.isEmpty) {
    return '/';
  }

  return path0.isEmpty
      ? '/$path1'
      : path1.isEmpty
          ? '$path0/'
          : '$path0/$path1';
}


String md5Hash(String data) {
  final digest = crypto.md5.convert(utf8.encode(data));
  return hex.encode(digest.bytes);
}

String sha256Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha256.convert(bytes);
  return digest.toString();
}

String sha512Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha512.convert(bytes);
  return digest.toString();
}

String computeNonce() {
  final rnd = Random.secure();
  final values = List<int>.generate(16, (i) => rnd.nextInt(256));
  return hex.encode(values).substring(0, 16);
}
