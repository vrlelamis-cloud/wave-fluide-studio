import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

import 'features.dart';
import 'fft.dart';

const int kSampleRate = 44100;

/// Décode n'importe quel format audio (mp3, m4a, aac, wav, ogg, opus, flac,
/// amr, 3gp) vers WAV PCM 16 bits mono 44 100 Hz dans le cache, puis charge
/// et analyse le signal (FFT, bandes, enveloppe de basse) hors du fil UI.
class Decoder {
  /// Conversion FFmpeg vers WAV mono 44,1 kHz.
  static Future<String> toWav(String srcPath) async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/wfs_${DateTime.now().microsecondsSinceEpoch}.wav';
    final rc = await FFmpegKit.execute(
        '-y -i "$srcPath" -ac 1 -ar 44100 -c:a pcm_s16le -f wav "$out"');
    // Dans ce fork, les accesseurs de session sont asynchrones.
    final code = await rc.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      throw Exception('Fichier audio illisible ou format non pris en charge');
    }
    return out;
  }

  static Future<double> probeDuration(String path) async {
    final s = await FFprobeKit.getMediaInformation(path);
    final mi = await s.getMediaInformation();
    final d = mi == null ? null : await mi.getDuration();
    return d == null ? 0 : (double.tryParse(d) ?? 0);
  }

  /// Analyse complète en Isolate (aucun calcul sur le fil d'interface).
  static Future<TrackFeatures> analyze(String wavPath) async {
    return await Isolate.run(() => analyzeWavFile(wavPath));
  }

  /// Lecture du WAV + analyse (bloquant, à appeler depuis un Isolate).
  static TrackFeatures analyzeWavFile(String wavPath) {
    final bytes = File(wavPath).readAsBytesSync();
    // Recherche du bloc « data ».
    int dataStart = 44;
    for (int i = 12; i + 8 <= bytes.length; i++) {
      if (bytes[i] == 0x64 && bytes[i + 1] == 0x61 &&
          bytes[i + 2] == 0x74 && bytes[i + 3] == 0x61) {
        dataStart = i + 8;
        break;
      }
    }
    final int nSamples = (bytes.length - dataStart) ~/ 2;
    final pcm = Int16List(nSamples);
    final bd = ByteData.sublistView(bytes, dataStart);
    for (int i = 0; i < nSamples; i++) {
      pcm[i] = bd.getInt16(i * 2, Endian.little);
    }
    return analyzePcm(pcm);
  }

  /// Analyse publique (testable) : spectre 16 bandes + enveloppe basse
  /// + forme d'onde, image par image à 60 Hz.
  static TrackFeatures analyzePcm(Int16List pcm) {
    const int sr = kSampleRate;
    const int fps = 60;
    final int nSamples = pcm.length;
    final int nFrames = math.max(1, (nSamples / sr * fps).round());
    final bands = Float32List(nFrames * 16);
    final env = Float32List(nFrames);
    final wave = Int16List(nFrames * 128);

    final fft = Fft(2048);
    final window = Float64List(2048);
    final edges = bandEdges();
    final bins255 = Uint8List(1024);

    // --- Passe 1 : spectre, bandes, forme d'onde ---
    for (int f = 0; f < nFrames; f++) {
      final int center = (f * sr / fps).round();
      final int start = center - 1024;
      for (int i = 0; i < 2048; i++) {
        final int idx = start + i;
        window[i] = (idx >= 0 && idx < nSamples) ? pcm[idx] / 32768.0 : 0.0;
      }
      fft.magnitudes(window);
      for (int b = 0; b < 1024; b++) {
        bins255[b] = Fft.dbByte(fft.mag[b + 1]);
      }
      for (int k = 0; k < 16; k++) {
        final int lo = edges[k];
        final int hi = math.max(lo + 1, math.min(1024, edges[k + 1]));
        int sum = 0;
        final int cnt = hi - lo;
        for (int b = lo; b < hi; b++) {
          sum += bins255[b];
        }
        final double x = (cnt <= 0 ? 0.0 : sum / cnt / 255.0);
        double v = (x - 0.22) / 0.78;
        if (v < 0) v = 0;
        bands[f * 16 + k] = v * (1 + k * 0.045);
      }
      final int ws = center - 512;
      for (int j = 0; j < 128; j++) {
        final int idx = ws + j * 8;
        wave[f * 128 + j] = (idx >= 0 && idx < nSamples) ? pcm[idx] : 0;
      }
    }

    // --- Passe 2 : enveloppe de basse « précise » ---
    // Deux filtres passe-bas à un pôle cascadés à 140 Hz.
    final double alpha = 1 - math.exp(-2 * math.pi * 140 / sr);
    final y2buf = Float32List(nSamples);
    double a1 = 0, b1 = 0;
    for (int i = 0; i < nSamples; i++) {
      final double x = pcm[i] / 32768.0;
      a1 += alpha * (x - a1);
      b1 += alpha * (a1 - b1);
      y2buf[i] = b1;
    }
    // RMS sur fenêtre de 256 échantillons centrée sur l'instant de l'image.
    for (int f = 0; f < nFrames; f++) {
      final int center = (f * sr / fps).round();
      int lo = center - 128, hi = center + 128;
      if (lo < 0) lo = 0;
      if (hi > nSamples) hi = nSamples;
      double s = 0;
      for (int i = lo; i < hi; i++) {
        s += y2buf[i] * y2buf[i];
      }
      env[f] = (hi == lo) ? 0.0 : math.sqrt(s / (hi - lo));
    }

    return TrackFeatures(
      frameCount: nFrames,
      duration: nSamples / sr,
      bands: bands,
      env: env,
      wave: wave,
    );
  }
}
