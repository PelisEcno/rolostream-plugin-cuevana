import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:rolostream_core/rolostream_core.dart' as core;

// ---------------------------------------------------------------------------
// Enlaces de servidores
// ---------------------------------------------------------------------------

/// Llave XOR del reproductor de cuevana3c.pro (el script la parte en trozos).
const _xorKey = 'a45f04ce-2394-47c3-b718-0ecd97ce51d6';

/// Servidores que el reproductor identifica por el primer carácter del `token`.
const _tokenServers = <String, String>{
  '1': 'https://ikhjerbhye3wjkhoduh5xiczuvd.lol/v/',
  '2': 'https://filemoon.sx/e/',
  '3': 'https://lkhjerbhye3wjkhodvh5xlczuvd.lol/e/',
  '4': 'https://dood.li/e/',
};

/// Calcula la URL real de un `data-server`, igual que el script de la página del reproductor:
///
///  * `?v=<base64>`     → la URL es el Base64 decodificado (`atob`).
///  * `?token=<id><b64>` → `<id>` (1 carácter) elige el servidor; el resto se decodifica de
///    Base64 y se desencripta con XOR contra [_xorKey]; URL final = servidor + texto.
///
/// Devuelve `null` si el valor no tiene ninguna de las dos formas o no se puede decodificar.
String? decodeServerUrl(String dataServer) {
  final Uri uri;
  try {
    uri = Uri.parse(dataServer.trim());
  } on FormatException {
    return null;
  }

  try {
    final token = uri.queryParameters['token'];
    if (token != null && token.length > 1) {
      final base = _tokenServers[token[0]];
      if (base == null) return null;
      final bytes = base64.decode(base64.normalize(token.substring(1)));
      final out = StringBuffer();
      for (var i = 0; i < bytes.length; i++) {
        out.writeCharCode(bytes[i] ^ _xorKey.codeUnitAt(i % _xorKey.length));
      }
      return '$base$out';
    }

    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) {
      final url = utf8.decode(base64.decode(base64.normalize(v)));
      return url.startsWith('http') ? url : null;
    }
  } on FormatException {
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Fuente
// ---------------------------------------------------------------------------

/// Fuente Cuevana 3 (cuevana3c.pro): películas y series.
///
///  * "slug" de la app = `pelicula/{slug}` o `serie/{slug}` (el sitio separa los dos tipos).
///  * Episodios: `numero = temporada * 10000 + episodio` (las películas usan 1).
///  * Servidores: atributos `data-server`, agrupados por idioma; se calculan en el cliente
///    con [decodeServerUrl], sin pedir nada a las páginas de los reproductores.
class CuevanaSource implements core.SourcePlugin {
  CuevanaSource() {
    _dio = Dio(BaseOptions(
      headers: {
        'User-Agent': _userAgent,
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      followRedirects: true,
      validateStatus: (status) => status != null && status < 500,
    ));
    _dio.interceptors.add(CookieManager(CookieJar()));
  }

  static const _baseUrl = 'https://cuevana3c.pro';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  /// Los episodios de series se codifican como `temporada * _seasonFactor + episodio`.
  static const seasonFactor = 10000;

  late final Dio _dio;

  @override
  String get id => 'cuevana';

  @override
  String get name => 'Cuevana 3';

  @override
  String? get iconAsset => null;

  @override
  core.FilterOptions get filterOptions => _filterOptions;

  // ----------------------------------------------------------
  // URLs
  // ----------------------------------------------------------

  /// `https://cuevana3c.pro/serie/akka` o `…/serie/akka/episodio-1x4` → `serie/akka`.
  @override
  String slugFromUrl(String url) {
    final segs = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? [];
    if (segs.length >= 2 && (segs[0] == 'pelicula' || segs[0] == 'serie')) {
      return '${segs[0]}/${segs[1]}';
    }
    return segs.isEmpty ? url : segs.last;
  }

  /// `…/serie/akka/episodio-2x5` → (`serie/akka`, 20005). Las películas devuelven número 1.
  @override
  ({String slug, int numero})? parseEpisodeUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final ep = RegExp(r'^/?serie/([^/]+)/episodio-(\d+)x(\d+)/?$').firstMatch(path);
    if (ep != null) {
      return (
        slug: 'serie/${ep.group(1)}',
        numero: int.parse(ep.group(2)!) * seasonFactor + int.parse(ep.group(3)!),
      );
    }
    final movie = RegExp(r'^/?pelicula/([^/]+)/?$').firstMatch(path);
    if (movie != null) return (slug: 'pelicula/${movie.group(1)}', numero: 1);
    return null;
  }

  Future<Document> _getDoc(String url, {Map<String, dynamic>? query}) async {
    final res = await _dio.get<String>(
      url,
      queryParameters: query,
      options: Options(responseType: ResponseType.plain),
    );
    return html_parser.parse(res.data ?? '');
  }

  String _abs(String href) {
    if (href.startsWith('http')) return href;
    return '$_baseUrl/${href.replaceFirst(RegExp(r'^/'), '')}';
  }

  /// Los posters del listado vienen en `w200`; para el detalle se pide una versión mayor.
  String _bigImage(String url) => url.replaceFirst('/w200/', '/w500/');

  // ----------------------------------------------------------
  // Listados (tarjetas `.movie-item`)
  // ----------------------------------------------------------

  /// Tarjetas de película/serie de una página (excluye las de episodios).
  List<_Card> _cards(Document doc) {
    final seen = <String>{};
    final out = <_Card>[];
    for (final item in doc.querySelectorAll('.movie-item:not(.episode-item)')) {
      final a = item.querySelector('a');
      final href = a?.attributes['href'] ?? '';
      final titulo = item.querySelector('.item-detail p')?.text.trim() ?? '';
      if (href.isEmpty || titulo.isEmpty || !seen.add(href)) continue;
      final yearText = item.querySelector('.year')?.text ?? '';
      out.add(_Card(
        titulo: titulo,
        url: _abs(href),
        imagen: item.querySelector('img.poster')?.attributes['src'] ?? '',
        isSerie: href.contains('/serie/'),
        anio: RegExp(r'\b(19|20)\d{2}\b').firstMatch(yearText)?.group(0) ?? '',
      ));
    }
    return out;
  }

  @override
  Future<List<core.AnimeResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final doc = await _getDoc('$_baseUrl/explorar', query: {'s': query.trim()});
    return [
      for (final c in _cards(doc))
        core.AnimeResult(nombre: c.titulo, url: c.url, imagen: c.imagen),
    ];
  }

  /// Cuevana no tiene un listado de "series recientes": se usan los últimos estrenos
  /// de películas y de series, intercalados.
  @override
  Future<List<core.RecentSerie>> getRecentSeries() async {
    final pages = await Future.wait([
      _getDoc('$_baseUrl/peliculas'),
      _getDoc('$_baseUrl/series'),
    ]);
    final movies = _cards(pages[0]).take(12).toList();
    final series = _cards(pages[1]).take(12).toList();
    final mixed = <_Card>[];
    for (var i = 0; i < movies.length || i < series.length; i++) {
      if (i < movies.length) mixed.add(movies[i]);
      if (i < series.length) mixed.add(series[i]);
    }
    return [
      for (final c in mixed) core.RecentSerie(titulo: c.titulo, url: c.url, imagen: c.imagen),
    ];
  }

  /// `/episodios/recientes`: título "Serie 1x4" + miniatura.
  @override
  Future<List<core.RecentEpisode>> getLatestEpisodes() async {
    final doc = await _getDoc('$_baseUrl/episodios/recientes');
    final seen = <String>{};
    final out = <core.RecentEpisode>[];
    for (final item in doc.querySelectorAll('.episode-item')) {
      final href = item.querySelector('a')?.attributes['href'] ?? '';
      final raw = item.querySelector('.item-detail p')?.text.trim() ?? '';
      if (parseEpisodeUrl(href) == null || raw.isEmpty || !seen.add(href)) continue;
      out.add(core.RecentEpisode(
        titulo: raw.replaceFirst(RegExp(r'\s+\d+x\d+$'), ''),
        url: _abs(href),
        imagen: item.querySelector('img.poster')?.attributes['src'] ?? '',
        fecha: '',
      ));
    }
    return out;
  }

  /// "Emisión": las series, de la más reciente a la más antigua.
  @override
  Future<List<core.AiringAnime>> getAiringAnimes({int page = 1}) async {
    final doc = await _getDoc('$_baseUrl/series', query: {
      'orden': 'recientes',
      if (page > 1) 'page': '$page',
    });
    return [
      for (final c in _cards(doc))
        core.AiringAnime(
            titulo: c.titulo, url: c.url, imagen: c.imagen, tipo: 'Serie', anio: c.anio),
    ];
  }

  /// `categoria` = `peliculas` o `series` (por defecto, películas).
  @override
  Future<List<core.FilterAnime>> getAnimesByFilter({
    String genero = 'false',
    String fecha = 'false',
    String letra = 'false',
    String categoria = 'false',
    int page = 1,
  }) async {
    final section = categoria == 'series' ? 'series' : 'peliculas';
    final doc = await _getDoc('$_baseUrl/$section', query: {
      if (genero != 'false') 'genero': genero,
      if (fecha != 'false') 'ano': fecha,
      if (letra != 'false') 'letra': letra,
      if (page > 1) 'page': '$page',
    });
    return [
      for (final c in _cards(doc))
        core.FilterAnime(
          titulo: c.titulo,
          url: c.url,
          imagen: c.imagen,
          tipo: c.isSerie ? 'Serie' : 'Película',
          anio: c.anio,
        ),
    ];
  }

  // ----------------------------------------------------------
  // Detalle
  // ----------------------------------------------------------

  @override
  Future<core.AnimeDetail> getAnime(String slug) async {
    final clean = slugFromUrl(slug);
    final isSerie = clean.startsWith('serie/');
    final pageUrl = '$_baseUrl/$clean';
    final doc = await _getDoc(pageUrl);

    // El h1 trae la puntuación en un <span> y, en series, el prefijo "Serie ".
    final h1 = doc.querySelector('h1');
    h1?.querySelectorAll('span').forEach((e) => e.remove());
    final titulo = (h1?.text ?? '')
        .replaceFirst(RegExp(r'^\s*(Serie|Película)\s+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (titulo.isEmpty) throw Exception('No se encontró "$clean" en Cuevana');

    final ogDescription =
        doc.querySelector('meta[property="og:description"]')?.attributes['content'] ?? '';
    final summary = _sectionText(doc, 'Resumen') ??
        (ogDescription.startsWith('$titulo - ')
            ? ogDescription.substring(titulo.length + 3)
            : ogDescription);

    final year = RegExp(r'\b(19|20)\d{2}\b')
        .firstMatch(_sectionText(doc, 'Año de estreno') ?? '')
        ?.group(0);

    final generos = <String>{
      for (final a in doc.querySelectorAll('a[href*="genero="]'))
        if (a.text.trim().isNotEmpty) a.text.trim(),
    }.toList();

    return core.AnimeDetail(
      titulo: titulo,
      sinopsis: summary.trim(),
      imagen: _bigImage(doc.querySelector('meta[property="og:image"]')?.attributes['content'] ?? ''),
      estado: year ?? '',
      generos: generos,
      episodios: isSerie
          ? await _getSeriesEpisodes(clean, doc)
          : [core.Episode(numero: 1, url: pageUrl, titulo: 'Película')],
    );
  }

  /// Texto del primer `<p>` que sigue al `<h2>` cuyo título empieza por [heading].
  String? _sectionText(Document doc, String heading) {
    for (final h2 in doc.querySelectorAll('h2')) {
      if (h2.text.trim().startsWith(heading)) {
        final p = h2.parent?.querySelector('p') ?? h2.nextElementSibling;
        final text = p?.text.trim();
        if (text != null && text.isNotEmpty) return text;
      }
    }
    return null;
  }

  /// La ficha de la serie solo lista temporadas; cada temporada tiene su página de episodios.
  Future<List<core.Episode>> _getSeriesEpisodes(String slug, Document serieDoc) async {
    final seasonUrls = <String>{
      for (final a in serieDoc.querySelectorAll('a[href*="/temporada-"]'))
        _abs(a.attributes['href'] ?? ''),
    }.toList();

    final byNumber = <int, core.Episode>{};
    // Por lotes, para no abrir decenas de conexiones a la vez.
    for (var i = 0; i < seasonUrls.length; i += 5) {
      final batch = seasonUrls.skip(i).take(5);
      final docs = await Future.wait(batch.map(_getDoc));
      for (final doc in docs) {
        for (final a in doc.querySelectorAll('a[href*="/episodio-"]')) {
          final href = a.attributes['href'] ?? '';
          final m = RegExp(r'/episodio-(\d+)x(\d+)').firstMatch(href);
          if (m == null) continue;
          final season = int.parse(m.group(1)!);
          final episode = int.parse(m.group(2)!);
          byNumber[season * seasonFactor + episode] = core.Episode(
            numero: season * seasonFactor + episode,
            url: _abs(href),
            titulo: 'T$season · Episodio $episode',
          );
        }
      }
    }
    return byNumber.values.toList()..sort((a, b) => a.numero.compareTo(b.numero));
  }

  // ----------------------------------------------------------
  // Servidores
  // ----------------------------------------------------------

  @override
  Future<List<core.VideoServer>> getServers(String slug, int numero) async {
    final clean = slugFromUrl(slug);
    final String pageUrl;
    if (clean.startsWith('serie/')) {
      pageUrl = '$_baseUrl/$clean/episodio-${numero ~/ seasonFactor}x${numero % seasonFactor}';
    } else {
      pageUrl = '$_baseUrl/$clean';
    }
    final doc = await _getDoc(pageUrl);

    final seen = <String>{};
    final out = <core.VideoServer>[];
    for (final tab in doc.querySelectorAll('li.tab-video-item')) {
      final lang = _languageOf(tab);
      for (final li in tab.querySelectorAll('li[data-server]')) {
        final url = decodeServerUrl(li.attributes['data-server'] ?? '');
        if (url == null || !seen.add(url)) continue;
        final siteLabel =
            (li.querySelector('span')?.text ?? '').replaceFirst(RegExp(r'^\s*Servidor\s+'), '').trim();
        out.add(core.VideoServer(nombre: '${hostLabel(url, siteLabel)} ($lang)', url: url));
      }
    }

    // El reproductor abre el primero: primero los que el proxy sabe extraer.
    bool supported(core.VideoServer s) => proxySupported.any(s.nombre.toLowerCase().startsWith);
    return [...out.where(supported), ...out.where((s) => !supported(s))];
  }

  /// Nombre del idioma de una pestaña: el texto de `.tab-item-name` sin su calidad.
  String _languageOf(Element tab) {
    final name = tab.querySelector('.tab-item-name');
    if (name == null) return 'Idioma';
    final own = name.nodes.whereType<Text>().map((t) => t.text.trim()).join(' ').trim();
    return own.isEmpty ? 'Idioma' : own;
  }

  /// Extractores que tiene el proxy para los hosts de este sitio.
  static const proxySupported = ['filemoon', 'doodstream'];

  /// Nombre legible del servidor a partir de su URL final.
  static String hostLabel(String url, String siteLabel) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('filemoon')) return 'Filemoon';
    if (host.contains('dood')) return 'Doodstream';
    // Hosts anónimos (.lol) del token con ID 1: sus páginas son de VidHide.
    if (url.startsWith(_tokenServers['1']!)) return 'Vidhide';
    if (host.contains('vsembed')) return 'Vsembed';
    if (host.contains('vidlink')) return 'Vidlink';
    if (host.contains('videasy')) return 'Videasy';
    if (host.contains('vidapi')) return 'Vidapi';
    return siteLabel.isEmpty ? host : siteLabel;
  }
}

