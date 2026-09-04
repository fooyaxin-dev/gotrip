import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart' show BuildContext;
import 'package:flutter/services.dart' show rootBundle, ByteData;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/itineraryModel.dart';

typedef ImageBytesProvider = Future<Uint8List?> Function(String url);
typedef FontBytesLoader = Future<ByteData> Function(String assetPath);
typedef ShareFileHandler = Future<void> Function(
  String filePath, {
  String? text,
  String? subject,
});
typedef ExportHandler = Future<String> Function(ItineraryModel itinerary);

/// Production cache-only reader that queries [DefaultCacheManager] without making
/// any network requests.
class ProductionDiskCacheReader {
  final BaseCacheManager Function()? _cacheManagerFactory;
  BaseCacheManager? _cacheManager;

  ProductionDiskCacheReader({
    BaseCacheManager? cacheManager,
    BaseCacheManager Function()? cacheManagerFactory,
  })  : _cacheManager = cacheManager,
        _cacheManagerFactory = cacheManagerFactory;

  Future<Uint8List?> call(String url) async {
    try {
      final mgr = _cacheManager ??= (_cacheManagerFactory != null
          ? _cacheManagerFactory!()
          : DefaultCacheManager());
      final fileInfo = await mgr.getFileFromCache(url);
      if (fileInfo != null && await fileInfo.file.exists()) {
        return await fileInfo.file.readAsBytes();
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Service responsible for generating well-formatted, multi-page PDF documents
/// from existing itinerary models and sharing them on device without making any
/// new network calls.
class ItineraryPdfService {
  static final ItineraryPdfService instance = ItineraryPdfService();

  static const String defaultFontAssetPath =
      'assets/fonts/NotoSansSC-Regular.ttf';

  static final ImageBytesProvider productionCacheImageReader =
      ProductionDiskCacheReader().call;

  static Future<ByteData> defaultFontBytesLoader(String assetPath) async {
    try {
      return await rootBundle.load(assetPath);
    } catch (_) {
      final file = File(assetPath);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        return bytes.buffer.asByteData();
      }
      rethrow;
    }
  }

  final ImageBytesProvider? imageBytesProvider;
  final ShareFileHandler? shareHandler;
  final ExportHandler? exportHandler;

  final pw.Font? baseFont;
  final pw.Font? boldFont;
  final String? fontAssetPath;
  final FontBytesLoader? fontBytesLoader;

  ItineraryPdfService({
    this.imageBytesProvider,
    this.shareHandler,
    this.exportHandler,
    this.baseFont,
    this.boldFont,
    this.fontAssetPath,
    this.fontBytesLoader,
  });

  /// Loads the bundled Unicode font from Flutter assets.
  /// Throws a [StateError] if loading fails.
  Future<pw.Font> loadBundledFont() async {
    final loader = fontBytesLoader ?? defaultFontBytesLoader;
    final path = fontAssetPath ?? defaultFontAssetPath;
    try {
      final byteData = await loader(path);
      return pw.Font.ttf(byteData);
    } catch (e) {
      throw StateError(
        'Failed to load bundled offline Unicode font from "$path": $e. '
        'Export cannot proceed without the required offline font.',
      );
    }
  }

  /// Sanitizes an itinerary title into a filesystem-safe filename.
  static String sanitizeFilename(String title) {
    var sanitized = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();

    // Remove leading or trailing periods/underscores
    sanitized = sanitized.replaceAll(RegExp(r'^[\._]+|[\._]+$'), '');

    if (sanitized.isEmpty) {
      sanitized = 'Itinerary';
    }
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50).trim();
    }
    return '${sanitized}_Itinerary.pdf';
  }

  /// Extracts the places from an itinerary in the exact presentation order used
  /// by the PDF document generator.
  static List<ItineraryPlace> extractOrderedPlaces(ItineraryModel itinerary) {
    final list = <ItineraryPlace>[];
    for (final day in itinerary.days) {
      for (final place in day.places) {
        list.add(place);
      }
    }
    return list;
  }

  /// Default provider returns null (omitting photos without making network calls).
  /// Custom image bytes (e.g. from cache or assets) can be injected via [imageBytesProvider].
  static Future<Uint8List?> defaultImageBytesProvider(String url) async => null;

  /// Computes Haversine distance in meters between two coordinates.
  static double calculateDistanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const pVal = 0.017453292519943295; // Math.PI / 180
    final a = 0.5 -
        math.cos((lat2 - lat1) * pVal) / 2 +
        math.cos(lat1 * pVal) *
            math.cos(lat2 * pVal) *
            (1 - math.cos((lon2 - lon1) * pVal)) /
            2;
    return 12742 * math.asin(math.sqrt(a.clamp(0.0, 1.0))) * 1000;
  }

