# R8 rules para sa release build.
#
# Ang google_mlkit_text_recognition ay nagre-refer sa optional na ML Kit
# language recognizers (Chinese/Devanagari/Japanese/Korean) na hindi natin
# ini-install — hindi natin ginagamit ang mga iyon (English/Latin lang ang
# kailangan ng ID scanner), kaya tinatanggal ang warnings na ito para
# makapag-compile ang R8 nang walang error.

-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
