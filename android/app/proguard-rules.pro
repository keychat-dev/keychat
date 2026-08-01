# mobile_scanner (ML Kit barcode scanning) discovers its Play-Services
# registrar classes via reflection at runtime. R8 strips their no-arg
# constructors by default since nothing calls them directly in code,
# which crashes ComponentDiscovery with NoSuchMethodException in release
# builds (works fine in debug, where R8 doesn't run).
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-dontwarn com.google.mlkit.**
