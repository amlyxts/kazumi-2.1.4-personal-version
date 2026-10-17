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
    description: 'Anime4K 超分, 效率优先 (低清新番日常用)',
  ),
  quality(
    storageValue: 3,
    label: '动漫-质量档',
    description: 'Anime4K 超分, 质量优先',
  ),
  artcnn(
    storageValue: 6,
    label: '动漫-超质',
    description: 'ArtCNN 专为动漫线稿训练的CNN超分 (中高档GPU推荐, 线稿干净度最佳)',
  ),
  fsrcnnxEfficiency(
    storageValue: 4,
    label: '通用-效率档',
    description: 'FSRCNNX 超分, 实拍/动漫通用, 效率优先',
  ),
  fsrcnnxQuality(
    storageValue: 5,
    label: '通用-质量档',
    description: 'FSRCNNX 超分, 实拍/动漫通用, 质量优先 (老番与噪点源效果好)',
  ),
  // [my修改] 感知画质增强三件套
  enhance(
    storageValue: 7,
    label: '画质增强',
    description: '色度升采样+感知超分+高质量降采样三件套 (老番/颗粒源友好, 中档GPU可跑)',
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
