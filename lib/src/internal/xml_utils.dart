import 'package:xml/xml.dart';

/// Locate every element in [document] matching [tag] irrespective of namespace.
List<XmlElement> findAllElements(XmlDocument document, String tag) =>
    document.findAllElements(tag, namespaceUri: '*').toList();

/// Locate direct or nested children of [element] matching [tag] irrespective
/// of namespace.
List<XmlElement> findElements(XmlElement element, String tag) =>
    element.findElements(tag, namespaceUri: '*').toList();

/// Extract a string value from the first matching element or return `null`.
String? getElementText(XmlElement parent, String tag) =>
    findElements(parent, tag).firstOrNull?.innerText;

/// Extract an integer value from the first matching element or return `null`.
int? getIntValue(XmlElement parent, String tag) {
  final value = getElementText(parent, tag)?.trim();
  return value != null ? int.tryParse(value) : null;
}

/// Return `true` when [parent] contains at least one child with [childTag].
bool hasElement(XmlElement parent, String childTag) =>
    findElements(parent, childTag).isNotEmpty;

final _statusLineReg = RegExp(r'^HTTP/\d+(?:\.\d+)?\s+(\d{3})(?:\s|$)');

/// Parse the code of a `DAV:status` HTTP status-line (RFC 4918 §14.28), or
/// return `null` when [statusText] is not one.
int? parseStatusLine(String statusText) {
  final match = _statusLineReg.firstMatch(statusText.trim());
  return match != null ? int.parse(match.group(1)!) : null;
}
