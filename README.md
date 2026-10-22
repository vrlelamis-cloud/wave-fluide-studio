# Wave Fluide Studio (Flutter / Android)

Application Android complète en Flutter : animation d'ondulations parfaitement synchronisée
avec la musique (analyse FFT précalculée), 5 styles, 9 palettes, fond OLED, et **export vidéo
MP4 (H.264 + AAC) hors temps réel**, image par image.

## Construire l'APK

```bash
flutter pub get
flutter build apk --release
```

```
# APK final :
build/app/outputs/flutter-apk/app-release.apk
```

## Polices

Placez `Poppins-Regular.ttf`, `Poppins-Medium.ttf`, `Poppins-SemiBold.ttf` et
`Righteous-Regular.ttf` (libres, OFL) dans `assets/fonts/` (déclarées dans pubspec.yaml).

## Architecture

- `lib/audio/` — décodage FFmpeg vers WAV mono 44,1 kHz, FFT radix-2 2048 (Hann),
  16 bandes logarithmiques, enveloppe de basse (2 × passe-bas 140 Hz + RMS 256),
  analyse progressive en Isolate, horloge de lecture continue.
- `lib/render/` — lissage 2 étages (exponentiel + ressort critique), palettes,
  5 styles (Néon, Capsules, Organique, Bleu, Fluide), notes, ondes, fond OLED.
- `lib/export/` — export image par image (préchauffe 3 s, décalage vidéo,
  3 essais de repli, annulation, tube FFmpeg ou PNG en repli).
- `lib/ui/` — écran unique, Material 3, français, contrastes et Semantics.

## Licences

- ffmpeg_kit_flutter_new (min-gpl) : x264 est sous GPL. Pour une licence plus
  restrictive, basculez sur la saveur `min` et l'encodeur matériel `h264_mediacodec`
  (l'export essaie déjà `h264_mediacodec` en premier, voir `lib/export/exporter.dart`).

## Ce qui n'a pas pu être testé ici

Le code a été écrit pour être compilable tel quel, mais **aucun build ni test sur
appareil n'a pu être exécuté dans cet environnement**. Points à vérifier au premier build :

1. La version exacte de `ffmpeg_kit_flutter_new` (saveur GPL) et son intégration Gradle
   (voir `android/app/build.gradle` : `ffmpeg_kit_flutter.min` / `min_gpl`).
2. Les clés `-super_name` du *font tree-shaking* si vous ajoutez des variantes de polices.
3. La disponibilité de `h264_mediacodec` sur votre appareil (le repli x264 est automatique).
4. La permission `FOREGROUND_SERVICE_MEDIA_PROCESSING` sur Android 14 : l'export
   utilise un service de premier plan Kotlin simple (`ExportService.kt`).
5. Les tests unitaires (`flutter test`) : FFT, bandes, enveloppe de basse, ressort,
   déclenchement des ondes sur kick synthétique 60 Hz.
