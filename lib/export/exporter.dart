import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
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
  static ExportFormat fullscreen(int w, int h) {
    // Portrait : largeur 1080, hauteur selon le rapport réel (max 2560, pair).
    if (w > h) {
      final int t = w; w = h; h = t;
    }
    w = math.min(w, 1080);
    h = math.min(h, 2560);
    if (w.isOdd) w++;
    if (h.isOdd) h++;
    return ExportFormat('Plein écran', w, h, 30);
  }
}

class ExportParams {
  final TrackFeatures features;
  final String audioPath;
  final double start;
  final double duration;
  final ExportFormat format;
  final int videoOffsetMs;
  final VizStyle style;
  final int paletteIndex;
  final bool oled;
  final double p;
  final void Function(double progress, String label)? onProgress;
  ExportParams({
    required this.features, required this.audioPath, required this.start,
    required this.duration, required this.format, required this.videoOffsetMs,
    required this.style, required this.paletteIndex, required this.oled,
    required this.p, this.onProgress,
  });
}

/// Export MP4 (H.264 + AAC) hors temps réel : chaque image est calculée
/// avec exactement les mêmes fonctions que la lecture (synchro identique).
class VideoExporter {
  bool _cancelled = false;
  FFmpegSession? _session;

  void cancel() {
    _cancelled = true;
    final s = _session;
    if (s != null) FFmpegKit.cancel(s.getSessionId());
  }

  Future<String> export(ExportParams params) async {
    _cancelled = false;
    final f = params.format;
    final attempts = <_Attempt>[
      _Attempt(f.width, f.height, f.fps, ''),
      _Attempt(((f.width * 2 / 3).round() ~/ 2) * 2,
          ((f.height * 2 / 3).round() ~/ 2) * 2, 30,
          'Essai en qualité réduite… (résolution 2/3, 30 ips)'),
      _Attempt((f.width ~/ 2 ~/ 2) * 2, (f.height ~/ 2 ~/ 2) * 2, 30,
          'Essai en qualité réduite… (résolution 1/2, 30 ips)'),
    ];
    Object? lastError;
    for (final a in attempts) {
      try {
        if (a.note.isNotEmpty) params.onProgress?.call(0, a.note);
        return await _tryExport(params, a);
      } catch (e) {
        if (_cancelled) rethrow;
        lastError = e;
      }
    }
    throw Exception('Export impossible : $lastError');
  }

  Future<String> _tryExport(ExportParams params, _Attempt a) async {
    final feat = params.features;
    final fps = a.fps;
    final int nFrames = (params.duration * fps).round();
    if (nFrames <= 0) throw Exception('Extrait trop court');
    if (params.start >= feat.duration - 0.05) {
      throw Exception('Position trop proche de la fin du morceau');
    }
    final dt = 1.0 / fps;
    final offset = params.videoOffsetMs / 1000.0;
    final unit = math.min(a.w, a.h).toDouble();

    final rs = RenderState();
    final fx = OrganicFX();
    final fv = FrameView();
    final scene = Scene(
        rs: rs, style: params.style, paletteIndex: params.paletteIndex,
        oled: params.oled, p: params.p);
    final canvasSize = ui.Size(a.w.toDouble(), a.h.toDouble());

    // Préchauffe de 3 s : gain automatique stable dès la première image.
    const double warmup = 3.0;
    for (double t = -warmup; t < 0 && !_cancelled; t += dt) {
      fv.read(feat, math.max(0, params.start + t));
      rs.step(dt, fv, paused: false);
      fx.step(dt, rs, unit: unit, height: a.h.toDouble());
    }

    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/export_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final bitrate = _bitrate(a.w, a.h, fps);

    // Essai du tube nommé FFmpeg (méthode recommandée) puis repli PNG.
    String? pipe;
    try {
      pipe = FFmpegKitConfig.registerNewFFmpegPipe();
    } catch (_) {
      pipe = null;
    }

    // Rendu d'une image (même fonction draw que l'affichage).
    Future<ui.Image> renderFrame() async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      drawScene(scene, c, canvasSize, fx);
      return rec.endRecording().toImage(a.w, a.h);
    }

