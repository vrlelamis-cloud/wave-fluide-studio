import 'dart:typed_data';
import 'fft.dart';

/// Caractéristiques précalculées d'un morceau, à 60 images/seconde.
/// Stockage compact : ~325 octets/image, < 5 Mo pour 4 minutes.
class TrackFeatures {
  final int frameCount;
  final double duration;
  final Float32List bands; // frameCount × 16 : valeurs v_k (§5, avant gain)
  final Float32List env;   // frameCount : RMS enveloppe basse (e)
  final Int16List wave;    // frameCount × 128 : forme d'onde brute

  TrackFeatures({
    required this.frameCount,
    required this.duration,
    required this.bands,
    required this.env,
    required this.wave,
  });

  static const int fps = 60;

  void dispose() {} // libération immédiate quand la référence tombe

  void bandsAt(double t, Float32List out) {
    double f = t * fps;
    if (f < 0) f = 0;
    if (f > frameCount - 1) f = (frameCount - 1).toDouble();
    final int i0 = f.toInt();
    final int i1 = i0 + 1 < frameCount ? i0 + 1 : i0;
    final double u = f - i0;
    for (int k = 0; k < 16; k++) {
      final double a = bands[i0 * 16 + k];
      final double b = bands[i1 * 16 + k];
      out[k] = a + (b - a) * u;
    }
  }

  double envAt(double t) {
    double f = t * fps;
    if (f < 0) f = 0;
    if (f > frameCount - 1) f = (frameCount - 1).toDouble();
    final int i0 = f.toInt();
    final int i1 = i0 + 1 < frameCount ? i0 + 1 : i0;
    return env[i0] + (env[i1] - env[i0]) * (f - i0);
  }

  void waveAt(double t, Float32List out) {
    int f = (t * fps).toInt();
    if (f < 0) f = 0;
    if (f > frameCount - 1) f = frameCount - 1;
    for (int j = 0; j < 128; j++) {
      out[j] = wave[f * 128 + j] / 32768.0;
    }
  }
}

/// Vue interpolée d'une image (réutilisable, sans allocation par frame).
class FrameView {
  final Float32List bands = Float32List(16);
  final Float32List wave = Float32List(128);
  double env = 0;
  void read(TrackFeatures f, double t) {
    f.bandsAt(t, bands);
    f.waveAt(t, wave);
    env = f.envAt(t);
  }
}
