import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'file.dart';
import 'utils.dart';

const fileXmlStr = '''<d:propfind xmlns:d='DAV:'>
			<d:prop>
				<d:displayname/>
				<d:resourcetype/>
				<d:getcontentlength/>
				<d:getcontenttype/>
				<d:getetag/>
				<d:getlastmodified/>
			</d:prop>
		</d:propfind>''';

// const quotaXmlStr = '''<d:propfind xmlns:d="DAV:">
//            <d:prop>
//              <d:quota-available-bytes/>
//              <d:quota-used-bytes/>
//            </d:prop>
//          </d:propfind>''';

class WebdavXml {
  static List<XmlElement> findAllElements(XmlDocument document, String tag) =>
      document.findAllElements(tag, namespace: '*').toList();

  static List<XmlElement> findElements(XmlElement element, String tag) =>
      element.findElements(tag, namespace: '*').toList();

  static List<WebdavFile> toFiles(String path, String xmlStr, {skipSelf = true}) {
    var files = <WebdavFile>[];
    var xmlDocument = XmlDocument.parse(xmlStr);
    List<XmlElement> list = findAllElements(xmlDocument, 'response');
    // response
    list.forEach((element) {
      // name
      final hrefElements = findElements(element, 'href');
      String href = hrefElements.isNotEmpty ? hrefElements.single.text : '';

      // propstats
      var props = findElements(element, 'propstat');
      // propstat
      for (var propstat in props) {
        // ignore != 200
        if (findElements(propstat, 'status').single.text.contains('200')) {
          // prop
          for (var prop in findElements(propstat, 'prop')) {
            final resourceTypeElements = findElements(prop, 'resourcetype');
            // isDir
            bool isDir = resourceTypeElements.isNotEmpty
                ? findElements(resourceTypeElements.single, 'collection')
                    .isNotEmpty
                : false;

            // skip self
            if (skipSelf) {
              skipSelf = false;
              if (isDir) {
                break;
              }
              throw _newXmlError('xml parse error(405)');
            }

            // mimeType
            final mimeTypeElements = findElements(prop, 'getcontenttype');
            String mimeType =
                mimeTypeElements.isNotEmpty ? mimeTypeElements.single.text : '';

            // size
            int size = 0;
            if (!isDir) {
              final sizeElements = findElements(prop, 'getcontentlength');
              size = sizeElements.isNotEmpty
                  ? int.parse(sizeElements.single.text)
                  : 0;
            }

            // eTag
            final eTagElements = findElements(prop, 'getetag');
            String eTag =
                eTagElements.isNotEmpty ? eTagElements.single.text : '';

            // create time
            final cTimeElements = findElements(prop, 'creationdate');
            DateTime? cTime = cTimeElements.isNotEmpty
                ? DateTime.parse(cTimeElements.single.text).toLocal()
                : null;

            // modified time
            final mTimeElements = findElements(prop, 'getlastmodified');
            DateTime? mTime = mTimeElements.isNotEmpty
                ? _str2LocalTime(mTimeElements.single.text)
                : null;

            //
            var str = Uri.decodeFull(href);
            var name = path2Name(str);
            var filePath = path + name + (isDir ? '/' : '');

            files.add(WebdavFile(
              path: filePath,
              isDir: isDir,
              name: name,
              mimeType: mimeType,
              size: size,
              eTag: eTag,
              cTime: cTime,
              mTime: mTime,
            ));
            break;
          }
        }
      }
    });
    return files;
  }
}

// create xml error
DioException _newXmlError(dynamic err) {
  return DioException(
    requestOptions: RequestOptions(path: '/'),
    type: DioExceptionType.unknown,
    error: err,
  );
}

DateTime? _str2LocalTime(String? str) {
  if (str == null) {
    return null;
  }
  var s = str.toLowerCase();
  if (!s.endsWith('gmt')) {
    return null;
  }
  var list = s.split(' ');
  if (list.length != 6) {
    return null;
  }
  var month = _monthMap[list[2]];
  if (month == null) {
    return null;
  }

  return DateTime.parse(
          '${list[3]}-$month-${list[1].padLeft(2, '0')}T${list[4]}Z')
      .toLocal();
}

const _monthMap = {
  'jan': '01',
  'feb': '02',
  'mar': '03',
  'apr': '04',
  'may': '05',
  'jun': '06',
  'jul': '07',
  'aug': '08',
  'sep': '09',
  'oct': '10',
  'nov': '11',
  'dec': '12',
};