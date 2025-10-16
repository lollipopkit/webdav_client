import 'package:test/test.dart';
import 'package:webdav_client_plus/src/enums.dart';
import 'package:xml/xml.dart';

void main() {
  group('PropfindType.allprop', () {
    test('omits include element when no extra properties are provided', () {
      final xml = PropfindType.allprop.buildXmlStr(const []);
      final document = XmlDocument.parse(xml);

      final includeElements =
          document.findAllElements('include', namespace: '*');
      expect(includeElements, isEmpty);
    });

    test('adds include element for explicitly requested properties', () {
      final xml = PropfindType.allprop.buildXmlStr(
        const ['oc:permissions'],
        namespaceMap: const {'oc': 'http://owncloud.org/ns'},
      );
      final document = XmlDocument.parse(xml);

      final include =
          document.findAllElements('include', namespace: '*').single;
      final propertyElement = include
          .findElements('permissions', namespace: 'http://owncloud.org/ns')
          .single;

      expect(propertyElement.name.prefix, 'oc');

      final root = document.rootElement;
      final namespaceAttr = root.getAttribute('xmlns:oc');
      expect(namespaceAttr, 'http://owncloud.org/ns');
    });
  });
}
