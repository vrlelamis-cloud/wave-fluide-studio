import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show Alignment, LinearGradient;

import 'organic.dart';
import 'palettes.dart';
import 'render_state.dart';

export 'palettes.dart';

enum VizStyle { neon, capsules, organique, bleu, fluide }

/// Tout ce qu'il faut pour dessiner une image de la scène.
class Scene {
  final RenderState rs;
  final VizStyle style;
  final int paletteIndex; // 0 = Origine (aucune palette)
  final bool oled;
  final double p; // Espace paroles 0..0.6
  Scene({
    required this.rs,
    required this.style,
    required this.paletteIndex,
    required this.oled,
    required this.p,
  });

  Palette get palette => kPalettes[paletteIndex];
  bool get hasPalette => paletteIndex > 0;
  bool get lightStyle => style == VizStyle.capsules ||
      style == VizStyle.organique || style == VizStyle.bleu;

  /// Peinture d'encre (formes) selon les règles du §6.
  Paint inkPaint(Rect bounds) {
    final paint = Paint()..style = PaintingStyle.fill;
    if (hasPalette) {
      if (oled) {
        // Dégradé éclairci vertical sur 15 % à 85 % de la hauteur.
        paint.shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: palette.colors.map(lighten).toList(),
        ).createShader(Rect.fromLTRB(
            bounds.left, bounds.top + bounds.height * 0.15,
            bounds.right, bounds.top + bounds.height * 0.85));
      } else if (lightStyle) {
        final lum = paletteLuminance(palette);
        paint.color = lum > 0.33 ? kInkDark : kWhite;
      } else {
        paint.color = kWhite;
      }
    } else {
      if (oled) {
        paint.color = style == VizStyle.bleu ? kBlueOled : kWhite;
      } else if (style == VizStyle.organique) {
        paint.color = const Color(0xFF000000);
      } else if (style == VizStyle.bleu) {
        paint.color = const Color(0xFF0000A8);
      } else {
        paint.color = kWhite;
      }
    }
    return paint;
  }
}

/// Fond de l'image selon le style / palette / OLED (§6).
void paintBackground(Scene s, Canvas canvas, Size size) {
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);
  if (s.oled || !s.lightStyle) {
    canvas.drawRect(rect, Paint()..color = const Color(0xFF000000));
    return;
  }
  if (s.hasPalette) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: s.palette.colors,
        ).createShader(rect),
    );
    return;
  }
  late Color c;
  switch (s.style) {
    case VizStyle.capsules:
      c = const Color(0xFF1B1BFF);
      break;
    case VizStyle.organique:
      c = const Color(0xFFFFFFFF);
      break;
    case VizStyle.bleu:
      c = const Color(0xFFFFFFFF);
      break;
    default:
      c = const Color(0xFF000000);
  }
  canvas.drawRect(rect, Paint()..color = c);
}

/// Dessine la scène complète. Sert à l'affichage ET à l'export vidéo.
/// Aucun titre de morceau, aucun texte ni barre de progression ne sont dessinés.
void drawScene(Scene s, Canvas canvas, Size size, OrganicFX organic) {
  paintBackground(s, canvas, size);
  final double H = size.height;

  // Espace paroles : bord gauche et centre vertical comme point fixe.
  if (s.p > 0) {
    canvas.save();
    final double k = 1 - s.p;
    canvas.translate(0, H / 2);
    canvas.scale(k, k);
    canvas.translate(0, -H / 2);
  }

  switch (s.style) {
    case VizStyle.neon:
      drawNeon(s, canvas, size);
      break;
    case VizStyle.capsules:
      drawCapsules(s, canvas, size);
      break;
    case VizStyle.organique:
      drawOrganic(s, canvas, size, organic);
      break;
    case VizStyle.bleu:
      drawBlue(s, canvas, size);
      break;
    case VizStyle.fluide:
      drawFluide(s, canvas, size);
      break;
  }

  if (s.p > 0) canvas.restore();
}

