import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/pages/video/local_video_page.dart';

final localVideoModule = createModule(
  path: '/local_video',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const LocalVideoPage(),
    );
  },
);
