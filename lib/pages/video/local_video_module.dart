import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/pages/video/local_video_page.dart';

class LocalVideoModule extends Module {
  @override
  void routes(r) {
    r.child("/", child: (_) => const LocalVideoPage());
  }
}
