import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/pages/adult_collect/adult_collect_page.dart';

// [my新增] 里番收藏页签: 直连浏览收藏的独立分区视图 (纯本地+WebDAV)
final adultCollectModule = createModule(
  path: '/adult_collect',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const AdultCollectPage(),
    );
  },
);