// ------------------------- 8.1 Néon -------------------------
void drawNeon(Scene s, Canvas canvas, Size size) {
  final rs = s.rs;
  final double W = size.width, H = size.height, m = math.min(W, H);
  final double cy = H / 2, t = rs.t;

  final ys1 = List<double>.filled(171, 0);
  final ys2 = List<double>.filled(171, 0);
  for (int j = 0; j <= 170; j++) {
    final double u = j / 170 * 2 - 1;
    final double env = math.exp(-3.4 * u * u);
    final int wi = (j * 127 / 170).toInt().clamp(0, 127).toInt();
    final double w = rs.wave[wi];
    final double sv = (w + 0.06 * math.sin(j * 0.25 + t * 2)) * 2.2;
    final double base =
        cy - H * 0.3 * math.min(1.2, rs.loud * 2.2 + 0.05) * env * sv;
    ys1[j] = base - m * 0.42 * rs.bass * math.exp(-160 * u * u);
    final double u2 = u - 0.07;
    ys2[j] = base * 0.9 + cy * 0.1 + m * 0.3 * rs.bass * math.exp(-220 * u2 * u2);
  }

  final path = Path();
  void build(List<double> ys, double dx) {
    path.reset();
    for (int j = 0; j <= 170; j++) {
      final double x = j / 170 * W + dx;
      if (j == 0) {
        path.moveTo(x, ys[0]);
      } else {
        path.lineTo(x, ys[j]);
      }
    }
  }

  final widths = [0.05, 0.026, 0.012, 0.012, 0.012, 0.004];
  final offsets = [0.0, 0.0, 0.0, 0.006, -0.006, 0.0];
  final alphas = [0.10, 0.22, 0.55, 0.22, 0.22, 0.95];
  List<Color> colors;
  if (s.hasPalette) {
    final c0 = lighten(s.palette.colors[0]);
    final c1 = lighten(s.palette.colors[1]);
    final c2 = lighten(s.palette.colors[2]);
    colors = [c0, c1, c2, c2, c0, kWhite];
  } else {
    colors = [
      const Color(0xFF1E5AFF), const Color(0xFF3C8CFF),
      const Color(0xFF82C8FF), const Color(0xFF00FFC8),
      const Color(0xFFAA5AFF), kWhite,
    ];
  }

  final paint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke
    ..blendMode = BlendMode.plus; // fusion additive, pas de flou

  for (int c = 0; c < widths.length; c++) {
    for (int curve = 0; curve < 2; curve++) {
      build(curve == 0 ? ys1 : ys2, offsets[c] * m);
      paint
        ..strokeWidth = widths[c] * m
        ..color = colors[c].withValues(alpha: alphas[c]);
      canvas.drawPath(path, paint);
    }
  }
}

// ------------------------- 8.2 Capsules -------------------------
void drawCapsules(Scene s, Canvas canvas, Size size) {
  final rs = s.rs;
  final double W = size.width, H = size.height, m = math.min(W, H);
  final double cy = H / 2;
  final double pw = m * 0.105, step = pw * 1.04;
  const map = [5, 7, 1, 0, 3, 6];
  final double y0 = cy - m * 0.3;
  final double x0 = W / 2 - (5 * step + pw) / 2;

  final Paint? ink = (s.hasPalette || s.oled)
      ? s.inkPaint(Rect.fromLTWH(0, 0, W, H))
      : null;

  for (int i = 0; i < 6; i++) {
    final double h = pw * 1.2 + math.min(1.05, rs.sm[map[i]]) * m * 0.55;
    final rect = Rect.fromLTWH(x0 + i * step, y0, pw, h);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(pw / 2));
    if (ink != null) {
      canvas.drawRRect(rrect, ink);
    } else if (i.isEven) {
      // Blanc plein jusqu'à 38 %, blanc 42 % α à 78 %, presque transparent ensuite.
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.38, 0.78, 1],
            colors: [
              kWhite,
              kWhite,
              kWhite.withValues(alpha: 0.42),
              kWhite.withValues(alpha: 0.08),
            ],
          ).createShader(rect),
      );
    } else {
      // Impairs : l'inverse (transparent en haut, plein à partir de 62 %).
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.62, 1],
            colors: [
              kWhite.withValues(alpha: 0.08),
              kWhite.withValues(alpha: 0.42),
              kWhite,
            ],
          ).createShader(rect),
      );
    }
  }
}

