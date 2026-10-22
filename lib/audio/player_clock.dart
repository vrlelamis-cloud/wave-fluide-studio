import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Horloge de lecture continue : just_audio ne donne sa position que
/// sporadiquement ; on extrapole avec un Stopwatch et on resynchronise
/// en douceur dès que l'écart dépasse 30 ms.
class PlayerClock {
  final AudioPlayer player;
  PlayerClock(this.player);

  double _anchorPos = 0;      // position audio mémorisée à l'ancre
  final Stopwatch _watch = Stopwatch();
  bool _playing = false;
  double _rate = 1.0;

  double get rate => _rate;

  /// À appeler après play(), seek() et pause().
  void sync({bool playing = true, double rate = 1.0}) {
    _playing = playing;
    _rate = rate > 0 ? rate : 1.0;
    _anchorPos = player.position.inMilliseconds / 1000.0 *
        (_rate != 1.0 ? _rate : 1.0);
    // position est déjà en temps réel même avec speed != 1 ; on garde simple :
    _anchorPos = player.position.inMilliseconds / 1000.0;
    _watch
      ..reset()
      ..start();
  }

  void pause() {
    _playing = false;
    _watch.stop();
    _anchorPos = player.position.inMilliseconds / 1000.0;
  }

  void resume() {
    _playing = true;
    _anchorPos = player.position.inMilliseconds / 1000.0;
    _watch.start();
  }

  /// Position extrapolée en secondes (avant soustraction du réglage Synchro).
  double position() {
    double p = _anchorPos + (_playing ? _watch.elapsedMilliseconds / 1000.0 * _rate : 0);
    if (_playing) {
      // Resynchronisation douce si l'écart dépasse 30 ms.
      final real = player.position.inMilliseconds / 1000.0;
      final diff = real - p;
      if (diff.abs() > 0.030) {
        _anchorPos = real;
        _watch..reset()..start();
        p = real;
      } else if (diff.abs() > 0.008) {
        // correction progressive : ±10 % de l'écart par interrogation
        _anchorPos += diff * 0.5;
        p += diff * 0.5;
      }
    }
    return p;
  }
}
