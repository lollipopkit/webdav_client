class WebdavFile {
  String path;
  bool isDir;
  String name;
  String? mimeType;
  int? size;
  String? eTag;
  DateTime? created;
  DateTime? modified;
  Map<String, String> customProps;

  WebdavFile({
    required this.path,
    required this.isDir,
    required this.name,
    this.mimeType,
    this.size,
    this.eTag,
    this.created,
    this.modified,
    this.customProps = const {},
  });

  @override
  String toString() {
    return 'WebdavFile{path: $path, isDir: $isDir, name: $name, mimeType: $mimeType, size: $size, eTag: $eTag, created: $created, modified: $modified}';
  }
}
