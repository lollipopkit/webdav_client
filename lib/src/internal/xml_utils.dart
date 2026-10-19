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

/// The `DAV:response` children of a `DAV:multistatus` [document]
/// (RFC 4918 §14.16). Nested elements, such as property values that happen to
/// be named `response`, are not included. Any other root is malformed.
Iterable<XmlElement> multiStatusResponses(XmlDocument document) {
  final root = document.rootElement;
  if (root.localName != 'multistatus' || root.namespaceUri != 'DAV:') {
    throw XmlParserException(
      'Expected a DAV:multistatus root, found ${root.name.qualified}',
    );
  }
  return davChildren(root, 'response');
}

/// Direct `DAV:` children of [element] named [name].
Iterable<XmlElement> davChildren(XmlElement element, String name) =>
    element.findElements(name, namespaceUri: 'DAV:');

/// First direct `DAV:` child of [element] named [name], or `null`.
XmlElement? davChild(XmlElement element, String name) =>
    element.getElement(name, namespaceUri: 'DAV:');

/// Trimmed text of the `DAV:href` child of [element], or `null`.
String? hrefText(XmlElement element) {
  final text = davChild(element, 'href')?.innerText.trim();
  return text == null || text.isEmpty ? null : text;
}
