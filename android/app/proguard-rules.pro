# Mingtu AI ProGuard/R8 rules.
#
# P0 launch crash (Xiaomi 15, release 229601e): FATAL EXCEPTION
# main -- Unable to get provider
# androidx.startup.InitializationProvider:
# RuntimeException: Failed to create an instance of class
# androidx.work.impl.WorkDatabase (WorkManagerInitializer).
# The Room-generated WorkDatabase_Impl was stripped/obfuscated
# by R8. Demo release builds currently ship with minify OFF
# (see build.gradle.kts), but these rules are wired in via
# proguardFiles so re-enabling minify cannot silently
# reintroduce the crash.

# Room: keep database classes and their generated _Impl.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.room.** { *; }

# WorkManager (pulled in transitively by plugins): keep all.
-keep class androidx.work.** { *; }

# AndroidX Startup (the provider that crashed first).
-keep class androidx.startup.** { *; }
