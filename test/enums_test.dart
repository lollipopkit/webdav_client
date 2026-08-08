import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
import 'package:xml/xml.dart';

void main() {
  group('LockTimeout', () {
    test('seconds creates correct header value', () {
      final t = LockTimeout.seconds(3600);
      expect(t.headerValue, 'Second-3600');
    });

    test('seconds rejects zero', () {
      expect(() => LockTimeout.seconds(0), throwsArgumentError);
    });

    test('seconds rejects negative', () {
      expect(() => LockTimeout.seconds(-1), throwsArgumentError);
    });

    test('infinite creates correct header value', () {
      const t = LockTimeout.infinite();
      expect(t.headerValue, 'Infinite');
    });

    test('custom creates correct header value', () {
      final t = LockTimeout.custom('Second-600');
      expect(t.headerValue, 'Second-600');
    });

    test('custom rejects empty', () {
      expect(() => LockTimeout.custom(''), throwsArgumentError);
      expect(() => LockTimeout.custom('   '), throwsArgumentError);
    });

    test('equality', () {
      final a = LockTimeout.seconds(100);
      final b = LockTimeout.seconds(100);
      final c = LockTimeout.seconds(200);
      expect(a, equals(b));
      expect(a == c, isFalse);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('toString', () {
      final t = LockTimeout.seconds(60);
      expect(t.toString(), 'LockTimeout(Second-60)');
    });
  });

  group('PropfindType', () {
    test('allprop omits include when no properties given', () {
      final xml = PropfindType.allprop.buildXmlStr([]);
      final doc = XmlDocument.parse(xml);
      final includes =
          doc.findAllElements('include', namespaceUri: '*').toList();
      expect(includes, isEmpty);
      final allprop = doc.findAllElements('allprop', namespaceUri: '*');
      expect(allprop, isNotEmpty);
    });

    test('allprop adds include when properties given', () {
      final xml =
          PropfindType.allprop.buildXmlStr(['getetag', 'displayname']);
      final doc = XmlDocument.parse(xml);
      final includes =
          doc.findAllElements('include', namespaceUri: '*').toList();
      expect(includes, isNotEmpty);
      final include = includes.first;
      final children = include.childElements.toList();
      expect(children.length, 2);
    });

    test('allprop with custom namespaces', () {
      final xml = PropfindType.allprop.buildXmlStr(
        ['custom:test'],
        namespaceMap: {'custom': 'http://example.com/custom'},
      );
      expect(xml, contains('http://example.com/custom'));
      expect(xml, contains('custom:test'));
    });

    test('propname builds correct XML', () {
      final xml = PropfindType.propname.buildXmlStr([]);
      final doc = XmlDocument.parse(xml);
      final propname = doc.findAllElements('propname', namespaceUri: '*');
      expect(propname, isNotEmpty);
    });

    test('prop builds XML with multiple properties', () {
      final xml = PropfindType.prop.buildXmlStr([
        'getetag',
        'displayname',
        '{http://example.com/custom}prop1',
      ]);
      expect(xml, contains('getetag'));
      expect(xml, contains('displayname'));
      expect(xml, contains('prop1'));
    });

    test('prop with custom namespaces', () {
      final xml = PropfindType.prop.buildXmlStr(
        ['custom:test', 'custom:test2'],
        namespaceMap: {'custom': 'http://example.com/custom'},
      );
      expect(xml, contains('http://example.com/custom'));
      expect(xml, contains('custom:test'));
      expect(xml, contains('custom:test2'));
    });
  });

  group('PropsDepth', () {
    test('value strings', () {
      expect(PropsDepth.zero.value, '0');
      expect(PropsDepth.one.value, '1');
      expect(PropsDepth.infinity.value, 'infinity');
    });
  });
}
