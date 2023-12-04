


String trim(String str, [String? chars]) {
  RegExp pattern =
      (chars != null) ? RegExp('^[$chars]+|[$chars]+\$') : RegExp(r'^\s+|\s+$');
  return str.replaceAll(pattern, '');
}

String ltrim(String str, [String? chars]) {
  var pattern = chars != null ? new RegExp('^[$chars]+') : new RegExp(r'^\s+');
  return str.replaceAll(pattern, '');
}

String rtrim(String str, [String? chars]) {
  var pattern = chars != null ? new RegExp('[$chars]+\$') : new RegExp(r'\s+$');
  return str.replaceAll(pattern, '');
}

// 获取文件名
String path2Name(String path) {
  var str = rtrim(path, '/');
  var index = str.lastIndexOf('/');
  if (index > -1) {
    str = str.substring(index + 1);
  }
  if (str == '') {
    return '/';
  }
  return str;
}
