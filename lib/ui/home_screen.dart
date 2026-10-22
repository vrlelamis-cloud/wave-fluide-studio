import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../render/palettes.dart';
import '../render/scene.dart';
import 'app_state.dart';

/// Écran unique (portrait) : en-tête, zone d'animation, panneau du bas.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final controller = AppController();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _previewLongSide = 1280; // réduction auto si < 45 ips
  final List<double> _fpsWindow = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    WakelockPlus.enable(); // écran allumé pendant lecture et export
  }

  void _onTick(Duration elapsed) {
    final double dt = _last == Duration.zero
        ? 1 / 60
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    controller.tick(dt.clamp(0.001, 0.1).toDouble());
    if (dt > 0) _fpsWindow.add(dt);
    if (_fpsWindow.length > 120) {
      _fpsWindow.removeAt(0);
      final avg = _fpsWindow.reduce((a, b) => a + b) / _fpsWindow.length;
      if (1 / avg < 45 && _previewLongSide > 640) {
        _previewLongSide = 720;
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    controller.setScreenSize(media.size.width, media.size.height);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildAnimationArea()),
                _buildPanel(context, media),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------- En-tête -------------------------
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(colors: [
                Color(0xFFC6FF5A), Color(0xFF2BE3A0), Color(0xFF12B7D4),
              ]).createShader(r),
              child: Text(
                'Wave Fluide Studio',
                style: TextStyle(
                  fontFamily: 'Righteous',
                  fontSize: 22,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontSize: 12,
                color: Color(0xFF9AA3AF),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------- Zone d'animation -------------------------
  Widget _buildAnimationArea() {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScenePainter(
          controller: controller,
          longSide: _previewLongSide,
          aspect: controller.format.width / controller.format.height,
          repaint: controller.repaint,
        ),
      ),
    );
  }

  // ------------------------- Panneau du bas -------------------------
  Widget _buildPanel(BuildContext context, MediaQueryData media) {
    final disabled = controller.exporting;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF000000),
        border: Border(top: BorderSide(color: Color(0xFF1C1F26), width: 1)),
      ),
      constraints: BoxConstraints(
        maxHeight: media.size.height * 0.52, // hauteur max 52 %
      ),
      child: SingleChildScrollView(
        child: Opacity(
          opacity: disabled ? 0.35 : 1, // tous les contrôles à 35 % pendant l'export
          child: IgnorePointer(
            ignoring: disabled,
            child: Column(
              children: [
                _buildSeekBar(),
                _buildControls(),
                _buildPlaylist(),
                _buildSlider(
                  label: 'Espace paroles',
                  value: controller.espaceParoles.toDouble(),
                  min: 0, max: 60, divisions: 12,
                  display: controller.espaceParoles.toString() + ' %',
                  onChanged: (v) {
                    controller.espaceParoles = v.round();
                    controller.update();
                  },
                ),
                _buildSlider(
                  label: 'Décalage vidéo',
                  value: controller.decalageVideo.toDouble(),
                  min: -120, max: 120, divisions: 48,
                  display: controller.decalageVideo.toString() + ' ms',
                  onChanged: (v) {
                    controller.decalageVideo = v.round();
                    controller.update();
                  },
                ),
                _buildSlider(
                  label: 'Synchro',
                  value: controller.synchro.toDouble(),
                  min: -50, max: 400, divisions: 45,
                  display: controller.synchro.toString() + ' ms',
                  onChanged: (v) {
                    controller.synchro = v.round();
                    controller.update();
                  },
                ),
                _buildColors(),
                _buildStyles(),
                _buildFormats(),
                _buildExtrait(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "L'extrait démarre à la position actuelle du morceau",
                      style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                    ),
                  ),
                ),
                _buildExportButton(),
                if (controller.exportedPath != null) _buildResult(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Barre de position + temps écoulé / durée.
  Widget _buildSeekBar() {
    final dur = controller.duration;
    final pos = controller.position.clamp(0.0, dur).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [
        SliderTheme(
          data: const SliderThemeData(
            activeTrackColor: Color(0xFF2BE3A0),
            thumbColor: Color(0xFF2BE3A0),
            inactiveTrackColor: Color(0xFF1C1F26),
          ),
          child: Slider(
            value: dur <= 0 ? 0 : pos,
            max: dur <= 0 ? 1 : dur,
            onChanged: dur <= 0 ? null : (v) => controller.seek(v),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(_fmtTime(pos),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3AF))),
          Text(_fmtTime(dur),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3AF))),
        ]),
      ]),
    );
  }

  String _fmtTime(double s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s.round() % 60).toString().padLeft(2, '0');
    return m + ':' + sec;
  }

  Widget _buildControls() {
    final playing = controller.player.playing;
    const accent = Color(0xFF2BE3A0);
    Widget circle(IconData icon, String label, VoidCallback onTap,
        {double size = 48, Color? bg, Color? fg}) {
      return Semantics(
        label: label,
        button: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: size, height: size,
            decoration: BoxDecoration(
              color: bg ?? const Color(0xFF15181E),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: fg ?? accent, size: size * 0.45),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          circle(Icons.skip_previous, 'Morceau précédent', controller.prev),
          const SizedBox(width: 20),
          circle(
            playing ? Icons.pause : Icons.play_arrow,
            playing ? 'Pause' : 'Lecture',
            controller.playPause,
            size: 64,
            bg: Colors.white,
            fg: Colors.black,
          ),
          const SizedBox(width: 20),
          circle(Icons.skip_next, 'Morceau suivant', controller.next),
          const SizedBox(width: 20),
          circle(Icons.upload, 'Importer de la musique', controller.importFiles),
        ],
      ),
    );
  }

  Widget _buildPlaylist() {
    if (controller.names.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: math.min(120.0, controller.names.length * 40.0),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: controller.names.length,
        itemBuilder: (context, i) {
          final active = i == controller.current;
          final name =
              controller.names[i].replaceAll(RegExp('\\.[^.]+\$'), '');
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              (i + 1).toString() + '. ' + name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'Poppins',
                color:
                    active ? const Color(0xFF2BE3A0) : const Color(0xFFC7CBD1),
              ),
            ),
            onTap: () => controller.selectTrack(i),
            tileColor: active ? const Color(0x142BE3A0) : null,
            shape: active
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFF2BE3A0)))
                : null,
          );
        },
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFFC7CBD1))),
          Text(display,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3AF))),
        ]),
        SliderTheme(
          data: const SliderThemeData(
            activeTrackColor: Color(0xFF2BE3A0),
            thumbColor: Color(0xFF2BE3A0),
            inactiveTrackColor: Color(0xFF1C1F26),
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }

  // Ligne Couleurs : 9 pastilles de 44 dp + nom de la palette.
  Widget _buildColors() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Couleurs',
              style: TextStyle(fontSize: 12, color: Color(0xFFC7CBD1))),
          const SizedBox(width: 12),
          Text(kPalettes[controller.paletteIndex].name,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3AF))),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (int i = 0; i < kPalettes.length; i++) _swatch(i)],
          ),
        ),
      ]),
    );
  }

  Widget _swatch(int i) {
    final p = kPalettes[i];
    final selected = controller.paletteIndex == i;
    return Semantics(
      label: 'Palette ' + p.name,
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () {
          controller.paletteIndex = i;
          controller.update();
        },
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: p.colors.isEmpty
                ? const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [Color(0xFFC6FF5A), Color(0xFF12B7D4)])
                : LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: p.colors),
            border: Border.all(
              color: selected ? Colors.white : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStyles() {
    final names = ['Néon', 'Capsules', 'Organique', 'Bleu', 'Fluide'];
    final values = VizStyle.values;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (int i = 0; i < names.length; i++)
            ChoiceChip(
              label: Text(names[i],
                  style: const TextStyle(fontSize: 12, fontFamily: 'Poppins')),
              selected: controller.style == values[i],
              selectedColor: const Color(0xFF2BE3A0),
              backgroundColor: const Color(0xFF15181E),
              labelStyle: TextStyle(
                color: controller.style == values[i]
                    ? Colors.black
                    : Colors.white,
              ),
              onSelected: (_) {
                controller.style = values[i];
                controller.update();
              },
            ),
          FilterChip(
            label: const Text('Fond noir OLED',
                style: TextStyle(fontSize: 12, fontFamily: 'Poppins')),
            selected: controller.oled,
            selectedColor: Colors.white,
            backgroundColor: const Color(0xFF15181E),
            labelStyle: TextStyle(
                color: controller.oled ? Colors.black : Colors.white),
            onSelected: (v) {
              controller.oled = v;
              controller.update();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFormats() {
    final fmts = ['9:16', '16:9', 'TikTok HD', 'Plein écran'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Format',
            style: TextStyle(fontSize: 12, color: Color(0xFFC7CBD1))),
        Wrap(spacing: 8, children: [
          for (int i = 0; i < fmts.length; i++)
            ChoiceChip(
              label: Text(fmts[i], style: const TextStyle(fontSize: 12)),
              selected: controller.formatIndex == i,
              selectedColor: const Color(0xFF2BE3A0),
              backgroundColor: const Color(0xFF15181E),
              labelStyle: TextStyle(
                  color:
                      controller.formatIndex == i ? Colors.black : Colors.white),
              onSelected: (_) {
                controller.formatIndex = i;
                controller.update();
              },
            ),
        ]),
      ]),
    );
  }

  Widget _buildExtrait() {
    final items = <int, String>{15: '15 s', 30: '30 s', 60: '60 s', -1: 'Complet'};
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Extrait',
            style: TextStyle(fontSize: 12, color: Color(0xFFC7CBD1))),
        Wrap(spacing: 8, children: [
          for (final e in items.entries)
            ChoiceChip(
              label: Text(e.value, style: const TextStyle(fontSize: 12)),
              selected: controller.extraitSec == e.key,
              selectedColor: const Color(0xFF2BE3A0),
              backgroundColor: const Color(0xFF15181E),
              labelStyle: TextStyle(
                  color: controller.extraitSec == e.key
                      ? Colors.black
                      : Colors.white),
              onSelected: (_) {
                controller.extraitSec = e.key;
                controller.update();
              },
            ),
        ]),
      ]),
    );
  }

  Widget _buildExportButton() {
    if (controller.exporting) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(controller.exportLabel,
              style:
                  const TextStyle(fontSize: 13, color: Color(0xFFC7CBD1))),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: controller.cancelExport,
              child: const Text("Annuler l'export"),
            ),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFF2BE3A0)),
          onPressed:
              controller.features == null ? null : controller.startExport,
          child: const Text('Exporter la vidéo',
              style: TextStyle(color: Colors.black, fontFamily: 'Poppins')),
        ),
      ),
    );
  }

  // Zone résultat : aperçu + Enregistrer + Partager + Fermer.
  Widget _buildResult() {
    return _ResultZone(
        path: controller.exportedPath!, controller: controller);
  }
}

