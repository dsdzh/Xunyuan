# Flutter engine embedding
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }

# Flutter embedding references Play Core deferred-component APIs we never use
-dontwarn com.google.android.play.core.**

# Keep line numbers for readable crash traces after R8
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
