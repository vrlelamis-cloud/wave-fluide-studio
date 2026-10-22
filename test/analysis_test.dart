import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wave_fluide_studio/audio/decoder.dart';
import 'package:wave_fluide_studio/audio/fft.dart';
import 'package:wave_fluide_studio/render/organic.dart';
import 'package:wave_fluide_studio/render/render_state.dart';
import 'package:wave_fluide_studio/audio/features.dart';

void main() {
  group('FFT', () {
    test('pics corrects pour une sinusoïde', () {
      final fft = Fft(2048);
      final w = Float64List(2048);
      const int sr = 44100;
      const double freq = 440.0;
      for (int i = 0; i < 2048; i++) {
        w[i] = 0.5 * math.sin(2 * math.pi * freq * i / sr);
      }
      fft.magnitudes(w);
      // Bin le plus fort autour de 440 Hz.
      int best = 0;
      double bm = 0;
      for (int b = 1; b < 1024; b++) {
        if (fft.mag[b] > bm) {
          bm = fft.mag[b];
          best = b;
        }
      }
      final double freqFound = best * sr / 2048.0;
      expect((freqFound - freq).abs(), lessThan(sr / 2048 * 1.5));
    });

    test('conversion dB en octets (plage -90..0)', () {
      expect(Fft.dbByte(1.0), 255); // 0 dBFS
      expect(Fft.dbByte(0.0), 0);
      expect(Fft.dbByte(-1.0), 0); // valeur aberrante : aucun NaN
    });
  });

  group('bandes', () {
    test('bornes logarithmiques exactes', () {
      final e = bandEdges();
      expect(e[0], 2);
      expect(e.length, 17);
      for (int k = 1; k <= 16; k++) {
        final int expectMax =
            math.max(e[k - 1] + 1, (2 * math.pow(300.0, k / 16)).floor());
        expect(e[k], expectMax);
      }
    });
  });

  group('ressort critique', () {
    test('montée et descente stables, indépendant du dt', () {
      final rs = RenderState();
      final fv = FrameView();
      // Une cible forte.
      for (int k = 0; k < 16; k++) {
        fv.bands[k] = 1.0;
      }
      fv.env = 0;
      for (int i = 0; i < 120; i++) {
        rs.step(1 / 60, fv, paused: false);
      }
      expect(rs.sm[0], greaterThan(0.5));
      expect(rs.sm[0], lessThanOrEqualTo(1.08));
      // Descente douce.
      for (int k = 0; k < 16; k++) {
        fv.bands[k] = 0;
      }
      final double before = rs.sm[0];
      for (int i = 0; i < 30; i++) {
        rs.step(1 / 60, fv, paused: false);
      }
      expect(rs.sm[0], lessThan(before));
      // Jamais négatif.
      expect(rs.sm[0], greaterThanOrEqualTo(0));
    });

    test("pas de dépendance au taux d'images", () {
      double run(double dt) {
        final rs = RenderState();
        final fv = FrameView();
        for (int k = 0; k < 16; k++) {
          fv.bands[k] = 1;
        }
        fv.env = 0;
        double t = 0;
        while (t < 0.5) {
          rs.step(dt, fv, paused: false);
          t += dt;
        }
        return rs.sm[0];
      }
      final a = run(1 / 60);
      final b = run(1 / 30);
      expect((a - b).abs(), lessThan(0.25));
    });
  });

  group('enveloppe de basse et ondes', () {
    test('kick synthétique 60 Hz toutes les 0,5 s -> ondes à ±1 image', () {
      // Génère un kick 60 Hz toutes les 0,5 s sur 2 secondes.
      // Le premier battement commence à t = 0 : les déclenchemements
      // attendus sont aux images 0, 30, 60 et 90 (à ±1 image près).
      const int sr = 44100;
      final pcm = Int16List(sr * 2);
      for (int i = 0; i < pcm.length; i++) {
        final double phase = i / sr;
        final double beat = phase % 0.5;
        final double env = math.exp(-beat * 12);
        final double s =
            0.9 * env * math.sin(2 * math.pi * 60 * phase);
        pcm[i] = (s * 32767).toInt();
      }
      final feats = Decoder.analyzePcm(pcm);
      expect(feats.frameCount, 120);

      final rs = RenderState();
      final fx = OrganicFX();
      final fv = FrameView();
      final birthFrames = <int>[];
      int lastBirths = 0;
      for (int f = 0; f < 120; f++) {
        fv.read(feats, f / 60);
        rs.step(1 / 60, fv, paused: false);
        fx.step(1 / 60, rs, unit: 400, height: 800);
        if (fx.waveBirths > lastBirths) {
          birthFrames.add(f);
          lastBirths = fx.waveBirths;
        }
      }
      // Au moins les 4 battements (0 s, 0,5 s, 1 s, 1,5 s).
      expect(birthFrames.length, greaterThanOrEqualTo(4));
      // Le premier kick est à t = 0 : tolérance 0..2 images.
      expect(birthFrames[0], lessThanOrEqualTo(2));
      // Les battements suivants : images 30, 60, 90 à ±1 image près.
      expect((birthFrames[1] - 30).abs(), lessThan(2));
      expect((birthFrames[2] - 60).abs(), lessThan(2));
      expect((birthFrames[3] - 90).abs(), lessThan(2));
    });
  });
}
