import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/decoder.dart';
import '../audio/features.dart';
import '../audio/player_clock.dart';
import '../export/exporter.dart';
import '../render/organic.dart';
import '../render/render_state.dart';
import '../render/scene.dart';

/// État global de l'application (ChangeNotifier simple).
class AppController extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  late final PlayerClock clock = PlayerClock(player);

  // Playlist
  final List<String> paths = [];
  final List<String> names = [];
  int current = -1;

  // Analyse
  TrackFeatures? features;
  bool analyzing = false;
  String status = 'Importez de la musique pour commencer';

  // Réglages (valeurs par défaut du cahier des charges)
  int espaceParoles = 40;     // 0..60 %, pas 5
  int decalageVideo = 0;      // -120..120 ms, pas 5
  int synchro = 0;            // -50..400 ms, pas 10
  int paletteIndex = 0;       // 0 = Origine
  bool oled = true;
  VizStyle style = VizStyle.fluide;
  int formatIndex = 0;        // 9:16, 16:9, TikTok HD, Plein écran
  int extraitSec = 30;        // 15, 30, 60, -1 = complet

  // Export
  bool exporting = false;
  double exportProgress = 0;
  String exportLabel = '';
  String? exportedPath;
  VideoExporter? exporter;

  // Moteur d'animation (commun affichage / export)
  final RenderState rs = RenderState();
  final OrganicFX fx = OrganicFX();
  final FrameView fv = FrameView();
  final ValueNotifier<int> repaint = ValueNotifier<int>(0);
  final serviceChannel = const MethodChannelX();

  ExportFormat get format {
    switch (formatIndex) {
      case 0: return ExportFormat.f9x16;
      case 1: return ExportFormat.f16x9;
      case 2: return ExportFormat.tiktokHd;
      default:
        return ExportFormat.fullscreen(
            _screenW.toInt(), _screenH.toInt());
    }
  }

  double _screenW = 1080, _screenH = 1920;
  void setScreenSize(double w, double h) { _screenW = w; _screenH = h; }

  // ------------------------------------------------------------------
  // Import et playlist
  // ------------------------------------------------------------------
  Future<void> importFiles() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'amr', '3gp'
      ],
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;
    final added = <String>[];
    for (final f in res.files) {
      final p = f.path;
      if (p != null && File(p).existsSync()) {
        paths.add(p);
        names.add(f.name);
        added.add(p);
      }
    }
    if (added.isEmpty) {
      status = 'Aucun fichier importé';
    } else {
      status = '${added.length} morceau(s) importé(s)';
      await _rebuildPlaylist(startIndex: current < 0 ? paths.length - added.length : current);
    }
    notifyListeners();
  }

  Future<void> _rebuildPlaylist({int startIndex = 0}) async {
    try {
      final sources = <AudioSource>[];
      for (final p in paths) {
        sources.add(AudioSource.uri(Uri.file(p)));
      }
      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: startIndex < 0 ? 0 : startIndex,
      );
      current = startIndex < 0 ? 0 : startIndex;
    } catch (e) {
      status = 'Fichier illisible';
    }
    player.currentIndexStream.listen((i) {
      if (i != null && i != current) {
        current = i;
        _loadFeatures();
        notifyListeners();
      }
    });
    player.playerStateStream.listen((s) {
      notifyListeners();
    });
  }

  String get currentName =>
      current >= 0 && current < names.length
          ? names[current].replaceAll(RegExp(r'\.[^.]+$'), '')
          : '';

  // ------------------------------------------------------------------
  // Analyse du morceau courant
  // ------------------------------------------------------------------
  Future<void> _loadFeatures() async {
    if (current < 0 || current >= paths.length) return;
    analyzing = true;
    status = 'Analyse du morceau…';
    notifyListeners();
    final path = paths[current];
    try {
      final wav = await Decoder.toWav(path);
      features = await Decoder.analyze(wav);
      // Le WAV intermédiaire peut être supprimé.
      try { File(wav).deleteSync(); } catch (_) {}
      rs.reset();
      fx.reset();
      status = 'Prêt : ${names[current]}';
    } catch (e) {
      features = null;
      status = 'Fichier illisible ou format non pris en charge';
    }
    analyzing = false;
    notifyListeners();
  }

  Future<void> selectTrack(int i) async {
    if (i < 0 || i >= paths.length || i == current) return;
    current = i;
    await player.seek(Duration.zero, index: i);
    await player.play();
    notifyListeners();
    _loadFeatures();
  }

  // ------------------------------------------------------------------
  // Lecture
  // ------------------------------------------------------------------
  Future<void> playPause() async {
    if (player.playing) {
      await player.pause();
      clock.pause();
    } else {
      await player.play();
      clock.resume();
    }
    notifyListeners();
  }

  Future<void> next() async { if (paths.isEmpty) return; await player.seekToNext(); }
  Future<void> prev() async { if (paths.isEmpty) return; await player.seekToPrevious(); }

  Future<void> seek(double seconds) async {
    await player.seek(Duration(milliseconds: (seconds * 1000).round()));
    clock.sync(playing: player.playing);
    rs.reset();
    fx.reset();
    notifyListeners();
  }

  double get position => player.position.inMilliseconds / 1000.0;
  double get duration => player.duration?.inMilliseconds.toDouble() ?? 0;

  // ------------------------------------------------------------------
  // Boucle d'animation (appelée par le Ticker de l'UI, 60 ips cible)
  // ------------------------------------------------------------------
  void tick(double dt) {
    final f = features;
    if (f == null) return;
    clock.sync(playing: player.playing); // resynchronisation douce
    final double pos = clock.position() - synchro / 1000.0;
    final double t = pos < 0 ? 0 : (pos > f.duration ? f.duration : pos);
    fv.read(f, t);
    rs.step(dt, fv, paused: !player.playing);
    fx.step(dt, rs, unit: 400, height: 800);
    repaint.value++;
  }

  // ------------------------------------------------------------------
  // Export
  // ------------------------------------------------------------------
  Future<void> startExport() async {
    final f = features;
    if (f == null || exporting) return;
    final fmt = format;
    double start = clock.position();
    double dur = extraitSec < 0
        ? (f.duration - start)
        : extraitSec.toDouble();
    if (start > f.duration - 1) start = 0;
    if (dur > f.duration - start) dur = f.duration - start;
    exporting = true;
    exportProgress = 0;
    exportLabel = 'Export 0 % (${fmt.width}x${fmt.height})';
    exportedPath = null;
    notifyListeners();

    final exp = VideoExporter();
    exporter = exp;
    await serviceChannel.startForeground();
    try {
      final out = await exp.export(ExportParams(
        features: f,
        audioPath: paths[current],
        start: start,
        duration: dur,
        format: fmt,
        videoOffsetMs: decalageVideo,
        style: style,
        paletteIndex: paletteIndex,
        oled: oled,
        p: espaceParoles / 100.0,
        onProgress: (p, label) {
          exportProgress = p;
          exportLabel = label;
          notifyListeners();
        },
      ));
      exportedPath = out;
      status = 'Export terminé';
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp('^Exception: '), '');
      status = _cancelledByUser(msg) ? 'Export annulé' : 'Erreur : $msg';
      exporter = null;
    } finally {
      await serviceChannel.stopForeground();
      exporting = false;
      exportProgress = 0;
      notifyListeners();
    }
  }

  bool _cancelledByUser(String m) => m.contains('annulé') || m.contains('cancel');

  void cancelExport() {
    exporter?.cancel();
    status = 'Annulation de l\'export…';
    notifyListeners();
  }

  // ------------------------------------------------------------------
  Future<void> closeResult() async {
    exportedPath = null;
    notifyListeners();
  }

  @override
  void dispose() {
    player.dispose();
    repaint.dispose();
    super.dispose();
  }
}

/// Canal de méthode vers le service de premier plan Android.
class MethodChannelX {
  static const _ch = MethodChannel('wave_fluide/export_service');
  Future<void> startForeground() async {
    try { await _ch.invokeMethod('startExport'); } catch (_) {}
  }
  Future<void> stopForeground() async {
    try { await _ch.invokeMethod('stopExport'); } catch (_) {}
  }
}
