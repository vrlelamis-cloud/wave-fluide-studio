import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/features.dart';
import '../render/organic.dart';
import '../render/render_state.dart';
import '../render/scene.dart';

/// Format vidéo (§7).
class ExportFormat {
  final String label;
  final int width, height, fps;
  const ExportFormat(this.label, this.width, this.height, this.fps);
  static const f9x16 = ExportFormat('9:16', 720, 1280, 60);
  static const f16x9 = ExportFormat('16:9', 1280, 720, 60);
  static const tiktokHd = ExportFormat('TikTok HD', 1080, 1920, 30);
  // Plein écran : résolue à l'exécution selon l'écran réel.
  static ExportFormat fullscreen(double screenW, double screenH, double dpr) {
    int w = (screenW * dpr).round();
    int h = (screenH * dpr).round();
    if (h > w) {
      final int t = w; w = h; h = t; // portrait
    }
    w = math.min(w, 1080);
    h = math.min(h, 2560);
    if (h.isOdd) h--;
    if (w.isOdd) w--;
    return ExportFormat('Plein écran', w, h, 30);
  }
}

class ExportParams {
  final TrackFeatures features;
  final String audioPath;      // fichier d'origine
  final double start;          // position de départ (s)
  final double duration;       // durée de l'extrait (s)
  final ExportFormat format;
  final int videoOffsetMs;     // décalage vidéo
  final VizStyle style;
  final int paletteIndex;
  final bool oled;
  final double p;              // espace paroles
  final void Function(double progress, String label)? onProgress;
  ExportParams({
    required this.features, required this.audioPath, required this.start,
    required this.duration, required this.format, required this.videoOffsetMs,
    required this.style, required this.paletteIndex, required this.oled,
    required this.p, this.onProgress,
  });
}

/// Export d'un vrai fichier MP4 (H.264 + AAC) calculé hors temps réel,
/// image par image, avec préchauffe de 3 s et essais de repli.
class VideoExporter {
  bool _cancelled = false;
  FFmpegSession? _session;

  void cancel() {
    _cancelled = true;
    final s = _session;
    if (s != null) FFmpegKit.cancel(s.getSessionId());
  }

  /// Renvoie le chemin du MP4, ou jette une exception lisible.
  Future<String> export(ExportParams params) async {
    _cancelled = false;
    final attempts = <_Attempt>[
      _Attempt(params.format.width, params.format.height, params.format.fps, ''),
      _Attempt((params.format.width * 2 / 3).toInt() & ~1,
          (params.format.height * 2 / 3).toInt() & ~1, 30,
          'Essai en qualité réduite… (résolution 2/3, 30 ips)'),
      _Attempt(params.format.width ~/ 2 & ~1, params.format.height ~/ 2 & ~1,
          30, 'Essai en qualité réduite… (résolution 1/2, 30 ips)'),
    ];
    Object? lastError;
    for (final a in attempts) {
      try {
        if (a.note.isNotEmpty) {
          params.onProgress?.call(0, a.note);
        }
        return await _tryExport(params, a);
      } catch (e) {
        if (_cancelled) rethrow;
        lastError = e;
      }
    }
    throw Exception('Export impossible : ${lastError}');
  }

