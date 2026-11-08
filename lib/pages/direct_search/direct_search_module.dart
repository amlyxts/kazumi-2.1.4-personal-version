import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/pages/direct_search/direct_search_page.dart';

final directSearchModule = createModule(
  path: '/direct_search',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const DirectSearchPage(),
    );
  },
);