/// Peintre de la scène : même fonction draw que l'export, repeint à
/// chaque image par le ValueNotifier (via repaint:), dans un RepaintBoundary.
class _ScenePainter extends CustomPainter {
  final AppController controller;
  final double longSide;
  final double aspect;
  _ScenePainter({
    required this.controller,
    required this.longSide,
    required this.aspect,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  bool shouldRepaint(covariant _ScenePainter old) =>
      old.longSide != longSide || old.aspect != aspect;

  @override
  void paint(Canvas canvas, Size size) {
    // Fond noir pur (OLED).
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final scene = Scene(
      rs: controller.rs,
      style: controller.style,
      paletteIndex: controller.paletteIndex,
      oled: controller.oled,
      p: controller.espaceParoles / 100.0,
    );
    // Résolution interne selon le format, côté long limité (petits écrans).
    double w, h;
    if (aspect >= 1) {
      w = math.min(longSide, size.width * 2);
      h = w / aspect;
    } else {
      h = math.min(longSide, size.height * 2);
      w = h * aspect;
    }
    // object-fit: contain.
    final double scale = math.min(size.width / w, size.height / h);
    canvas.save();
    canvas.translate(
        (size.width - w * scale) / 2, (size.height - h * scale) / 2);
    canvas.scale(scale, scale);
    drawScene(scene, canvas, Size(w, h), controller.fx);
    canvas.restore();
  }
}

/// Aperçu vidéo + boutons Enregistrer / Partager / Fermer.
class _ResultZone extends StatefulWidget {
  final String path;
  final AppController controller;
  const _ResultZone({required this.path, required this.controller});
  @override
  State<_ResultZone> createState() => _ResultZoneState();
}

class _ResultZoneState extends State<_ResultZone> {
  VideoPlayerController? _vc;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    final vc = VideoPlayerController.file(File(widget.path));
    _vc = vc;
    vc.initialize().then((_) {
      if (mounted) setState(() {});
      vc.play();
      vc.setLooping(true);
    });
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      // Copie dans Movies/WaveFluide via MediaStore.
      await Gal.putVideo(widget.path, album: 'WaveFluide');
      setState(() => _msg = 'Enregistré dans Movies/WaveFluide');
    } catch (e) {
      setState(() => _msg = "Erreur d'enregistrement : stockage plein ou indisponible");
    }
  }

  Future<void> _share() async {
    try {
      // API share_plus 10.x.
      await Share.shareXFiles([XFile(widget.path)], mime: 'video/mp4');
    } catch (e) {
      setState(() => _msg = 'Partage impossible');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        if (vc != null && vc.value.isInitialized)
          AspectRatio(aspectRatio: vc.value.aspectRatio, child: VideoPlayer(vc)),
        const SizedBox(height: 8),
        if (_msg.isNotEmpty)
          Text(_msg,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA3AF))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: _save,
              child: const Text('Enregistrer sur le téléphone'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _share,
              child: const Text('Partager'),
            ),
          ),
        ]),
        TextButton(
          onPressed: widget.controller.closeResult,
          child: const Text('Fermer'),
        ),
      ]),
    );
  }
}
