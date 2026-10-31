enum SuperResolutionMode {
  off(
    storageValue: 1,
    label: '关闭',
    description: '默认禁用超分辨率',
  ),
  // [my修改] 档位按"动漫专用在前、通用在后"重排并统一命名; storageValue 保持
  // 不变, 旧存档不受影响。
  efficiency(
    storageValue: 2,
    label: '动漫-效率档',
    description: '官方 Mode B 软修复链 (温和去锯齿, 720p/降采样源; 1080p 同分辨率收益有限)',
  ),
  quality(
    storageValue: 3,
    label: '动漫-质量档',
    description: '官方 Mode A VL 重型链 (修复压缩模糊, 1080p 番/老番; 中高档 GPU)',
  ),
  artcnn(
    storageValue: 6,
    label: '动漫-超质',
    description: 'ArtCNN 动漫线稿 CNN 超分, 线稿干净度最佳 (需中高档 GPU, 编译失败请看 mpv 日志)',
  ),
  fsrcnnxEfficiency(
    storageValue: 4,
    label: '通用-效率档',
    description: 'FSRCNNX x2_8 轻量网络 (实拍/动漫通用, 提升温和)',
  ),
  fsrcnnxQuality(
    storageValue: 5,
    label: '通用-质量档',
    description: 'FSRCNNX x2_16 满血网络 (低清源放大观看收益最大)',
  ),
  // [my修改] 感知画质增强三件套
  enhance(
    storageValue: 7,
    label: '画质增强',
    description: '色度升采样+感知超分+高质量降采样三件套 — 视频分辨率高于屏幕时才发挥 (高分屏/放大观看适用)',
  );

  const SuperResolutionMode({
    required this.storageValue,
    required this.label,
    required this.description,
  });

  final int storageValue;
  final String label;
  final String description;

  static SuperResolutionMode fromStorageValue(int value) {
    return SuperResolutionMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => SuperResolutionMode.off,
    );
  }
}
