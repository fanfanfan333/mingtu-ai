/// Web / non-mobile permission gateway: there is no
/// platform permission system to talk to, so the factory
/// returns the unavailable implementation.
library;

import '../core/permission_flow.dart';
import 'permission_gateway.dart';

PermissionGateway createPermissionGateway() =>
    const UnavailablePermissionGateway();
