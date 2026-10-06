enum SuperResolutionMode {
  off(
    storageValue: 1,
    label: '关闭',
    description: '默认禁用超分辨率',
  ),
  efficiency(
    storageValue: 2,
    label: '动漫-效率档',
    description: 'Anime4K超分, 适合动漫 (效率优先)',
  ),
  quality(
    storageValue: 3,
    label: '动漫-质量档',
    description: 'Anime4K超分, 适合动漫 (质量优先)',
  ),
  liveActionEfficiency(
    storageValue: 4,
    label: '电视剧-效率档',
    description: 'FSRCNNX超分, 适合真人实拍内容 (效率优先)',
  ),
  liveActionQuality(
    storageValue: 5,
    label: '电视剧-质量档',
    description: 'FSRCNNX超分, 适合真人实拍内容 (质量优先, 4K输出时开销较大)',
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
