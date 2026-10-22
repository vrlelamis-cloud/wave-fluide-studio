import 'dart:math' as math;
import 'dart:typed_data';

/// FFT radix-2 réelle -> complexe, 2048 points, fenêtre de Hann.
/// Réutilise des tampons internes pour éviter toute allocation par image.
class Fft {
  final int n;
  late final Float64List _cos;
  late final Float64List _sin;
  late final Float64List _hann;
  // late final : remplis dans le constructeur, sans allocation par image.
  late final Float64List re;
  late final Float64List im;
  late final Float64List mag;

  Fft(this.n) {
    _cos = Float64List(n ~/ 2);
    _sin = Float64List(n ~/ 2);
    for (int i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = math.sin(2 * math.pi * i / n);
    }
    _hann = Float64List(n);
    for (int i = 0; i < n; i++) {
      _hann[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
    }
    re = Float64List(n);
    im = Float64List(n);
    mag = Float64List(n ~/ 2 + 1);
  }

  /// Analyse la fenêtre de 2048 échantillons [x] et produit les magnitudes
  /// normalisées |X|/n des bins 0..n/2 (fenêtre de Hann appliquée ici).
  void magnitudes(Float64List window) {
    // Fenêtre de Hann appliquée pendant la copie.
    for (int i = 0; i < n; i++) {
      re[i] = window[i] * _hann[i];
      im[i] = 0.0;
    }
    // FFT itérative radix-2 (Cooley-Tukey) : inversion binaire.
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j |= bit;
      if (i < j) {
        final double tr = re[i]; re[i] = re[j]; re[j] = tr;
        final double ti = im[i]; im[i] = im[j]; im[j] = ti;
      }
    }
    // Papillons.
    for (int len = 2; len <= n; len <<= 1) {
      final int half = len >> 1;
      final int step = n ~/ len;
      for (int i = 0; i < n; i += len) {
        for (int k = 0; k < half; k++) {
          final int c = k * step;
          final double wr = _cos[c];
          final double wi = -_sin[c];
          final int a = i + k;
          final int b = a + half;
          final double xr = re[b] * wr - im[b] * wi;
          final double xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
    for (int i = 0; i <= n ~/ 2; i++) {
      mag[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]) / n;
    }
  }

  /// dB normalisés en octets : dB = 20 log10(m + 1e-9),
  /// octet = clamp((dB + 90)/90 * 255, 0, 255)  (plage -90..0 dB).
  static int dbByte(double m) {
    final double db = 20 * math.log(m + 1e-9) / math.ln10;
    double v = (db + 90) / 90 * 255;
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return v.toInt();
  }
}

/// Bornes des 16 bandes logarithmiques (bins FFT), constantes exactes.
/// e[0] = 2 ; e[k] = max(e[k-1]+1, floor(2 × 300^(k/16))) pour k = 1..16.
List<int> bandEdges() {
  final edges = List<int>.filled(17, 0);
  edges[0] = 2;
  for (int k = 1; k <= 16; k++) {
    final double v = 2 * math.pow(300.0, k / 16).toDouble();
    final int cand = v.floor();
    edges[k] = math.max(edges[k - 1] + 1, cand);
  }
  return edges;
}