class _Card {
  final String titulo;
  final String url;
  final String imagen;
  final bool isSerie;
  final String anio;
  const _Card({
    required this.titulo,
    required this.url,
    required this.imagen,
    required this.isSerie,
    required this.anio,
  });
}

final _filterOptions = core.FilterOptions(
  generos: _generos,
  anios: _anios,
  letras: _letras,
  categorias: _categorias,
);

const _categorias = <core.FilterOption>[
  core.FilterOption('peliculas', 'Películas'),
  core.FilterOption('series', 'Series'),
];

// Valores tal como los usa cuevana3c.pro/peliculas y /series (selects de género, año y letra).
const _generos = <core.FilterOption>[
  core.FilterOption('accion', 'Accion'),
  core.FilterOption('animacion', 'Animacion'),
  core.FilterOption('anime', 'Anime'),
  core.FilterOption('aventura', 'Aventura'),
  core.FilterOption('belica', 'Belica'),
  core.FilterOption('ciencia-ficcion', 'Ciencia Ficcion'),
  core.FilterOption('comedia', 'Comedia'),
  core.FilterOption('crimen', 'Crimen'),
  core.FilterOption('documental', 'Documental'),
  core.FilterOption('drama', 'Drama'),
  core.FilterOption('familia', 'Familia'),
  core.FilterOption('fantasia', 'Fantasia'),
  core.FilterOption('historia', 'Historia'),
  core.FilterOption('infantil', 'Infantil'),
  core.FilterOption('misterio', 'Misterio'),
  core.FilterOption('musica', 'Musica'),
  core.FilterOption('news', 'News'),
  core.FilterOption('pelicula-de-tv', 'Película de TV'),
  core.FilterOption('politica', 'Politica'),
  core.FilterOption('reality', 'Reality'),
  core.FilterOption('romance', 'Romance'),
  core.FilterOption('suspenso', 'Suspenso'),
  core.FilterOption('talk', 'Talk'),
  core.FilterOption('telenovela', 'Telenovela'),
  core.FilterOption('terror', 'Terror'),
  core.FilterOption('western', 'Western'),
];

