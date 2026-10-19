import 'package:xml/xml.dart';

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
