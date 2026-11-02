import 'dart:convert';

import 'package:cuevana_plugin/cuevana_source.dart';
import 'package:test/test.dart';

const _key = 'a45f04ce-2394-47c3-b718-0ecd97ce51d6';

/// Inverso de `decodeServerUrl` para el caso `token`: <id> + base64(xor(texto)).
String _makeToken(String id, String text) {
  final bytes = [for (var i = 0; i < text.length; i++) text.codeUnitAt(i) ^ _key.codeUnitAt(i % _key.length)];
  return '$id${base64.encode(bytes)}';
}

void main() {
  group('decodeServerUrl', () {
    test('token real de la página (servidor 1, XOR)', () {
      expect(decodeServerUrl('https://tungtungsahur.cuevana3c.pro/?token=1D1ZdAEgBWlxOV0oK'),
          'https://ikhjerbhye3wjkhoduh5xiczuvd.lol/v/nbhfx599cey3');
    });

    test('token real de la página (servidor 3, XOR)', () {
      expect(decodeServerUrl('https://tungtungsahur.cuevana3c.pro/?token=3BwJDCllQGx0UAF5L'),
          'https://lkhjerbhye3wjkhodvh5xlczuvd.lol/e/f6vlidxx92mr');
    });

    test('servidores 2 (Filemoon) y 4 (Doodstream)', () {
      expect(decodeServerUrl('https://x.cuevana3c.pro/?token=${_makeToken('2', 'abc123xyz')}'),
          'https://filemoon.sx/e/abc123xyz');
      expect(decodeServerUrl('https://x.cuevana3c.pro/?token=${_makeToken('4', 'k9j8h7g6f5d4')}'),
          'https://dood.li/e/k9j8h7g6f5d4');
    });

    test('?v= es Base64 directo', () {
      expect(decodeServerUrl('https://x.cuevana3c.pro/?v=aHR0cHM6Ly9wbGF5ZXIudmlkZWFzeS5uZXQvbW92aWUvOTY5Njgx'),
          'https://player.videasy.net/movie/969681');
      // Sin relleno "=" (el sitio a veces lo omite) y con "?" dentro de la URL.
      expect(decodeServerUrl('https://x.cuevana3c.pro/?v=aHR0cHM6Ly92c2VtYmVkLnJ1L2VtYmVkL21vdmllP3RtZGI9OTY5NjgxJmRzX2xhbmc9ZXM'),
          'https://vsembed.ru/embed/movie?tmdb=969681&ds_lang=es');
    });

    test('entradas inválidas devuelven null', () {
      expect(decodeServerUrl('https://x.cuevana3c.pro/'), isNull);
      expect(decodeServerUrl('https://x.cuevana3c.pro/?token=9AAAA'), isNull); // servidor desconocido
      expect(decodeServerUrl('https://x.cuevana3c.pro/?token=1'), isNull);
      expect(decodeServerUrl('https://x.cuevana3c.pro/?v=%%%'), isNull);
      expect(decodeServerUrl('https://x.cuevana3c.pro/?v=aG9sYQ'), isNull); // "hola": no es una URL
    });
  });

  group('URLs', () {
    final s = CuevanaSource();

    test('slugFromUrl', () {
      expect(s.slugFromUrl('https://cuevana3c.pro/pelicula/colision-2'), 'pelicula/colision-2');
      expect(s.slugFromUrl('https://cuevana3c.pro/serie/akka'), 'serie/akka');
      expect(s.slugFromUrl('https://cuevana3c.pro/serie/akka/episodio-2x5'), 'serie/akka');
    });

    test('parseEpisodeUrl codifica temporada*10000+episodio', () {
      final ep = s.parseEpisodeUrl('https://cuevana3c.pro/serie/akka/episodio-2x5')!;
      expect(ep.slug, 'serie/akka');
      expect(ep.numero, 20005);
      expect(s.parseEpisodeUrl('https://cuevana3c.pro/pelicula/colision-2')!.numero, 1);
      expect(s.parseEpisodeUrl('https://cuevana3c.pro/serie/akka'), isNull);
    });
  });

  group('hostLabel', () {
    test('nombres a partir de la URL final', () {
      expect(CuevanaSource.hostLabel('https://filemoon.sx/e/abc', 'Hyper'), 'Filemoon');
      expect(CuevanaSource.hostLabel('https://dood.li/e/abc', 'Hyper'), 'Doodstream');
      // Los hosts .lol (IDs 1 y 3) se resuelven con el extractor streamwish del proxy.
      expect(CuevanaSource.hostLabel('https://ikhjerbhye3wjkhoduh5xiczuvd.lol/v/abc', 'Hyper'), 'Streamwish');
      expect(CuevanaSource.hostLabel('https://lkhjerbhye3wjkhodvh5xlczuvd.lol/e/abc', 'Nebula'), 'Streamwish');
      expect(CuevanaSource.isStreamwishHost('https://ikhjerbhye3wjkhoduh5xiczuvd.lol/v/abc'), isTrue);
      expect(CuevanaSource.isStreamwishHost('https://lkhjerbhye3wjkhodvh5xlczuvd.lol/e/abc'), isTrue);
      expect(CuevanaSource.isStreamwishHost('https://filemoon.sx/e/abc'), isFalse);
      expect(CuevanaSource.hostLabel('https://player.videasy.net/movie/1', 'Trinity'), 'Videasy');
    });
  });
}
