/// REMOVED (2026-11-09, user decision): the direct Bailian
/// client that used to live here took a client-side API key
/// supplied at build time through a dart-define channel. That
/// channel is gone entirely: the APK contains no Bailian key
/// injection point any more, and nothing in the app reads,
/// holds or sends a Bailian key.
///
/// Cloud vision now goes through the server function on
/// Alibaba Cloud Function Compute (see
/// adapters/cloud_vision_client.dart and server/DEPLOY_FC.md);
/// the Bailian key exists only in that function's server-side
/// environment.
///
/// This file remains as a tombstone because the snapshot push
/// channel cannot delete files. It intentionally declares no
/// client, no key handling and no network code.
library;
