/// Web / non-mobile guide store: nothing can be
/// persisted, so the factory returns the unavailable
/// store (which answers "seen").
library;

import '../core/permission_flow.dart';
import 'guide_store.dart';

GuideStore createGuideStore() => const UnavailableGuideStore();
