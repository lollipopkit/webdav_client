import 'package:xml/xml.dart';

/// Depth of the PROPFIND request
enum PropsDepth {
  /// Only the properties of the resource
  zero,

  /// Including the properties of the resource and its direct children
  one,

  /// Including the properties of the resource and all its children
  infinity,
  ;

  /// Get the String value of the enum
  String get value {
    return switch (this) {
      zero => '0',
      one => '1',
      infinity => 'infinity',
    };
  }
}

/// Type of PROPFIND request
enum PropfindType {
  /// Properties
  prop,

  /// All properties
  allprop,

  /// Only property names
  propname,
  ;

  /// Build the XML string for the PROPFIND request
  String buildXmlStr(List<String> properties) {
    return switch (this) {
      prop => _buildPropXml(properties),
      allprop => _buildAllPropXml(),
      propname => _buildPropNameXml(),
    };
  }

  static const defaultFindProperties = [
    'resourcetype',
    'getcontenttype',
    'getetag',
    'getcontentlength',
    'creationdate',
    'getlastmodified',
    'displayname',
  ];

  static String _buildPropXml(List<String> properties) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('d', 'DAV:');

      // Collect all namespaces
      final namespaces = <String, String>{};
      for (final prop in properties) {
        if (prop.contains(':')) {
          final parts = prop.split(':');
          final prefix = parts[0];
          if (prefix != 'd' && !namespaces.containsKey(prefix)) {
            namespaces[prefix] = 'http://example.com/ns/$prefix';
          }
        }
      }

      // Add namespaces to the XML
      namespaces.forEach((prefix, uri) {
        xmlBuilder.namespace(prefix, uri);
      });

      xmlBuilder.element('d:prop', nest: () {
        for (final prop in properties) {
          // Process all properties
          if (prop.contains(':')) {
            final parts = prop.split(':');
            final prefix = parts[0];
            final name = parts[1];
            xmlBuilder.element('$prefix:$name');
          } else {
            xmlBuilder.element('d:$prop');
          }
        }
      });
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildAllPropXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('d', 'DAV:');
      xmlBuilder.element('d:allprop');
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildPropNameXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('d', 'DAV:');
      xmlBuilder.element('d:propname');
    });
    return xmlBuilder.buildDocument().toString();
  }
}
