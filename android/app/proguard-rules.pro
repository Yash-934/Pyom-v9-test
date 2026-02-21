# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep our MainActivity
-keep class com.pyom.** { *; }

# Keep Flutter plugins
-keep class io.flutter.plugins.** { *; }

# Prevent stripping of reflection-based code
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable

# Kotlin
-keep class kotlin.** { *; }
-keepclassmembers class **$WhenMappings { <fields>; }