  Future<String> _tryExport(ExportParams params, _Attempt a) async {
    final feat = params.features;
    final fps = a.fps;
    final int nFrames =
        (params.duration * fps).round();
    if (nFrames <= 0) throw Exception('Extrait trop court');
    final dt = 1.0 / fps;
    final offset = params.videoOffsetMs / 1000.0;

    // ----- Rendu des images dans un état frais (préchauffe 3 s) -----
    final rs = RenderState();
    final fx = OrganicFX();
    final fv = FrameView();
    final scene = Scene(
        rs: rs, style: params.style, paletteIndex: params.paletteIndex,
        oled: params.oled, p: params.p);

    // Préchauffe : analyse les 3 s précédant l'extrait pour un gain stable.
    const double warmup = 3.0;
    for (double t = -warmup; t < 0 && !_cancelled; t += dt) {
      fv.read(feat, math.max(0, params.start + t));
      rs.step(dt, fv, paused: false);
      fx.step(dt, rs, unit: math.min(a.w, a.h).toDouble(), height: a.h.toDouble());
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final canvasSize = ui.Size(a.w.toDouble(), a.h.toDouble());

    // Tube nommé FFmpeg (méthode recommandée) ; repli PNG ci-dessous.
    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/export_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final bitrate = _bitrate(a.w, a.h, fps);
    String? pipe;
    try {
      pipe = FFmpegKitConfig.registerNewFFmpegPipe();
    } catch (_) {
      pipe = null;
    }

    final encoders = ['h264_mediacodec', 'libx264'];
    Object? err;
    for (final enc in encoders) {
      if (_cancelled) throw Exception('Export annulé');
      final vcodec = enc == 'libx264' ? '-c:v libx264 -profile:v high' : '-c:v h264_mediacodec';
      final input = pipe ?? '${dir.path}/frames/frame_%05d.png';
      final cmd = '-y -f rawvideo -pix_fmt rgba -s ${a.w}x${a.h} '
          '-r $fps -i "$input" '
          '-ss ${params.start.toStringAsFixed(3)} -i "${params.audioPath}" '
          '-map 0:v -map 1:a -t ${params.duration.toStringAsFixed(3)} '
          '$vcodec -b:v $bitrate -pix_fmt yuv420p '
          '-movflags +faststart -g ${fps * 2} '
          '-c:a aac -b:a 128k "$outPath"';
      if (pipe != null) {
        // Méthode tube : FFmpeg lit pendant qu'on écrit les images.
        final completer = Completer<void>();
        late final FFmpegSession session;
        session = (await FFmpegKit.executeAsync(cmd, (s) {
          final rc = s.getReturnCode();
          if (!completer.isCompleted) {
            if (ReturnCode.isSuccess(rc)) {
              completer.complete();
            } else {
              completer.completeError(
                  Exception('Échec encodage : ${s.getOutputAsString() ?? ""}'));
            }
          }
        }));
        _session = session;
        // Écriture des images dans le tube.
        final pipeFile = File(pipe);
        final raf = pipeFile.openSync(mode: FileMode.write);
        try {
          for (int i = 0; i < nFrames; i++) {
            if (_cancelled) {
              raf.closeSync();
              FFmpegKitConfig.closeFFmpegPipe(pipe);
              FFmpegKit.cancel(session.getSessionId());
              throw Exception('Export annulé');
            }
            // Analyse au temps image avec décalage vidéo.
            final double tau = params.start + i / fps - offset;
            fv.read(feat, math.max(0, tau));
            rs.step(dt, fv, paused: false);
            fx.step(dt, rs, unit: math.min(a.w, a.h).toDouble(), height: a.h.toDouble());

            recorder.endRecording();
            // (réenregistre à chaque image)
            final rec2 = ui.PictureRecorder();
            final c2 = ui.Canvas(rec2);
            drawScene(scene, c2, canvasSize, fx);
            final img = await rec2.endRecording().toImage(a.w, a.h);
            final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
            if (data == null) throw Exception('Rendu d\'image impossible');
            raf.writeFromSync(data.buffer.asUint8List());
            img.dispose();

            if (i % 4 == 0) {
              // Cède régulièrement la main à l'interface.
              await Future.delayed(Duration.zero);
              params.onProgress?.call(
                  i / nFrames,
                  'Export ${(i / nFrames * 100).toInt()} % (${a.w}x${a.h})');
            }
          }
          raf.flushSync();
          raf.closeSync();
          await completer.future;
        } finally {
          try { raf.closeSync(); } catch (_) {}
        }
        FFmpegKitConfig.closeFFmpegPipe(pipe);
        return outPath;
      } else {
        // Repli : séquence PNG.
        final framesDir = Directory('${dir.path}/frames');
        if (framesDir.existsSync()) framesDir.deleteSync(recursive: true);
        framesDir.createSync(recursive: true);
        for (int i = 0; i < nFrames; i++) {
          if (_cancelled) throw Exception('Export annulé');
          final double tau = params.start + i / fps - offset;
          fv.read(feat, math.max(0, tau));
          rs.step(dt, fv, paused: false);
          fx.step(dt, rs, unit: math.min(a.w, a.h).toDouble(), height: a.h.toDouble());
          final rec2 = ui.PictureRecorder();
          final c2 = ui.Canvas(rec2);
          drawScene(scene, c2, canvasSize, fx);
          final img = await rec2.endRecording().toImage(a.w, a.h);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          File('${framesDir.path}/frame_${i.toString().padLeft(5, '0')}.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          img.dispose();
          if (i % 4 == 0) {
            await Future.delayed(Duration.zero);
            params.onProgress?.call(i / nFrames,
                'Export ${(i / nFrames * 100).toInt()} % (${a.w}x${a.h})');
          }
        }
        final session = await FFmpegKit.execute(cmd);
        if (!ReturnCode.isSuccess(session.getReturnCode())) {
          err = Exception('Échec encodage : ${session.getOutputAsString() ?? ""}');
          continue;
        }
        framesDir.deleteSync(recursive: true);
        return outPath;
      }
    }
    throw Exception('Export impossible : ${err ?? "aucun encodeur disponible"}');
  }

  /// Débit vidéo : min(12 Mb/s, max(3 Mb/s, L·H·fps·0,14)).
  static String _bitrate(int w, int h, int fps) {
    final double bits = w * h * fps * 0.14;
    final double mbps = math.min(12, math.max(3, bits / 1000000.0));
    return '${mbps.toStringAsFixed(1)}M';
  }
}

class _Attempt {
  final int w, h, fps;
  final String note;
  const _Attempt(this.w, this.h, this.fps, this.note);
}