const _anios = <core.FilterOption>[
  core.FilterOption('2026', '2026'),
  core.FilterOption('2025', '2025'),
  core.FilterOption('2024', '2024'),
  core.FilterOption('2023', '2023'),
  core.FilterOption('2022', '2022'),
  core.FilterOption('2021', '2021'),
  core.FilterOption('2020', '2020'),
  core.FilterOption('2019', '2019'),
  core.FilterOption('2018', '2018'),
  core.FilterOption('2017', '2017'),
  core.FilterOption('2016', '2016'),
  core.FilterOption('2015', '2015'),
  core.FilterOption('2014', '2014'),
  core.FilterOption('2013', '2013'),
  core.FilterOption('2012', '2012'),
  core.FilterOption('2011', '2011'),
  core.FilterOption('2010', '2010'),
  core.FilterOption('2009', '2009'),
  core.FilterOption('2008', '2008'),
  core.FilterOption('2007', '2007'),
  core.FilterOption('2006', '2006'),
  core.FilterOption('2005', '2005'),
  core.FilterOption('2004', '2004'),
  core.FilterOption('2003', '2003'),
  core.FilterOption('2002', '2002'),
  core.FilterOption('2001', '2001'),
  core.FilterOption('2000', '2000'),
  core.FilterOption('1999', '1999'),
  core.FilterOption('1998', '1998'),
  core.FilterOption('1997', '1997'),
  core.FilterOption('1996', '1996'),
  core.FilterOption('1995', '1995'),
  core.FilterOption('1994', '1994'),
  core.FilterOption('1993', '1993'),
  core.FilterOption('1992', '1992'),
  core.FilterOption('1991', '1991'),
  core.FilterOption('1990', '1990'),
  core.FilterOption('1989', '1989'),
  core.FilterOption('1988', '1988'),
  core.FilterOption('1987', '1987'),
  core.FilterOption('1986', '1986'),
  core.FilterOption('1985', '1985'),
  core.FilterOption('1984', '1984'),
  core.FilterOption('1983', '1983'),
  core.FilterOption('1982', '1982'),
  core.FilterOption('1981', '1981'),
  core.FilterOption('1980', '1980'),
  core.FilterOption('1979', '1979'),
  core.FilterOption('1978', '1978'),
  core.FilterOption('1977', '1977'),
  core.FilterOption('1976', '1976'),
  core.FilterOption('1975', '1975'),
  core.FilterOption('1974', '1974'),
  core.FilterOption('1973', '1973'),
  core.FilterOption('1972', '1972'),
  core.FilterOption('1971', '1971'),
  core.FilterOption('1970', '1970'),
  core.FilterOption('1969', '1969'),
  core.FilterOption('1968', '1968'),
  core.FilterOption('1967', '1967'),
  core.FilterOption('1966', '1966'),
  core.FilterOption('1965', '1965'),
  core.FilterOption('1964', '1964'),
  core.FilterOption('1963', '1963'),
  core.FilterOption('1962', '1962'),
  core.FilterOption('1961', '1961'),
  core.FilterOption('1960', '1960'),
  core.FilterOption('1959', '1959'),
  core.FilterOption('1958', '1958'),
  core.FilterOption('1957', '1957'),
  core.FilterOption('1956', '1956'),
  core.FilterOption('1955', '1955'),
  core.FilterOption('1954', '1954'),
  core.FilterOption('1953', '1953'),
  core.FilterOption('1952', '1952'),
  core.FilterOption('1951', '1951'),
  core.FilterOption('1950', '1950'),
  core.FilterOption('1949', '1949'),
  core.FilterOption('1948', '1948'),
  core.FilterOption('1947', '1947'),
  core.FilterOption('1946', '1946'),
  core.FilterOption('1945', '1945'),
  core.FilterOption('1944', '1944'),
  core.FilterOption('1943', '1943'),
  core.FilterOption('1942', '1942'),
  core.FilterOption('1941', '1941'),
  core.FilterOption('1940', '1940'),
  core.FilterOption('1939', '1939'),
  core.FilterOption('1938', '1938'),
  core.FilterOption('1937', '1937'),
  core.FilterOption('1936', '1936'),
  core.FilterOption('1935', '1935'),
  core.FilterOption('1934', '1934'),
  core.FilterOption('1933', '1933'),
  core.FilterOption('1932', '1932'),
  core.FilterOption('1931', '1931'),
  core.FilterOption('1930', '1930'),
  core.FilterOption('1917', '1917'),
];

const _letras = <core.FilterOption>[
  core.FilterOption('a', 'A'),
  core.FilterOption('b', 'B'),
  core.FilterOption('c', 'C'),
  core.FilterOption('d', 'D'),
  core.FilterOption('e', 'E'),
  core.FilterOption('f', 'F'),
  core.FilterOption('g', 'G'),
  core.FilterOption('h', 'H'),
  core.FilterOption('i', 'I'),
  core.FilterOption('j', 'J'),
  core.FilterOption('k', 'K'),
  core.FilterOption('l', 'L'),
  core.FilterOption('m', 'M'),
  core.FilterOption('n', 'N'),
  core.FilterOption('o', 'O'),
  core.FilterOption('p', 'P'),
  core.FilterOption('q', 'Q'),
  core.FilterOption('r', 'R'),
  core.FilterOption('s', 'S'),
  core.FilterOption('t', 'T'),
  core.FilterOption('u', 'U'),
  core.FilterOption('v', 'V'),
  core.FilterOption('w', 'W'),
  core.FilterOption('x', 'X'),
  core.FilterOption('y', 'Y'),
  core.FilterOption('z', 'Z'),
];
