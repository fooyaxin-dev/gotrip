// historyWidget.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/history_service.dart';

class HistoryWidget extends StatefulWidget {
  const HistoryWidget({super.key});

  @override
  State<HistoryWidget> createState() => _HistoryWidgetState();
}

class _HistoryWidgetState extends State<HistoryWidget> {
  late Future<List<TripHistory>> _future;

  @override
  void initState() {
    super.initState();
    _future = HistoryService.instance.fetchGrouped();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TripHistory>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 240,
            child: Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF4DB6AC)),
            ),
          );
        }

        final trips = snap.data ?? [];
        if (trips.isEmpty) return _buildEmptyState();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Section header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('My Trips',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                          letterSpacing: -0.5)),
                  Text('${trips.length} trip${trips.length > 1 ? "s" : ""}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[400],
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),

            // ── Horizontal card list ──
            SizedBox(
              height: 240,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: trips.length,
                itemBuilder: (_, i) => _TripCard(
                  trip: trips[i],
                  index: i,
                  onTap: () => _openTripDetail(context, trips[i]),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.grey[100],
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.flight_takeoff_rounded,
                  size: 32, color: Colors.grey[350]),
            ),
            const SizedBox(height: 14),
            Text('No adventures yet',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[500])),
            const SizedBox(height: 4),
            Text('Your travel stories will live here',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          ],
        ),
      ),
    );
  }

  void _openTripDetail(BuildContext context, TripHistory trip) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => _TripDetailPopup(trip: trip),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Accent colours — cycle when no cover photo
// ─────────────────────────────────────────────────────────────────────────────

const _kAccents = [
  [Color(0xFF5E35B1), Color(0xFF9C27B0)],
  [Color(0xFF00796B), Color(0xFF26C6DA)],
  [Color(0xFFE65100), Color(0xFFFFA726)],
  [Color(0xFF1565C0), Color(0xFF42A5F5)],
  [Color(0xFF880E4F), Color(0xFFEC407A)],
];

// ─────────────────────────────────────────────────────────────────────────────
// Trip card  —  cinematic poster style
// ─────────────────────────────────────────────────────────────────────────────

class _TripCard extends StatelessWidget {
  final TripHistory trip;
  final int index;
  final VoidCallback onTap;

  const _TripCard(
      {required this.trip, required this.index, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent   = _kAccents[index % _kAccents.length];
    final hasPhoto = trip.coverPhoto != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 175,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color:
                  (hasPhoto ? Colors.black : accent[0]).withOpacity(0.22),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [

              // ── Background ──
              if (hasPhoto)
                Image.network(trip.coverPhoto!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _gradientBg(accent))
              else
                _gradientBg(accent),

              // ── Bottom scrim ──
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.08),
                      Colors.black.withOpacity(0.75),
                    ],
                    stops: const [0.35, 0.6, 1.0],
                  ),
                ),
              ),

              // ── Top-right date pill ──
              Positioned(
                top: 12, right: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.93),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    DateFormat('dd MMM').format(trip.latestVisit),
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                        letterSpacing: 0.2),
                  ),
                ),
              ),

              // ── Bottom content ──
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        trip.itineraryTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            height: 1.25,
                            letterSpacing: -0.2),
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        // Places count chip
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4DB6AC).withOpacity(0.85),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(children: [
                            const Icon(Icons.location_on_rounded,
                                size: 9, color: Colors.white),
                            const SizedBox(width: 3),
                            Text(
                              '${trip.places.length} place${trip.places.length > 1 ? "s" : ""}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700),
                            ),
                          ]),
                        ),
                        const SizedBox(width: 6),
                        // Arrow hint
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_forward_rounded,
                              size: 11, color: Colors.white),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gradientBg(List<Color> colors) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: colors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Icon(Icons.map_rounded,
          size: 52, color: Colors.white.withOpacity(0.15)),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Trip detail bottom sheet  —  timeline
// ─────────────────────────────────────────────────────────────────────────────

class _TripDetailPopup extends StatelessWidget {
  final TripHistory trip;
  const _TripDetailPopup({required this.trip});

  @override
  Widget build(BuildContext context) {
    final places = [...trip.places]
      ..sort((a, b) => a.visitedAt.compareTo(b.visitedAt));

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize:     0.5,
      maxChildSize:     0.95,
      builder: (_, controller) => Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.all(Radius.circular(32)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),

            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Cover strip ──
            if (trip.coverPhoto != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox(
                    height: 120,
                    width: double.infinity,
                    child: Image.network(trip.coverPhoto!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox()),
                  ),
                ),
              ),

            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(trip.itineraryTitle,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1A1A2E),
                              letterSpacing: -0.4)),
                      const SizedBox(height: 3),
                      Text(
                        '${trip.places.length} location${trip.places.length > 1 ? "s" : ""} visited',
                        style:
                            TextStyle(fontSize: 13, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4DB6AC).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    DateFormat('MMM yyyy').format(trip.latestVisit),
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF4DB6AC),
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),

            Divider(color: Colors.grey[100], height: 1,
                indent: 24, endIndent: 24),

            // ── Timeline list ──
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                itemCount: places.length,
                itemBuilder: (_, i) {
                  final item   = places[i];
                  final isLast = i == places.length - 1;

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // Timeline dot + line
                      Column(children: [
                        Container(
                          width: 14, height: 14,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF4DB6AC),
                          ),
                          child: const Center(
                            child: Icon(Icons.check_rounded,
                                size: 8, color: Colors.white),
                          ),
                        ),
                        if (!isLast)
                          Container(
                              width: 2, height: 88,
                              color: Colors.grey[100]),
                      ]),
                      const SizedBox(width: 16),

                      // Content
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                DateFormat('hh:mm a').format(item.visitedAt),
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF4DB6AC),
                                    letterSpacing: 0.3),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8F9FA),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                      color: Colors.grey[100]!, width: 1),
                                ),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(item.placeName,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                                color: Color(0xFF1A1A2E))),
                                        const SizedBox(height: 3),
                                        Text(item.address,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey[500])),
                                      ],
                                    ),
                                  ),
                                  if (item.photoUrl != null) ...[
                                    const SizedBox(width: 10),
                                    ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(10),
                                      child: Image.network(
                                        item.photoUrl!,
                                        width: 48, height: 48,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox(),
                                      ),
                                    ),
                                  ],
                                ]),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}