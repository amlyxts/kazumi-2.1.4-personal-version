class DanmakuEpisode {
  int episodeId;
  String episodeTitle;

  DanmakuEpisode({
    required this.episodeId,
    required this.episodeTitle,
  });

  factory DanmakuEpisode.fromJson(Map<String, dynamic> json) {
    return DanmakuEpisode(
      episodeId: json['episodeId'],
      episodeTitle: json['episodeTitle'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'episodeId': episodeId,
      'episodeTitle': episodeTitle,
    };
  }
}

class DanmakuEpisodeResponse {
  int bangumiId;
  List<DanmakuEpisode> episodes;
  int errorCode;
  bool success;
  String errorMessage;

  DanmakuEpisodeResponse({
    required this.bangumiId,
    required this.episodes,
    required this.errorCode,
    required this.success,
    required this.errorMessage,
  });

  factory DanmakuEpisodeResponse.fromJson(Map<String, dynamic> json) {
    // 空安全: 错误响应 (success=false) 无 bangumi 字段, 直接链式取值会崩溃
    final bangumi = json['bangumi'];
    var list = bangumi is Map ? bangumi['episodes'] as List? : null;
    List<DanmakuEpisode> episodeList =
        list?.map((i) => DanmakuEpisode.fromJson(i)).toList() ?? [];

    return DanmakuEpisodeResponse(
      bangumiId:
          bangumi is Map ? (bangumi['animeId'] ?? 0) : 0,
      episodes: episodeList,
      errorCode: json['errorCode'] ?? 0,
      success: json['success'] ?? false,
      errorMessage: json['errorMessage'] ?? '',
    );
  }

  factory DanmakuEpisodeResponse.fromTemplate() {
    return DanmakuEpisodeResponse(
      bangumiId: 0,
      episodes: [],
      errorCode: 0,
      success: false,
      errorMessage: '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'bangumi': episodes.map((episode) => episode.toJson()).toList(),
      'errorCode': errorCode,
      'success': success,
      'errorMessage': errorMessage,
    };
  }
}
