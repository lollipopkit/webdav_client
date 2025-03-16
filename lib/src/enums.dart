enum ReadPropsDepth {
  zero,
  one,
  infinity,
  ;

  String get value {
    return switch (this) {
      zero => '0',
      one => '1',
      infinity => 'infinity',
    };
  }
}
