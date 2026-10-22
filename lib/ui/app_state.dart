import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
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
  int espaceParoles = 40;     // 0..60 %, pas 5, défaut 40
  int decalageVideo = 0;      // -120..120 ms, pas 5, défaut 0
  int synchro = 0;            // -50..400 ms, pas 10, défaut 0
  int paletteIndex = 0;       // 0 = Origine (aucune palette)
  bool oled = true;
  VizStyle style = VizStyle.fluide;
  int formatIndex = 0;        // 9:16, 16:9, TikTok HD, Plein écran
  int extraitSec = 30;        // 15, 30 (défaut), 60, -1 = complet

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

  double _screenW = 1080, _screenH = 1920;
  void setScreenSize(double w, double h) { _screenW = w; _screenH = h; }

  /// Mise à jour publique de l'interface.
  void update() => notifyListeners();

  ExportFormat get format {
    switch (formatIndex) {
      case 0: return ExportFormat.f9x16;
      case 1: return ExportFormat.f16x9;
      case 2: return ExportFormat.tiktokHd;
      default:
        return ExportFormat.fullscreen(_screenW.round(), _screenH.round());
    }
  }

  // ------------------------------------------------------------------
  // Import et playlist
  // ------------------------------------------------------------------
  Future<void> importFiles() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'amr', '3gp'
        ],
        allowMultiple: true,
      );
    } catch (_) {
      status = 'Sélecteur de fichiers indisponible';
      update();
      return;
    }
    if (res == null || res.files.isEmpty) return;
    final int firstAdded = paths.length;
    int added = 0;
    for (final f in res.files) {
      final p = f.path;
      if (p != null && File(p).existsSync()) {
        paths.add(p);
        names.add(f.name);
        added++;
      }
    }
    if (added == 0) {
      status = 'Aucun fichier importé';
      update();
      return;
    }
    status = added.toString() + ' morceau(x) importé(s)';
    await _rebuildPlaylist(startIndex: current < 0 ? firstAdded : current);
    if (current < 0) {
      current = firstAdded;
      await _loadFeatures();
    }
    update();
  }

  bool _playlistBound = false;
  Future<void> _rebuildPlaylist({int startIndex = 0}) async {
    try {
      final sources = <AudioSource>[];
      for (final p in paths) {
        sources.add(AudioSource.uri(Uri.file(p)));
      }
      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: startIndex.clamp(0, paths.length - 1).toInt(),
      );
      current = startIndex.clamp(0, paths.length - 1).toInt();
    } catch (e) {
      status = 'Fichier illisible';
    }
    if (!_playlistBound) {
      _playlistBound = true;
      player.currentIndexStream.listen((i) {
        if (i != null && i != current) {
          current = i;
          _loadFeatures();
          update();
        }
      });
      player.playerStateStream.listen((_) => update());
      player.processingStateStream.listen((s) {
        if (s == ProcessingState.completed) {
          clock.sync(playing: false);
          update();
        }
      });
    }
  }

  String get currentName =>
      current >= 0 && current < names.length
          ? names[current].replaceAll(RegExp('\\.[^.]+\$'), '')
          : '';

  // ------------------------------------------------------------------
  // Analyse du morceau courant (Isolate, hors fil d'interface)
  // ------------------------------------------------------------------
  Future<void> _loadFeatures() async {
    if (current < 0 || current >= paths.length) return;
    analyzing = true;
    status = 'Analyse du morceau…';
    update();
    final path = paths[current];
    final oldFeatures = features;
    try {
      final wav = await Decoder.toWav(path);
      features = await Decoder.analyze(wav);
      try { File(wav).deleteSync(); } catch (_) {}
      oldFeatures?.dispose();
      rs.reset();
      fx.reset();
      status = 'Prêt : ' + currentName;
    } catch (e) {
      features = null;
      oldFeatures?.dispose();
      status = 'Fichier illisible ou format non pris en charge';
    }
    analyzing = false;
    update();
  }

  Future<void> selectTrack(int i) async {
    if (i < 0 || i >= paths.length || i == current) return;
    await player.seek(Duration.zero, index: i);
    current = i;
    await player.play();
    clock.sync(playing: true);
    update();
    _loadFeatures();
  }

  // ------------------------------------------------------------------
  // Lecture
  // ------------------------------------------------------------------
  Future<void> playPause() async {
    if (paths.isEmpty) return;
    if (player.playing) {
      await player.pause();
      clock.pause();
    } else {
      await player.play();
      clock.resume();
    }
    update();
  }

  Future<void> next() async {
    if (paths.isEmpty) return;
    await player.seekToNext();
    clock.sync(playing: player.playing);
  }

  Future<void> prev() async {
    if (paths.isEmpty) return;
    await player.seekToPrevious();
    clock.sync(playing: player.playing);
  }

  Future<void> seek(double seconds) async {
    await player.seek(Duration(milliseconds: (seconds * 1000).round()));
    clock.sync(playing: player.playing);
    rs.reset();
    fx.reset();
    update();
  }

  double get position => player.position.inMilliseconds / 1000.0;
  double get duration => player.duration?.inMilliseconds.toDouble() ?? 0;

  // ------------------------------------------------------------------
  // Boucle d'animation (Ticker de l'UI, 60 ips cible)
  // ------------------------------------------------------------------
  void tick(double dt) {
    final f = features;
    if (f == null) return;
    // Position d'animation = horloge continue − réglage Synchro.
    final double pos = clock.position() - synchro / 1000.0;
    final double t = pos < 0 ? 0 : (pos > f.duration ? f.duration : pos);
    fv.read(f, t);
    rs.step(dt, fv, paused: !player.playing);
    fx.step(dt, rs, unit: 400, height: 800);
    repaint.value++;
  }

  // ------------------------------------------------------------------
  // Export vidéo
  // ------------------------------------------------------------------
  Future<void> startExport() async {
    final f = features;
    if (f == null || exporting) return;
    final fmt = format;
    double start = clock.position();
    double dur = extraitSec < 0 ? (f.duration - start) : extraitSec.toDouble();
    if (start > f.duration - 1) start = 0;
    if (dur > f.duration - start) dur = f.duration - start;
    exporting = true;
    exportProgress = 0;
    exportLabel = 'Export 0 % (' + fmt.width.toString() + 'x' + fmt.height.toString() + ')';
    exportedPath = null;
    update();

    final exp = VideoExporter();
    exporter = exp;
    await ExportServiceChannel.start();
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
          update();
        },
      ));
      exportedPath = out;
      status = 'Export terminé';
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp('^Exception: '), '');
      status = _cancelledByUser(msg) ? 'Export annulé' : 'Erreur : ' + msg;
      exporter = null;
    } finally {
      await ExportServiceChannel.stop();
      exporting = false;
      exportProgress = 0;
      update();
    }
  }

  bool _cancelledByUser(String m) => m.contains('annulé') || m.contains('cancel');

  void cancelExport() {
    exporter?.cancel();
    status = "Annulation de l'export…";
    update();
  }

  void closeResult() {
    exportedPath = null;
    update();
  }

  @override
  void dispose() {
    player.dispose();
    repaint.dispose();
    super.dispose();
  }
}

/// Canal de méthode vers le service de premier plan Android.
class ExportServiceChannel {
  static const _ch = MethodChannel('wave_fluide/export_service');
  static Future<void> start() async {
    try { await _ch.invokeMethod('startExport'); } catch (_) {}
  }
  static Future<void> stop() async {
    try { await _ch.invokeMethod('stopExport'); } catch (_) {}
  }
}
