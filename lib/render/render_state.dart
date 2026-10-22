import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/features.dart';

/// État d'animation commun lecture/export : lissage en deux étages,
/// gain automatique global lent, saturation douce, enveloppe de basse,
/// forme d'onde avec gain, et signaux dérivés (§4 et §5).
class RenderState {
  // Bandes : sortie du ressort (appelée sm dans les styles).
  final Float32List sm = Float32List(16);
  final Float64List _sm1 = Float64List(16); // 1er lissage exponentiel
  final Float64List _pos = Float64List(16); // ressort : position
  final Float64List _vel = Float64List(16);  // ressort : vitesse

  double pk = 0.3;   // suiveur de crête du gain global
  double kp = 0.03;  // normalisation enveloppe basse
  double wp = 0.05;  // gain forme d'onde
  double ka = 0;     // moyenne lente de rb (déclenchement ondes)
  double rb = 0;     // enveloppe de basse normalisée
  double prevRb = 0;
  double rbDelta = 0; // variation de rb depuis l'image précédente (pour les ondes)
  double res = 0;    // énergie de résonance (notes)
  double hold = 0;   // suivi du coup de basse (écrasement)
  double t = 0;      // temps d'animation cumulé

  final Float32List wave = Float32List(128); // forme d'onde après gain

  // Signaux dérivés.
  double bass = 0, bb = 0, bx = 0, md = 0, hi = 0, loud = 0;

  void reset() {
    for (int k = 0; k < 16; k++) {
      sm[k] = 0; _sm1[k] = 0; _pos[k] = 0; _vel[k] = 0;
    }
    pk = 0.3; kp = 0.03; wp = 0.05; ka = 0; rb = 0; prevRb = 0;
    rbDelta = 0; res = 0; hold = 0; t = 0;
  }

  /// Fait avancer l'état de [dt] secondes avec les caractéristiques brutes
  /// [fv] lues à l'instant courant. Identique en lecture et en export.
  void step(double dtRaw, FrameView fv, {required bool paused}) {
    double dt = dtRaw;
    if (dt < 0.001) dt = 0.001;
    if (dt > 0.100) dt = 0.100;
    t += dt;

    double vmax = 0;
    if (!paused) {
      for (int k = 0; k < 16; k++) {
        if (fv.bands[k] > vmax) vmax = fv.bands[k];
      }
    }

    // --- Gain automatique global lent (suiveur de crête) ---
    if (!paused) {
      if (vmax > pk) {
        pk += (vmax - pk) * (1 - math.exp(-dt / 0.6));
      } else {
        pk *= math.exp(-dt / 6);
      }
    }
    final double g = 0.9 / math.max(0.3, pk);

    // --- Enveloppe de basse normalisée (rb) ---
    final double oldRb = rb;
    if (!paused) {
      final double e = fv.env;
      kp = math.max(e, kp * math.exp(-dt / 3));
      final double kn = math.min(1.2, e / math.max(0.03, kp));
      rb = math.min(1.2, kn);
    } else {
      rb = 0;
    }
    rbDelta = rb - oldRb;

    // --- Bandes : cible puis deux étages de lissage ---
    for (int k = 0; k < 16; k++) {
      double x;
      if (paused) {
        // Respiration douce en pause.
        x = 0.07 + 0.05 * math.sin(t * 1.2 + k * 0.5);
      } else {
        // Saturation douce.
        final double v = fv.bands[k] * g;
        x = math.min(1.08, (1 - math.exp(-2.2 * v)) / (1 - math.exp(-2.2)));
      }
      // 1) lissage exponentiel indépendant du taux d'images.
      final double tau = x > _sm1[k] ? 0.022 : 0.14;
      _sm1[k] += (x - _sm1[k]) * (1 - math.exp(-dt / tau));
      // 2) ressort critique.
      final double tg = _sm1[k];
      final double w = tg > _pos[k] ? 60.0 : 26.0;
      final double d = _pos[k] - tg;
      final double ex = math.exp(-w * dt);
      final double tmp = _vel[k] + w * d;
      _pos[k] = math.max(0, tg + (d + tmp * dt) * ex);
      _vel[k] = (_vel[k] - w * tmp * dt) * ex;
      sm[k] = _pos[k];
    }

    // --- Forme d'onde avec gain automatique ---
    double m = 0;
    for (int j = 0; j < 128; j++) {
      final double a = fv.wave[j].abs();
      if (a > m) m = a;
    }
    wp = math.max(m, wp * 0.985);
    final double wf = 0.55 / math.max(0.05, wp);
    for (int j = 0; j < 128; j++) {
      wave[j] = fv.wave[j] * wf;
    }

    // --- Signaux dérivés ---
    bass = math.min(1.0, (sm[0] + sm[1] + sm[2]) / 3);
    bb = 0.4 * sm[0] + 0.3 * sm[1] + 0.2 * sm[2] + 0.1 * sm[3];
    bx = math.min(1.15, (1 - math.exp(-3.2 * bb)) / (1 - math.exp(-3.2)) * 1.1);
    double s4 = 0;
    for (int k = 4; k <= 8; k++) {
      s4 += sm[k];
    }
    md = s4 / 5;
    double s9 = 0;
    for (int k = 9; k <= 15; k++) {
      s9 += sm[k];
    }
    hi = s9 / 7;
    double sl = 0;
    for (int k = 0; k < 16; k++) {
      sl += sm[k];
    }
    loud = sl / 16;

    // --- Résonance et suivi du coup de basse (notes) ---
    res = math.min(1.2, (res + math.max(0, rbDelta) * 2)) * math.exp(-dt / 0.22);
    hold = math.max(rb, hold * math.exp(-dt / 0.5));
    ka += (rb - ka) * (1 - math.exp(-dt / 0.2));
    prevRb = rb;
  }
}