    if (pipe != null) {
      final encoders = ['h264_mediacodec', 'libx264'];
      Object? err;
      for (final enc in encoders) {
        if (_cancelled) throw Exception('Export annulé');
        final vcodec = enc == 'libx264'
            ? '-c:v libx264 -profile:v high'
            : '-c:v h264_mediacodec';
        final cmd = '-y -f rawvideo -pix_fmt rgba -s ${a.w}x${a.h} -r $fps '
            '-i "$pipe" '
            '-ss ${params.start.toStringAsFixed(3)} '
            '-i "${params.audioPath}" '
            '-map 0:v -map 1:a -t ${params.duration.toStringAsFixed(3)} '
            '$vcodec -b:v $bitrate -pix_fmt yuv420p '
            '-movflags +faststart -g ${fps * 2} '
            '-c:a aac -b:a 128k "$outPath"';
        final completer = Completer<Object?>();
        FFmpegSession session;
        var started = false;
        session = (await FFmpegKit.executeAsync(cmd, (s) {
          if (!completer.isCompleted) {
            final rc = s.getReturnCode();
            if (ReturnCode.isSuccess(rc)) {
              completer.complete(rc);
            } else {
              completer.completeError(Exception(
                  'Échec de l\'encodage (${enc}) : ${s.getFailStackTrace() ?? s.getOutputAsString() ?? ""}'));
            }
          }
        }));
        started = true;
        _session = session;
        final raf = File(pipe).openSync(mode: FileMode.write);
        try {
          for (int i = 0; i < nFrames; i++) {
            if (_cancelled) {
              throw Exception('Export annulé');
            }
            final double tau = math.max(0.0, params.start + i / fps - offset);
            fv.read(feat, tau);
            rs.step(dt, fv, paused: false);
            fx.step(dt, rs, unit: unit, height: a.h.toDouble());
            final img = await renderFrame();
            final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
            if (data == null) throw Exception('Rendu d\'image impossible');
            raf.writeFromSync(data.buffer.asUint8List());
            img.dispose();
            if (i % 4 == 0) {
              // Cède régulièrement la main à l'interface.
              await Future.delayed(Duration.zero);
              params.onProgress?.call(i / nFrames,
                  'Export ${(i / nFrames * 100).toInt()} % (${a.w}x${a.h})');
            }
          }
          await raf.flush();
          raf.closeSync();
          // Attend la fin de l'encodage FFmpeg.
          final res = await completer.future;
          if (res is Exception) throw res;
          FFmpegKitConfig.closeFFmpegPipe(pipe);
          return outPath;
        } catch (e) {
          try { raf.closeSync(); } catch (_) {}
          FFmpegKitConfig.closeFFmpegPipe(pipe);
          pipe = FFmpegKitConfig.registerNewFFmpegPipe();
          if (_cancelled) rethrow;
          // Si l'encodeur a échoué, on tente le suivant.
          final _ = started;
          try {
            await completer.future;
          } catch (_) {}
          err = e;
          continue;
        }
      }
      // Tous les encodeurs ont échoué avec le tube : repli PNG.
      if (pipe != null) {
        try { FFmpegKitConfig.closeFFmpegPipe(pipe); } catch (_) {}
      }
    }

    // ----- Repli : séquence PNG dans le cache -----
    final framesDir = Directory('${dir.path}/frames');
    if (framesDir.existsSync()) framesDir.deleteSync(recursive: true);
    framesDir.createSync(recursive: true);
    for (int i = 0; i < nFrames; i++) {
      if (_cancelled) throw Exception('Export annulé');
      final double tau = math.max(0.0, params.start + i / fps - offset);
      fv.read(feat, tau);
      rs.step(dt, fv, paused: false);
      fx.step(dt, rs, unit: unit, height: a.h.toDouble());
      final img = await renderFrame();
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
    final cmd2 = '-y -framerate $fps '
        '-i ${framesDir.path}/frame_%05d.png '
        '-ss ${params.start.toStringAsFixed(3)} '
        '-i "${params.audioPath}" '
        '-map 0:v -map 1:a -t ${params.duration.toStringAsFixed(3)} '
        '-c:v libx264 -profile:v high -b:v $bitrate -pix_fmt yuv420p '
        '-movflags +faststart -g ${fps * 2} '
        '-c:a aac -b:a 128k "$outPath"';
    final session = await FFmpegKit.execute(cmd2);
    if (!ReturnCode.isSuccess(session.getReturnCode())) {
      throw Exception('Export impossible : ${session.getOutputAsString() ?? "échec FFmpeg"}');
    }
    framesDir.deleteSync(recursive: true);
    return outPath;
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
