import 'dart:math' as math;
import 'dart:ui';

import 'render_state.dart';
import 'scene.dart';

/// Effets vivants du style Organique : ondes en goutte d'eau + notes.
/// État persistant, recalculé image par image, identique en lecture et export.
class OrganicFX {
  final _waves = <_Wave>[];
  final _notes = <_Note>[];
  final _rng = math.Random(0xFEED);
  double _clock = 0;
  double _lastWaveTime = -10;
  double _lastSquashTime = -10;

  void reset() {
    _waves.clear();
    _notes.clear();
    _lastWaveTime = -10;
    _lastSquashTime = -10;
  }

  /// Fait vivre ondes et notes pour l'image suivante. [unit] = min(W,H).
  void step(double dt, RenderState rs, {required double unit, required double height}) {
    _clock += dt;

    // --- Déclenchement des ondes : à chaque moindre coup de basse ---
    // rbDelta = rb - rb(image précédente), calculé par RenderState.step.
    final double rate = rs.rbDelta / math.max(dt, 0.008);
    if (rate > 5 &&
        rs.rb > rs.ka * 1.1 + 0.06 &&
        (_clock - _lastWaveTime) > 0.06 &&
        _waves.length < 24) {
      _lastWaveTime = _clock;
      for (int j = 0; j < 3; j++) {
        _waves.add(_Wave(
          delay: j * 0.1,
          strength: math.min(1.0, rs.rb * (1 - j * 0.18) + 0.1),
          phase: _rng.nextDouble() * math.pi * 2,
        ));
      }
    }
    for (final w in _waves) {
      w.age += dt;
    }
    _waves.removeWhere((w) => w.age - w.delay > 1.4);

    // --- Naissance des notes (max 120) ---
    final double birth = 2.5 + rs.loud * 9 + rs.rb * 4;
    double remaining = birth * dt;
    while (remaining > 1 && _notes.length < 120) {
      remaining -= 1;
      double tot = 0;
      for (int k = 0; k < 16; k++) {
        tot += rs.sm[k] * rs.sm[k] + 0.001;
      }
      double r = _rng.nextDouble() * tot;
      int k = 0;
      while (k < 15 && r > rs.sm[k] * rs.sm[k] + 0.001) {
        r -= rs.sm[k] * rs.sm[k] + 0.001;
        k++;
      }
      final double q = k / 15;
      _notes.add(_Note.random(_rng, q));
    }

    // --- Vie des notes ---
    for (final n in _notes) {
      n.age += dt;
      // Chute + accélération d'écrasement (+0,3·m/s).
      n.y += (n.vy + (n.squash > 0.05 ? 0.3 : 0)) * dt;
      n.x += n.vx * dt;
      n.rot += n.rotSpeed * dt;
      n.squash *= math.exp(-dt / 0.28);
    }
    _notes.removeWhere((n) =>
        n.age > n.life || n.y * unit > height + 0.1 * unit);

    // --- Écrasement : gros coup de basse suivi d'une chute rapide ---
    if (rs.hold > 0.85 &&
        rs.rb < rs.hold * 0.5 &&
        (_clock - _lastSquashTime) > 0.5) {
      _lastSquashTime = _clock;
      for (final n in _notes) {
        n.squash = 1;
        n.age += n.life * 0.22;
      }
    }
  }

  int get waveCount => _waves.length;
  int get noteCount => _notes.length;
}