  /// Estimates travel duration in minutes based on distance and travel mode.
  static int estimateMinutes({
    required double distanceMeters,
    required String travelMode,
  }) {
    final speedMps = switch (travelMode.toLowerCase()) {
      'motor' => 8.33,
      'drive' => 11.11,
      _ => 1.25, // default walk (~4.5 km/h)
    };
    final seconds = distanceMeters / speedMps;
    return math.max(1, (seconds / 60).round());
  }

  /// Generates the raw PDF bytes for an itinerary.
  Future<Uint8List> generatePdf(ItineraryModel itinerary) async {
    final doc = await buildDocument(itinerary);
    return await doc.save();
  }

  /// Builds a `pw.Document` representing the itinerary.
  Future<pw.Document> buildDocument(ItineraryModel itinerary) async {
    pw.Font? resolvedBase = baseFont;
    pw.Font? resolvedBold = boldFont;

    if (resolvedBase == null) {
      final loaded = await loadBundledFont();
      resolvedBase = loaded;
      resolvedBold ??= loaded;
    }

    final theme = pw.ThemeData.withFont(
      base: resolvedBase,
      bold: resolvedBold ?? resolvedBase,
      italic: resolvedBase,
      boldItalic: resolvedBold ?? resolvedBase,
    );

    final pdf = pw.Document(
      title: itinerary.title,
      author: 'GoTrip',
      creator: 'GoTrip Offline PDF Generator',
      theme: theme,
    );

    // Pre-resolve photos with URL-level deduplication and zero network calls
    final imageProvider = imageBytesProvider ?? productionCacheImageReader;
    final urlBytesCache = <String, Uint8List?>{};
    final placePhotos = <String, Uint8List?>{};

    for (final day in itinerary.days) {
      for (final place in day.places) {
        final url = place.photoUrl;
        if (url != null && url.trim().isNotEmpty) {
          if (!urlBytesCache.containsKey(url)) {
            try {
              urlBytesCache[url] = await imageProvider(url);
            } catch (_) {
              urlBytesCache[url] = null;
            }
          }
          final bytes = urlBytesCache[url];
          if (bytes != null && bytes.isNotEmpty) {
            placePhotos[place.placeId] = bytes;
          }
        }
      }
    }

    // Pre-calculate leg and summary metrics
    double totalDistanceMeters = 0;
    int totalTravelMinutes = 0;

    for (final day in itinerary.days) {
      for (int i = 0; i < day.places.length; i++) {
        final legInfo = _resolveLeg(day, i, itinerary.travelMode);
        if (legInfo != null) {
          totalDistanceMeters += legInfo.distanceMeters;
          totalTravelMinutes += legInfo.durationMinutes;
        }
      }
    }

    final primaryColor = PdfColor.fromHex('#5E35B1');
    final accentColor = PdfColor.fromHex('#7C4DFF');
    final textDark = PdfColor.fromHex('#1A1A2E');
    final textMuted = PdfColor.fromHex('#555555');
    final cardBg = PdfColor.fromHex('#F8F9FA');
    final borderColor = PdfColor.fromHex('#E2E8F0');
    final successColor = PdfColor.fromHex('#2ECC71');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (pw.Context context) {
          if (context.pageNumber == 1) {
            return pw.SizedBox.shrink();
          }
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(bottom: 12),
            padding: const pw.EdgeInsets.only(bottom: 4),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  itinerary.title,
                  style: pw.TextStyle(
                    fontSize: 9,
                    color: primaryColor,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'GoTrip Offline Itinerary',
                  style: const pw.TextStyle(
                    fontSize: 8.5,
                    color: PdfColors.grey600,
                  ),
                ),
              ],
            ),
          );
        },
        footer: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 12),
            padding: const pw.EdgeInsets.only(top: 6),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Generated on ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())} | Usable Offline',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey600,
                  ),
                ),
                pw.Text(
                  'Page ${context.pageNumber} of ${context.pagesCount}',
                  style: pw.TextStyle(
                    fontSize: 8,
                    color: textDark,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          );
        },
        build: (pw.Context context) {
          return buildContentWidgets(
            itinerary: itinerary,
            placePhotos: placePhotos,
            totalDistanceMeters: totalDistanceMeters,
            totalTravelMinutes: totalTravelMinutes,
            primaryColor: primaryColor,
            accentColor: accentColor,
            textDark: textDark,
            textMuted: textMuted,
            cardBg: cardBg,
            borderColor: borderColor,
            successColor: successColor,
          );
        },
      ),
    );

    return pdf;
  }

  /// Production seam for deterministic PDF composition verification.
  /// Returns the exact list of widgets rendered into the MultiPage document.
  Future<List<pw.Widget>> buildProductionContentWidgets(
    ItineraryModel itinerary, {
    Map<String, Uint8List?>? injectedPlacePhotos,
  }) async {
    final imageProvider = imageBytesProvider ?? productionCacheImageReader;
    final urlBytesCache = <String, Uint8List?>{};
    final placePhotos = injectedPlacePhotos ?? <String, Uint8List?>{};

    if (injectedPlacePhotos == null) {
      for (final day in itinerary.days) {
        for (final place in day.places) {
          final url = place.photoUrl;
          if (url != null && url.trim().isNotEmpty) {
            if (!urlBytesCache.containsKey(url)) {
              try {
                urlBytesCache[url] = await imageProvider(url);
              } catch (_) {
                urlBytesCache[url] = null;
              }
            }
            final bytes = urlBytesCache[url];
            if (bytes != null && bytes.isNotEmpty) {
              placePhotos[place.placeId] = bytes;
            }
          }
        }
      }
    }

    double totalDistanceMeters = 0;
    int totalTravelMinutes = 0;

    for (final day in itinerary.days) {
      for (int i = 0; i < day.places.length; i++) {
        final legInfo = _resolveLeg(day, i, itinerary.travelMode);
        if (legInfo != null) {
          totalDistanceMeters += legInfo.distanceMeters;
          totalTravelMinutes += legInfo.durationMinutes;
        }
      }
    }

    final primaryColor = PdfColor.fromHex('#5E35B1');
    final accentColor = PdfColor.fromHex('#7C4DFF');
    final textDark = PdfColor.fromHex('#1A1A2E');
    final textMuted = PdfColor.fromHex('#555555');
    final cardBg = PdfColor.fromHex('#F8F9FA');
    final borderColor = PdfColor.fromHex('#E2E8F0');
    final successColor = PdfColor.fromHex('#2ECC71');

    return buildContentWidgets(
      itinerary: itinerary,
      placePhotos: placePhotos,
      totalDistanceMeters: totalDistanceMeters,
      totalTravelMinutes: totalTravelMinutes,
      primaryColor: primaryColor,
      accentColor: accentColor,
      textDark: textDark,
      textMuted: textMuted,
      cardBg: cardBg,
      borderColor: borderColor,
      successColor: successColor,
    );
  }

  /// Deterministic production composition builder.
  /// Day 1 begins after the cover/header. Every subsequent day receives exactly
  /// one page break (pw.NewPage) before its header.
  List<pw.Widget> buildContentWidgets({
    required ItineraryModel itinerary,
    required Map<String, Uint8List?> placePhotos,
    required double totalDistanceMeters,
    required int totalTravelMinutes,
    required PdfColor primaryColor,
    required PdfColor accentColor,
    required PdfColor textDark,
    required PdfColor textMuted,
    required PdfColor cardBg,
    required PdfColor borderColor,
    required PdfColor successColor,
  }) {
    final content = <pw.Widget>[];

    // 1. Cover / Header block
    content.add(
      _buildCoverHeader(
        itinerary: itinerary,
        primaryColor: primaryColor,
        accentColor: accentColor,
        textDark: textDark,
        textMuted: textMuted,
        successColor: successColor,
      ),
    );
    content.add(pw.SizedBox(height: 18));

    // 2. Day-by-Day sections
    if (itinerary.days.isEmpty) {
      content.add(
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          margin: const pw.EdgeInsets.only(bottom: 12),
          decoration: pw.BoxDecoration(
            color: cardBg,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            border: pw.Border.all(color: borderColor, width: 0.8),
          ),
          child: pw.Text(
            'No scheduled days or places in this itinerary.',
            style: pw.TextStyle(
              fontSize: 9.5,
              fontStyle: pw.FontStyle.italic,
              color: textMuted,
            ),
          ),
        ),
      );
    }

    for (int d = 0; d < itinerary.days.length; d++) {
      final day = itinerary.days[d];

      // Day 1 begins after the cover header without leading page break.
      // Every subsequent day (d > 0) starts on a fresh PDF page with exactly one page break.
      if (d > 0) {
        content.add(pw.NewPage());
      }

      content.add(
        _buildDayHeader(
          day: day,
          primaryColor: primaryColor,
          textDark: textDark,
        ),
      );
      content.add(pw.SizedBox(height: 10));

      if (day.places.isEmpty) {
        content.add(
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            margin: const pw.EdgeInsets.only(bottom: 12),
            decoration: pw.BoxDecoration(
              color: cardBg,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              border: pw.Border.all(color: borderColor, width: 0.8),
            ),
            child: pw.Text(
              'No scheduled places for this day.',
              style: pw.TextStyle(
                fontSize: 9.5,
                fontStyle: pw.FontStyle.italic,
                color: textMuted,
              ),
            ),
          ),
        );
      } else {
        for (int pIdx = 0; pIdx < day.places.length; pIdx++) {
          final place = day.places[pIdx];
          final leg = _resolveLeg(day, pIdx, itinerary.travelMode);
          final photoBytes = placePhotos[place.placeId];

          content.add(
            _buildPlaceCard(
              place: place,
              sequenceNumber: pIdx + 1,
              leg: leg,
              photoBytes: photoBytes,
              travelMode: itinerary.travelMode,
              cardBg: cardBg,
              borderColor: borderColor,
              primaryColor: primaryColor,
              accentColor: accentColor,
              textDark: textDark,
              textMuted: textMuted,
              successColor: successColor,
            ),
          );
          content.add(pw.SizedBox(height: 10));
        }
      }

      content.add(pw.SizedBox(height: 12));
    }

    // 3. Trip Summary block (preserved after the final day)
    content.add(pw.SizedBox(height: 8));
    content.add(
      _buildTripSummary(
        itinerary: itinerary,
        totalDistanceMeters: totalDistanceMeters,
        totalTravelMinutes: totalTravelMinutes,
        primaryColor: primaryColor,
        accentColor: accentColor,
        textDark: textDark,
        textMuted: textMuted,
        cardBg: cardBg,
        borderColor: borderColor,
      ),
    );

    return content;
  }

  /// Exports the itinerary to a local temporary PDF file and triggers the share sheet.
  Future<String> exportAndShareItinerary(
    ItineraryModel itinerary, {
    BuildContext? context,
  }) async {
    if (exportHandler != null) {
      return await exportHandler!(itinerary);
    }

    final pdfBytes = await generatePdf(itinerary);
    final filename = sanitizeFilename(itinerary.title);

    final tempDir = await getTemporaryDirectory();
    final file = File(p.join(tempDir.path, filename));
    await file.writeAsBytes(pdfBytes, flush: true);

    if (shareHandler != null) {
      await shareHandler!(
        file.path,
        text: 'Here is the itinerary for ${itinerary.title}',
        subject: '${itinerary.title} Itinerary',
      );
    } else {
      await Share.shareXFiles(
        [
          XFile(
            file.path,
            mimeType: 'application/pdf',
            name: filename,
          ),
        ],
        text: 'Here is the itinerary for ${itinerary.title}',
        subject: '${itinerary.title} Itinerary',
      );
    }

    return file.path;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helper Widget Builders
  // ─────────────────────────────────────────────────────────────────────────

  pw.Widget _buildCoverHeader({
    required ItineraryModel itinerary,
    required PdfColor primaryColor,
    required PdfColor accentColor,
    required PdfColor textDark,
    required PdfColor textMuted,
    required PdfColor successColor,
  }) {
    final destination = (itinerary.originName != null &&
            itinerary.originName!.trim().isNotEmpty)
        ? itinerary.originName!
        : (itinerary.days.isNotEmpty &&
                itinerary.days.first.places.isNotEmpty &&
                itinerary.days.first.places.first.address.isNotEmpty)
            ? itinerary.days.first.places.first.address
            : (itinerary.title.isNotEmpty ? itinerary.title : '');

    final travelDates = itinerary.startDate.isNotEmpty
        ? '${itinerary.startDate} (${itinerary.totalDays} ${itinerary.totalDays == 1 ? 'Day' : 'Days'})'
        : '${itinerary.totalDays} ${itinerary.totalDays == 1 ? 'Day' : 'Days'}';

    final generatedDate = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

    return pw.Container(
      padding: const pw.EdgeInsets.all(18),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#F3E8FF'),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
        border: pw.Border.all(color: primaryColor, width: 1.2),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'GOTRIP ITINERARY',
                      style: pw.TextStyle(
                        color: accentColor,
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      itinerary.title,
                      style: pw.TextStyle(
                        color: textDark,
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: pw.BoxDecoration(
                  color: itinerary.isCompleted ? successColor : accentColor,
                  borderRadius:
                      const pw.BorderRadius.all(pw.Radius.circular(12)),
                ),
                child: pw.Text(
                  itinerary.isCompleted ? 'COMPLETED TRIP' : 'ITINERARY PLAN',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Divider(color: PdfColors.grey300, thickness: 0.8),
          pw.SizedBox(height: 10),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _buildHeaderMetaItem(
                label: 'Destination',
                value: destination,
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildHeaderMetaItem(
                label: 'Travel Dates',
                value: travelDates,
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildHeaderMetaItem(
                label: 'Travel Mode',
                value: itinerary.travelMode.toUpperCase(),
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildHeaderMetaItem(
                label: 'Generated On',
                value: generatedDate,
                textDark: textDark,
                textMuted: textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _buildHeaderMetaItem({
    required String label,
    required String value,
    required PdfColor textDark,
    required PdfColor textMuted,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            color: textMuted,
            fontSize: 8,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          style: pw.TextStyle(
            color: textDark,
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ],
    );
  }

  pw.Widget _buildDayHeader({
    required ItineraryDay day,
    required PdfColor primaryColor,
    required PdfColor textDark,
  }) {
    final dateLabel = day.date.isNotEmpty ? ' | ${day.date}' : '';
    final placesCount =
        '${day.places.length} ${day.places.length == 1 ? 'place' : 'places'}';

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: pw.BoxDecoration(
        color: primaryColor,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'DAY ${day.dayNumber}$dateLabel',
            style: pw.TextStyle(
              color: PdfColors.white,
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            placesCount,
            style: const pw.TextStyle(
              color: PdfColors.white,
              fontSize: 9.5,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPlaceCard({
    required ItineraryPlace place,
    required int sequenceNumber,
    required _ResolvedLeg? leg,
    required Uint8List? photoBytes,
    required String travelMode,
    required PdfColor cardBg,
    required PdfColor borderColor,
    required PdfColor primaryColor,
    required PdfColor accentColor,
    required PdfColor textDark,
    required PdfColor textMuted,
    required PdfColor successColor,
  }) {
    final rawCategory = (place.primaryType != null &&
            place.primaryType!.trim().isNotEmpty)
        ? place.primaryType!.trim()
        : (place.allTypes.isNotEmpty && place.allTypes.first.trim().isNotEmpty
            ? place.allTypes.first.trim()
            : null);
    final hasCategory = rawCategory != null && rawCategory.isNotEmpty;
    final hasRating = place.rating != null;

    final hasSchedule =
        place.suggestedTime.trim().isNotEmpty || place.durationMinutes > 0;
    final scheduleStr = hasSchedule
        ? _formatDepartureTime(place.suggestedTime, place.durationMinutes)
        : null;
    final travelStr = leg != null
        ? '${(leg.distanceMeters / 1000).toStringAsFixed(1)} km (~${leg.durationMinutes} min ${travelMode.toLowerCase()})'
        : (sequenceNumber == 1 ? 'First stop of the day' : null);

    final mapsUrl = (place.lat != null && place.lng != null)
        ? 'https://www.google.com/maps/search/?api=1&query=${place.lat},${place.lng}'
        : null;

    final cleanNote = _sanitizeNote(place.notes ?? '');

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: cardBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: borderColor, width: 0.8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Sequence number badge
          pw.Container(
            width: 24,
            height: 24,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: place.isVisited ? successColor : primaryColor,
              shape: pw.BoxShape.circle,
            ),
            child: pw.Text(
              '$sequenceNumber',
              style: pw.TextStyle(
                color: PdfColors.white,
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(width: 10),

          // Main place information
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Title and visited status (Place name is ALWAYS bold and prominent)
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        place.name,
                        style: pw.TextStyle(
                          color: textDark,
                          fontSize: 12,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                    if (place.isVisited)
                      pw.Container(
                        padding: const pw.EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: pw.BoxDecoration(
                          color: PdfColor.fromHex('#E8F8F0'),
                          borderRadius:
                              const pw.BorderRadius.all(pw.Radius.circular(4)),
                          border:
                              pw.Border.all(color: successColor, width: 0.6),
                        ),
                        child: pw.Text(
                          'Visited',
                          style: pw.TextStyle(
                            color: successColor,
                            fontSize: 7.5,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),

                // Category & Rating (only when genuine non-empty data exists)
                if (hasCategory || hasRating) ...[
                  pw.SizedBox(height: 3),
                  pw.Row(
                    children: [
                      if (hasCategory)
                        pw.Text(
                          'Type: $rawCategory',
                          style: pw.TextStyle(
                            fontSize: 8.5,
                            color: textMuted,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      if (hasCategory && hasRating) pw.SizedBox(width: 10),
                      if (hasRating)
                        pw.Text(
                          'Rating: ${place.rating!.toStringAsFixed(1)} / 5.0${(place.userRatingCount != null && place.userRatingCount! > 0) ? ' (${place.userRatingCount} reviews)' : ''}',
                          style: pw.TextStyle(fontSize: 8.5, color: textMuted),
                        ),
                    ],
                  ),
                ],

                // Address (only when non-empty)
                if (place.address.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Address: ${place.address.trim()}',
                    style: pw.TextStyle(fontSize: 8.5, color: textDark),
                  ),
                ],

                // Schedule & Leg (only when genuine data exists)
                if (scheduleStr != null || travelStr != null) ...[
                  pw.SizedBox(height: 4),
                  pw.Row(
                    children: [
                      if (scheduleStr != null)
                        pw.Text(
                          'Schedule: $scheduleStr',
                          style: pw.TextStyle(
                            fontSize: 8.5,
                            color: textDark,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      if (scheduleStr != null && travelStr != null)
                        pw.SizedBox(width: 12),
                      if (travelStr != null)
                        pw.Expanded(
                          child: pw.Text(
                            'Travel from prev: $travelStr',
                            style:
                                pw.TextStyle(fontSize: 8.5, color: textMuted),
                          ),
                        ),
                    ],
                  ),
                ],

                // Phone (only when non-empty)
                if (place.phoneNumber != null &&
                    place.phoneNumber!.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Tel: ${place.phoneNumber!.trim()}',
                    style: pw.TextStyle(fontSize: 8.5, color: textMuted),
                  ),
                ],

                // Website (only when non-empty)
                if (place.website != null &&
                    place.website!.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Website: ${place.website!.trim()}',
                    style: pw.TextStyle(fontSize: 8, color: textMuted),
                  ),
                ],

                // Description (only when non-empty)
                if (place.description != null &&
                    place.description!.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Description: ${place.description!.trim()}',
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontStyle: pw.FontStyle.italic,
                      color: textMuted,
                    ),
                  ),
                ],

                // Note (sanitized without emoji and rating number)
                if (cleanNote.isNotEmpty) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Note: $cleanNote',
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontStyle: pw.FontStyle.italic,
                      color: primaryColor,
                    ),
                  ),
                ],

                // Google Maps link (only when coordinates exist)
                if (mapsUrl != null) ...[
                  pw.SizedBox(height: 4),
                  pw.UrlLink(
                    destination: mapsUrl,
                    child: pw.Text(
                      'Open in Google Maps (${place.lat!.toStringAsFixed(4)}, ${place.lng!.toStringAsFixed(4)})',
                      style: const pw.TextStyle(
                        fontSize: 8,
                        color: PdfColors.blue700,
                        decoration: pw.TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Photo on the right (strictly if cached in local storage)
          if (photoBytes != null) ...[
            pw.SizedBox(width: 8),
            pw.ClipRRect(
              horizontalRadius: 4,
              verticalRadius: 4,
              child: pw.Image(
                pw.MemoryImage(photoBytes),
                width: 60,
                height: 60,
                fit: pw.BoxFit.cover,
              ),
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget _buildTripSummary({
    required ItineraryModel itinerary,
    required double totalDistanceMeters,
    required int totalTravelMinutes,
    required PdfColor primaryColor,
    required PdfColor accentColor,
    required PdfColor textDark,
    required PdfColor textMuted,
    required PdfColor cardBg,
    required PdfColor borderColor,
  }) {
    final totalKm = (totalDistanceMeters / 1000).toStringAsFixed(1);
    final hours = totalTravelMinutes ~/ 60;
    final mins = totalTravelMinutes % 60;
    final timeStr = hours > 0 ? '${hours}h ${mins}m' : '${mins}m';

    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: cardBg,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        border: pw.Border.all(color: borderColor, width: 1),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'TRIP SUMMARY',
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: primaryColor,
              letterSpacing: 1.1,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Divider(color: borderColor, thickness: 0.6),
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _buildSummaryStat(
                label: 'Total Places',
                value: '${itinerary.totalPlaces}',
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildSummaryStat(
                label: 'Places Visited',
                value: '${itinerary.totalVisited} / ${itinerary.totalPlaces}',
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildSummaryStat(
                label: 'Estimated Distance',
                value: '$totalKm km',
                textDark: textDark,
                textMuted: textMuted,
              ),
              _buildSummaryStat(
                label: 'Estimated Travel Time',
                value: timeStr,
                textDark: textDark,
                textMuted: textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _buildSummaryStat({
    required String label,
    required String value,
    required PdfColor textDark,
    required PdfColor textMuted,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(fontSize: 8, color: textMuted),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: textDark,
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Calculation & Formatting Helpers
  // ─────────────────────────────────────────────────────────────────────────

  static _ResolvedLeg? _resolveLeg(
    ItineraryDay day,
    int placeIndex,
    String travelMode,
  ) {
    // If legData is persisted in the itinerary day
    if (day.legsData != null &&
        placeIndex >= 0 &&
        placeIndex < day.legsData!.length) {
      final leg = day.legsData![placeIndex];
      final d = (leg['distance'] as num?)?.toDouble() ?? 0.0;
      final m = (leg['minutes'] as num?)?.toInt() ?? 0;
      return _ResolvedLeg(distanceMeters: d, durationMinutes: m);
    }

    // Otherwise calculate straight-line Haversine if coords exist
    if (placeIndex > 0 && placeIndex < day.places.length) {
      final prev = day.places[placeIndex - 1];
      final curr = day.places[placeIndex];

      if (prev.lat != null &&
          prev.lng != null &&
          curr.lat != null &&
          curr.lng != null) {
        final d = calculateDistanceMeters(
          prev.lat!,
          prev.lng!,
          curr.lat!,
          curr.lng!,
        );
        final m = estimateMinutes(
          distanceMeters: d,
          travelMode: travelMode,
        );
        return _ResolvedLeg(distanceMeters: d, durationMinutes: m);
      }
    }

    return null;
  }

  static String _formatDepartureTime(
      String suggestedTime, int durationMinutes) {
    if (suggestedTime.isEmpty) {
      return '$durationMinutes min visit';
    }

    try {
      final parts = suggestedTime.split(':');
      if (parts.length == 2) {
        final startH = int.parse(parts[0]);
        final startM = int.parse(parts[1]);
        final totalStartM = startH * 60 + startM;
        final totalEndM = (totalStartM + durationMinutes) % 1440;

        final endH = totalEndM ~/ 60;
        final endM = totalEndM % 60;
        final endStr =
            '${endH.toString().padLeft(2, '0')}:${endM.toString().padLeft(2, '0')}';
        return '$suggestedTime - $endStr ($durationMinutes min)';
      }
    } catch (_) {
      // If parsing fails, fall back to simple string
    }

    return '$suggestedTime ($durationMinutes min)';
  }

  /// Sanitizes note text by removing leading emoji and rating (e.g. "⭐ 4.5 · ")
  /// while preserving all actual note and advice text.
  static String _sanitizeNote(String rawNote) {
    if (rawNote.trim().isEmpty) return '';
    var s = rawNote.trim();
    // Strip leading emoji and rating pattern e.g. "⭐ 4.5 · " or "⭐ 4.5 - "
    s = s.replaceFirst(RegExp(r'^[^\w\s]*\s*\d+(\.\d+)?\s*[·\-\:\.]*\s*'), '');
    // Strip any remaining emoji symbols that cannot be rendered by PDF fonts
    s = s.replaceAll(
        RegExp(r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]',
            unicode: true),
        '');
    return s.trim();
  }
}

class _ResolvedLeg {
  final double distanceMeters;
  final int durationMinutes;
  const _ResolvedLeg({
    required this.distanceMeters,
    required this.durationMinutes,
  });
}
