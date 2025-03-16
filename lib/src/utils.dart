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