/// Dessin du style Organique : colonnes, notes, disque, ondes.
/// Ordre : colonnes < notes < disque/ondes (les notes sont sous le disque
/// et les ondes, par-dessus les colonnes).
void drawOrganic(Scene s, Canvas canvas, Size size, OrganicFX fx) {
  final rs = s.rs;
  final double W = size.width, H = size.height, m = math.min(W, H);
  final double cx = W / 2, cy = H / 2, t = rs.t;
  final double cw = m * 0.07;
  final double gap = cw * (2.3 + rs.bx * 2.2);
  final double mx = m * 0.34;

  final Paint ink = s.inkPaint(Rect.fromLTWH(0, 0, W, H));
  final bool paletteOrOled = s.hasPalette || s.oled;

  // Couleur de fond (anneau intérieur du disque).
  Color bg;
  if (s.oled || !s.lightStyle) {
    bg = const Color(0xFF000000);
  } else if (s.hasPalette) {
    bg = s.palette.colors[1];
  } else {
    bg = kWhite;
  }

  // ---------- 2 groupes de 5 colonnes arrondies ----------
  for (int side = -1; side <= 1; side += 2) {
    for (int i = 0; i < 5; i++) {
      final int b = side < 0 ? i : i + 8;
      final double x =
          cx + side * (gap / 2 + cw / 2 + i * cw * 0.8) - cw / 2;
      final double haut = cw * 0.6 + math.min(1.05, rs.sm[b]) * mx;
      final double bas =
          cw * 0.6 + math.min(1.05, rs.sm[(b + 5) % 16]) * mx * 0.8;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, cy - haut, cw, haut + bas),
            Radius.circular(cw / 2)),
        ink,
      );
    }
  }

  // ---------- Notes (par-dessus les colonnes) ----------
  for (final n in fx._notes) {
    final double fadeIn = math.min(1.0, n.age * 2.5);
    double alpha = fadeIn;
    if (n.age > n.life * 0.55) {
      alpha = fadeIn * (1 - (n.age - n.life * 0.55) / (n.life * 0.45));
    }
    if (alpha <= 0) continue;
    final double resShift = (rs.res * 1 + rs.rb * 0.25) * m * 0.015;
    final double x = n.x * W +
        math.sin(t * 1.6 + n.phase) * n.sway * 6 * m +
        math.sin(t * 75 + 3 * n.phase) * resShift;
    final double y = n.y * m + math.cos(t * 61 + 2 * n.phase) * resShift;
    final double rot = n.rot + math.sin(t * 50 + n.phase) * rs.res * 0.08;
    final double scale = n.size * m * (1 + 0.1 * rs.rb);
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(rot);
    canvas.scale(scale * (1 + 0.7 * n.squash), scale * (1 - 0.6 * n.squash));
    _drawNoteGlyph(
        canvas,
        n.type,
        paletteOrOled
            ? _alpha(ink.color, alpha)
            : kWhite.withValues(alpha: alpha));
    canvas.restore();
  }

  // ---------- Disque central « haut-parleur de basse » ----------
  final double jf = rs.bx * 0.6 + rs.bx * rs.bx * 0.9;
  final double jx = math.sin(t * 83) * jf * cw * 0.15;
  final double jy = math.cos(t * 71) * jf * cw * 0.15;
  final double X = cx + jx, Y = cy + jy;
  final double r0 = cw * 0.42 * (1 + rs.bx * 1.9 + rs.md * 0.5);

  final discPath = Path();
  for (int i = 0; i <= 97; i++) {
    final double a = i / 97 * 2 * math.pi;
    final double r = r0 *
        (1 +
            0.26 * rs.sm[0] * math.cos(2 * a + t * 13) +
            0.20 * rs.sm[1] * math.cos(3 * a - t * 17) +
            0.16 * rs.sm[2] * math.cos(5 * a + t * 21) +
            0.05 * rs.sm[6] * math.cos(8 * a - t * 11) +
            0.06 * rs.sm[10] * math.cos(11 * a + t * 14) +
            0.07 * rs.hi * math.cos(14 * a + t * 25) +
            0.12 * rs.rb * math.cos(17 * a + t * 57) +
            0.07 * rs.rb * rs.rb * math.cos(29 * a + t * 83));
    final double px = X + r * math.cos(a);
    final double py = Y + r * math.sin(a);
    if (i == 0) {
      discPath.moveTo(px, py);
    } else {
      discPath.lineTo(px, py);
    }
  }
  discPath.close();
  canvas.drawPath(discPath, ink);
  canvas.drawCircle(
      Offset(X, Y),
      r0 * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cw * 0.05
        ..color = bg);
  canvas.drawCircle(Offset(X, Y), r0 * (0.26 + 0.1 * rs.bx), ink);

  // ---------- Ondes en goutte d'eau ----------
  final double r1 = r0 * 1.15;
  final wavePaint = Paint()..style = PaintingStyle.stroke;
  final wavePath = Path();
  for (final w in fx._waves) {
    final double ag = w.age - w.delay;
    if (ag < 0) continue;
    final double u = ag / 1.4;
    final double str = w.strength;
    final double R = r1 +
        (gap / 2 + cw * 1.6 - r1) * (0.7 + 0.3 * str) * (1 - (1 - u) * (1 - u));
    final double A = (0.04 + 0.13 * str * str) * (1 - 0.45 * u);
    final double fade = math.pow(1 - u, 1.4).toDouble() * (0.3 + 0.55 * str);
    for (int pass = 0; pass < 2; pass++) {
      wavePath.reset();
      for (int i = 0; i <= 73; i++) {
        final double a = i / 73 * 2 * math.pi;
        final double rr = (R + pass * cw * 0.1 * str) *
            (1 +
                A *
                    (0.6 * math.sin(7 * a + t * 46 + w.phase) +
                        0.4 * math.sin(13 * a - t * 63) +
                        0.3 * math.sin(23 * a + t * 85 + 2 * w.phase) +
                        0.2 * math.sin(37 * a - t * 97 + w.phase)));
        final double px = X + rr * math.cos(a);
        final double py = Y + rr * math.sin(a);
        if (i == 0) {
          wavePath.moveTo(px, py);
        } else {
          wavePath.lineTo(px, py);
        }
      }
      wavePath.close();
      wavePaint
        ..strokeWidth =
            cw * (0.14 - 0.08 * u) * (1 + 0.4 * str * math.sin(t * 79 + w.phase))
        ..blendMode = paletteOrOled ? BlendMode.srcOver : BlendMode.difference
        ..color = paletteOrOled
            ? _alpha(ink.color, fade)
            : kWhite.withValues(alpha: fade);
      canvas.drawPath(wavePath, wavePaint);
    }
  }
}

