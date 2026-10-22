import 'dart:math' as math;
import 'dart:ui';

/// Les 9 palettes (§6). L'index 0 (« Origine ») = aucune palette.
class Palette {
  final String name;
  final List<Color> colors; // 3 couleurs haut/milieu/bas
  const Palette(this.name, this.colors);
}

Color _hex(String h) => Color(int.parse('FF' + h.replaceFirst('#', ''), radix: 16));

Color _mix(Color a, Color b, double u) => Color.fromRGBO(
    ((a.r * (1 - u) + b.r * u) * 255).round(),
    ((a.g * (1 - u) + b.g * u) * 255).round(),
    ((a.b * (1 - u) + b.b * u) * 255).round(),
    1);

/// Pour les palettes à 2 couleurs, la teinte du milieu = mélange à 50 %.
List<Palette> kPalettes = [
  const Palette('Origine', []),
  Palette('Flowerbed', [_hex('#2BA6CF'), _hex('#4F4FB3'), _hex('#AD1D8C')]),
  Palette('Pink Crush', [_hex('#C2138D'), _mix(_hex('#C2138D'), _hex('#F7B28D'), 0.5), _hex('#F7B28D')]),
  Palette('Sunset', [_hex('#FFE45C'), _mix(_hex('#FFE45C'), _hex('#FC79A3'), 0.5), _hex('#FC79A3')]),
  Palette('Sublime Leaves', [_hex('#389B0F'), _hex('#6FD10D'), _hex('#F6FC77')]),
  Palette('New Life', [_hex('#49C949'), _hex('#317A7A'), _hex('#363670')]),
  Palette('Yellow Sky', [_hex('#7ADEFF'), _hex('#EEE18B'), _hex('#FAC657')]),
  Palette('Endless Blue', [_hex('#0575E6'), _mix(_hex('#0575E6'), _hex('#021B79'), 0.5), _hex('#021B79')]),
  Palette('Precious Blue', [_hex('#0078A1'), _mix(_hex('#0078A1'), _hex('#9EB541'), 0.5), _hex('#9EB541')]),
];

const Color kWhite = Color(0xFFFFFFFF);
const Color kInkDark = Color(0xFF0B0B24);
const Color kBlueOled = Color(0xFF4D4DFF);

/// Version éclaircie : mélange à 30 % avec le blanc.
Color lighten(Color c) => _mix(c, kWhite, 0.30);

/// Luminance relative moyenne (sRGB) des 3 couleurs de la palette.
double paletteLuminance(Palette p) {
  double lum(Color c) {
    double f(double x) {
      x /= 255;
      return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
    }
    return 0.2126 * f(c.r * 255) + 0.7152 * f(c.g * 255) + 0.0722 * f(c.b * 255);
  }
  if (p.colors.isEmpty) return 0;
  double s = 0;
  for (final c in p.colors) {
    s += lum(c);
  }
  return s / p.colors.length;
}
