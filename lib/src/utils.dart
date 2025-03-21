import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

/// XML

List<XmlElement> findAllElements(XmlDocument document, String tag) =>
    document.findAllElements(tag, namespace: '*').toList();

List<XmlElement> findElements(XmlElement element, String tag) =>
    element.findElements(tag, namespace: '*').toList();

/// Extract a string value from the first matching element
String? getElementText(XmlElement parent, String tag) =>
    findElements(parent, tag).firstOrNull?.innerText;

/// Extract an integer value from the first matching element
int? getIntValue(XmlElement parent, String tag) {
  final value = getElementText(parent, tag);
  return value != null ? int.tryParse(value) : null;
}

/// Check if element contains a specific child element
bool hasElement(XmlElement parent, String childTag) =>
    findElements(parent, childTag).isNotEmpty;

/// PATH

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

/// HASH

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

/// EXT

extension IterX<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}