Color _alpha(Color c, double a) => Color.fromRGBO(
    (c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round(),
    a.clamp(0.0, 1.0).toDouble());

/// Dessin vectoriel des 5 types de notes (aucune police embarquée).
void _drawNoteGlyph(Canvas canvas, int type, Color color) {
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.07
    ..strokeCap = StrokeCap.round
    ..color = color;
  final fill = Paint()..color = color;
  const double hx = 0.3, hy = 0.21, stemTop = -1.15;

  void head() {
    // Tête : ellipse inclinée de -0,45 rad.
    canvas.save();
    canvas.rotate(-0.45);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: hx * 2, height: hy * 2),
        type == 3 ? stroke : fill);
    canvas.restore();
    // Hampe.
    canvas.drawLine(const Offset(hx, -hy * 0.2), const Offset(hx, stemTop), stroke);
  }

  switch (type) {
    case 0: // croche : tête, hampe, un crochet
      head();
      canvas.drawPath(
        Path()
          ..moveTo(hx, stemTop)
          ..quadraticBezierTo(hx - 0.45, stemTop + 0.35, hx - 0.15, stemTop + 0.7),
        stroke,
      );
      break;
    case 1: // paire de croches liées : deux têtes, deux hampes, barre
      head();
      canvas.save();
      canvas.translate(0.9, 0.05);
      head();
      canvas.restore();
      canvas.drawLine(const Offset(0, stemTop), const Offset(0.9, stemTop + 0.05), stroke);
      break;
    case 2: // noire
      head();
      break;
    case 3: // blanche : tête creuse
      head();
      break;
    case 4: // double croche : deux crochets
      head();
      canvas.drawPath(
        Path()
          ..moveTo(hx, stemTop)
          ..quadraticBezierTo(hx - 0.45, stemTop + 0.25, hx - 0.15, stemTop + 0.45)
          ..quadraticBezierTo(hx - 0.45, stemTop + 0.55, hx - 0.15, stemTop + 0.8),
        stroke,
      );
      break;
  }
}

class _Wave {
  double age = 0;
  final double delay;
  final double strength;
  final double phase;
  _Wave({required this.delay, required this.strength, required this.phase});
}

class _Note {
  double x, y, vx, vy; // x fraction de largeur, y en unités de m = min(W,H)
  final double size;
  final int type;
  double rot;
  final double rotSpeed;
  final double phase;
  final double sway;
  final double life;
  double age = 0;
  double squash = 0;

  _Note({
    required this.x, required this.y, required this.vx, required this.vy,
    required this.size, required this.type, required this.rot,
    required this.rotSpeed, required this.phase, required this.sway,
    required this.life,
  });

  /// Naissance : 55 % en haut, 45 % sur les côtés (§8.3).
  factory _Note.random(math.Random rng, double q) {
    final bool top = rng.nextDouble() < 0.55;
    double x, y, vx;
    double speedMul;
    if (top) {
      x = rng.nextDouble();
      y = -0.08;
      vx = (rng.nextDouble() - 0.5) * 2 * 0.05;
      speedMul = 0.7 + rng.nextDouble() * 0.6;
    } else {
      final bool left = rng.nextBool();
      x = left ? -0.05 : 1.05;
      y = rng.nextDouble() * 0.6;
      vx = left ? 0.04 + rng.nextDouble() * 0.10 : -(0.04 + rng.nextDouble() * 0.10);
      speedMul = 0.4 + rng.nextDouble() * 0.5;
    }
    final double vy = (0.16 + 0.2 * q) * speedMul;
    int type;
    if (q < 0.25) {
      type = rng.nextBool() ? 2 : 3;
    } else if (q < 0.6) {
      type = rng.nextBool() ? 0 : 1;
    } else {
      type = rng.nextBool() ? 4 : 0;
    }
    return _Note(
      x: x, y: y, vx: vx, vy: vy,
      size: (0.075 - 0.04 * q) * (0.8 + rng.nextDouble() * 0.5),
      type: type,
      rot: (rng.nextDouble() - 0.5) * 0.8,
      rotSpeed: (rng.nextDouble() - 0.5) * (0.6 + q),
      phase: rng.nextDouble() * math.pi * 2,
      sway: 0.02 + rng.nextDouble() * 0.02,
      life: 4 + rng.nextDouble() * 2.5,
    );
  }
}