// ------------------------- 8.4 Bleu -------------------------
void drawBlue(Scene s, Canvas canvas, Size size) {
  final rs = s.rs;
  final double W = size.width, H = size.height, m = math.min(W, H);
  final double cy = H / 2;
  final double bw = m * 0.085, step = bw * 1.3;
  const map = [6, 3, 0, 1, 4, 7];
  const off = [0.0, -0.55, -1.0, 0.75, 0.5, 0.0];
  final double x0 = W / 2 - (5 * step + bw) / 2;
  final Paint paint = (s.hasPalette || s.oled)
      ? s.inkPaint(Rect.fromLTWH(0, 0, W, H))
      : (Paint()..color = s.oled ? kBlueOled : const Color(0xFF0000A8));

  for (int i = 0; i < 6; i++) {
    final double h = bw * 0.9 + math.min(1.05, rs.sm[map[i]]) * m * 0.5;
    final double centerY = cy + off[i] * m * 0.1 * (0.3 + rs.sm[map[i]]);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(x0 + i * step, centerY - h / 2, bw, h),
          Radius.circular(bw / 2)),
      paint,
    );
  }
}

// ------------------------- 8.5 Fluide -------------------------
void drawFluide(Scene s, Canvas canvas, Size size) {
  final rs = s.rs;
  final double W = size.width, H = size.height;
  final double cy = H / 2;
  final double bw = math.min(W / 15 / 1.9, 46.0);
  final double step = bw * 1.9;

  Color top, mid, bottom;
  if (s.hasPalette) {
    top = lighten(s.palette.colors[0]);
    mid = lighten(s.palette.colors[1]);
    bottom = lighten(s.palette.colors[2]);
  } else {
    top = const Color(0xFFD4FF6A);
    mid = const Color(0xFF2BE3A0);
    bottom = const Color(0xFF12B7D4);
  }

  // 15 barres blanches symétriques + halo vert translucide derrière.
  final halo = Paint()..color = const Color(0xFF2BE3A0).withValues(alpha: 0.13);
  final Paint white = (s.oled && s.hasPalette)
      ? s.inkPaint(Rect.fromLTWH(0, 0, W, H))
      : (Paint()..color = kWhite);
  for (int i = -7; i <= 7; i++) {
    final int b = (i.abs() * 2).clamp(0, 15).toInt();
    final double h = bw + math.min(1.05, rs.sm[b]) * (0.6 * H - bw);
    final double x = W / 2 + i * step - bw / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(x - bw * 0.35, cy - h / 2 - bw * 0.35,
              bw * 1.7, h + bw * 0.7),
          Radius.circular(bw)),
      halo,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(x, cy - h / 2, bw, h), Radius.circular(bw / 2)),
      white,
    );
  }

  // 3 rubans lissés, Catmull-Rom -> Bézier, fusion additive.
  final scales = [1.0, 0.74, 0.5];
  final phases = [0.0, 1.7, 3.1];
  final opac = [0.38, 0.26, 0.18];
  for (int r = 0; r < 3; r++) {
    final path = Path();
    final double sc = scales[r], ph = phases[r];
    final shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [top, mid, bottom],
    ).createShader(Rect.fromLTWH(0, cy - H * 0.35, W, H * 0.7));
    final ribbon = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = bw * 0.16
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus
      ..shader = shader;

    double px = 0, py = 0;
    for (int i = -7; i <= 7; i++) {
      final double wob = 1 + 0.07 * math.sin(rs.t * 2.1 + i * 0.8 + ph);
      final int b = (i.abs() * 2).clamp(0, 15).toInt();
      final double h = bw + math.min(1.05, rs.sm[b]) * (0.6 * H - bw);
      final double x = W / 2 + i * step * sc;
      final double y = cy - (h / 2) * wob * sc;
      if (i == -7) {
        path.moveTo(x, y);
      } else {
        path.quadraticBezierTo((px + x) / 2, py, x, y);
      }
      px = x; py = y;
    }
    // L'opacité propre à chaque ruban.
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = kWhite.withValues(alpha: opac[r]));
    canvas.drawPath(path, ribbon);
    canvas.restore();
  }
}
