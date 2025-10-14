import 'package:webdav_client_plus/src/utils.dart';
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
  String buildXmlStr(
    List<String> properties, {
    Map<String, String> namespaceMap = const <String, String>{},
  }) {
    return switch (this) {
      prop => _buildPropXml(properties, namespaceMap: namespaceMap),
      allprop => _buildAllPropXml(),
      propname => _buildPropNameXml(),
    };
  }

  /// Default properties to be requested in a PROPFIND request
  static const defaultFindProperties = [
    'resourcetype',
    'getcontenttype',
    'getetag',
    'getcontentlength',
    'creationdate',
    'getlastmodified',
    'displayname',
  ];

  static String _buildPropXml(
    List<String> properties, {
    Map<String, String> namespaceMap = const <String, String>{},
  }) {
    final resolution = resolvePropertyNames(
      properties,
      namespaceMap: namespaceMap,
    );

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');

      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespace(uri, prefix);
      });

      xmlBuilder.element('d:prop', nest: () {
        for (final prop in resolution.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildAllPropXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:allprop');
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildPropNameXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:propname');
    });
    return xmlBuilder.buildDocument().toString();
  }
}
