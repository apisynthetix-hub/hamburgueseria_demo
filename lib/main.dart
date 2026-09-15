import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const HamburgueseriaDemo());
}

class HamburgueseriaDemo extends StatelessWidget {
  const HamburgueseriaDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hamburguesería Demo',
      theme: ThemeData(useMaterial3: true, fontFamily: 'Arial'),
      home: const TrackingPage(),
    );
  }
}

class TrackingPage extends StatefulWidget {
  const TrackingPage({super.key});

  @override
  State<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends State<TrackingPage> {
  // ============================================================
  // COORDENADAS DE PRUEBA
  // ============================================================

  static const LatLng restaurant = LatLng(7.7938101, -72.2352371);

  static const LatLng initialCustomer = LatLng(7.8296152, -72.2282777);

  // ============================================================
  // CONTROLADORES
  // ============================================================

  final MapController mapController = MapController();

  final DraggableScrollableController sheetController =
      DraggableScrollableController();

  Timer? demoTimer;

  // ============================================================
  // ESTADO
  // ============================================================

  LatLng customer = initialCustomer;
  LatLng courier = restaurant;

  List<LatLng> routePoints = [];

  double distanceKm = 0;
  double totalEta = 0;
  double remainingEta = 0;

  int currentRouteIndex = 0;

  bool loadingRoute = false;
  bool demoRunning = false;
  bool delivered = false;
  bool locating = false;

  String deliveryStatus = 'Pedido preparado';

  // ============================================================
  // COLORES
  // ============================================================

  static const Color orange = Color(0xFFFF6500);
  static const Color dark = Color(0xFF101418);
  static const Color dark2 = Color(0xFF171C21);
  static const Color muted = Color(0xFF8C959E);

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadRoute();
    });
  }

  @override
  void dispose() {
    demoTimer?.cancel();
    sheetController.dispose();
    super.dispose();
  }

  // ============================================================
  // RUTA REAL
  // ============================================================

  Future<List<LatLng>> getRealRoute(LatLng start, LatLng end) async {
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${start.longitude},${start.latitude};'
      '${end.longitude},${end.latitude}'
      '?overview=full&geometries=geojson&steps=true',
    );

    final response = await http.get(
      uri,
      headers: {'User-Agent': 'hamburgueseria_demo/1.0'},
    );

    if (response.statusCode != 200) {
      throw Exception('No se pudo obtener la ruta');
    }

    final data = jsonDecode(response.body);

    if (data['code'] != 'Ok') {
      throw Exception('Ruta no disponible');
    }

    final coordinates = data['routes'][0]['geometry']['coordinates'];

    final points = <LatLng>[];

    for (final coordinate in coordinates) {
      points.add(
        LatLng(
          (coordinate[1] as num).toDouble(),
          (coordinate[0] as num).toDouble(),
        ),
      );
    }

    return points;
  }

  Future<void> loadRoute() async {
    setState(() {
      loadingRoute = true;
      deliveryStatus = 'Calculando ruta';
    });

    try {
      final points = await getRealRoute(restaurant, customer);

      final distance = calculateDistance(points);

      if (!mounted) return;

      setState(() {
        routePoints = points;
        distanceKm = distance;

        totalEta = (distance / 28) * 60;

        if (totalEta < 1) {
          totalEta = 1;
        }

        remainingEta = totalEta;

        courier = restaurant;
        currentRouteIndex = 0;

        loadingRoute = false;
        demoRunning = false;
        delivered = false;

        deliveryStatus = 'Pedido preparado';
      });

      fitRoute(points);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadingRoute = false;
        deliveryStatus = 'Ruta no disponible';
      });

      showMessage('No se pudo calcular la ruta. Comprueba Internet.');
    }
  }

  double calculateDistance(List<LatLng> points) {
    if (points.length < 2) {
      return 0;
    }

    const distance = Distance();

    double totalMeters = 0;

    for (int i = 0; i < points.length - 1; i++) {
      totalMeters += distance.as(LengthUnit.Meter, points[i], points[i + 1]);
    }

    return totalMeters / 1000;
  }

  void fitRoute(List<LatLng> points) {
    if (points.length < 2) return;

    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;

      mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.fromLTRB(45, 145, 45, 230),
        ),
      );
    });
  }

  // ============================================================
  // ELEGIR CLIENTE TOCANDO MAPA
  // ============================================================

  Future<void> selectCustomer(LatLng point) async {
    if (demoRunning) {
      showMessage('Detén la demostración para cambiar el cliente.');
      return;
    }

    setState(() {
      customer = point;
      courier = restaurant;
      delivered = false;
      deliveryStatus = 'Nueva ubicación';
    });

    await loadRoute();
  }

  // ============================================================
  // GPS
  // ============================================================

  Future<void> useMyLocation() async {
    setState(() {
      locating = true;
      deliveryStatus = 'Buscando ubicación';
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        showMessage('Activa el GPS del dispositivo.');

        setState(() {
          locating = false;
          deliveryStatus = 'GPS desactivado';
        });

        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        showMessage('Permiso de ubicación rechazado.');

        setState(() {
          locating = false;
        });

        return;
      }

      if (permission == LocationPermission.deniedForever) {
        showMessage('Activa el permiso de ubicación desde Ajustes.');

        setState(() {
          locating = false;
        });

        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        customer = LatLng(position.latitude, position.longitude);

        locating = false;
        courier = restaurant;
        delivered = false;
      });

      await loadRoute();

      mapController.move(customer, 15.5);
    } catch (_) {
      if (!mounted) return;

      setState(() {
        locating = false;
        deliveryStatus = 'No se obtuvo ubicación';
      });

      showMessage('No fue posible obtener tu ubicación.');
    }
  }

  // ============================================================
  // DEMO
  // ============================================================

  void startDemo() {
    if (routePoints.length < 2) {
      showMessage('Espera a que termine de calcularse la ruta.');
      return;
    }

    demoTimer?.cancel();

    setState(() {
      demoRunning = true;
      delivered = false;
      currentRouteIndex = 0;
      courier = routePoints.first;
      deliveryStatus = 'Repartidor saliendo';
      remainingEta = totalEta;
    });

    // Abrimos automáticamente el panel a un nivel medio.
    if (sheetController.isAttached) {
      sheetController.animateTo(
        0.42,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }

    demoTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (currentRouteIndex >= routePoints.length - 1) {
        timer.cancel();

        setState(() {
          courier = customer;
          demoRunning = false;
          delivered = true;
          remainingEta = 0;
          deliveryStatus = 'Pedido entregado';
        });

        showDelivered();

        return;
      }

      currentRouteIndex++;

      final progress = currentRouteIndex / (routePoints.length - 1);

      final remaining = totalEta * (1 - progress);

      setState(() {
        courier = routePoints[currentRouteIndex];

        remainingEta = remaining < 0 ? 0 : remaining;

        if (progress < 0.18) {
          deliveryStatus = 'Repartidor saliendo';
        } else if (progress < 0.72) {
          deliveryStatus = 'En camino';
        } else if (progress < 0.93) {
          deliveryStatus = 'Llegando al cliente';
        } else {
          deliveryStatus = 'Casi en tu ubicación';
        }
      });

      mapController.move(courier, 15.4);
    });
  }

  void stopDemo() {
    demoTimer?.cancel();

    setState(() {
      demoRunning = false;
      delivered = false;
      currentRouteIndex = 0;
      courier = restaurant;
      remainingEta = totalEta;
      deliveryStatus = 'Pedido preparado';
    });
  }

  // ============================================================
  // MENSAJES
  // ============================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  void showDelivered() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
          decoration: const BoxDecoration(
            color: dark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: orange.withOpacity(.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: orange,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Pedido entregado',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'La demostración terminó correctamente.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 13),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Continuar',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // MARCADOR RESTAURANTE
  // ============================================================

  Widget restaurantMarker() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: dark,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.25),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: const Icon(Icons.storefront_rounded, color: orange, size: 22),
        ),
        const SizedBox(height: 5),
        markerLabel('RESTAURANTE'),
      ],
    );
  }

  // ============================================================
  // MARCADOR CLIENTE
  // ============================================================

  Widget customerMarker() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFF1769FF),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1769FF).withOpacity(.30),
                blurRadius: 14,
              ),
            ],
          ),
          child: const Icon(Icons.home_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(height: 5),
        markerLabel('TU UBICACIÓN', light: true),
      ],
    );
  }

  // ============================================================
  // MARCADOR REPARTIDOR
  // ============================================================

  Widget courierMarker() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: orange,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: [
              BoxShadow(
                color: orange.withOpacity(.40),
                blurRadius: 20,
                spreadRadius: 3,
              ),
            ],
          ),
          child: const Icon(
            Icons.two_wheeler_rounded,
            color: Colors.white,
            size: 27,
          ),
        ),
        const SizedBox(height: 4),
        markerLabel(demoRunning ? 'CARLOS · EN RUTA' : 'CARLOS'),
      ],
    );
  }

  Widget markerLabel(String text, {bool light = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: light ? Colors.white : dark,
        borderRadius: BorderRadius.circular(7),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(.15), blurRadius: 7),
        ],
      ),
      child: Text(
        text,
        style: TextStyle(
          color: light ? const Color(0xFF1769FF) : Colors.white,
          fontSize: 7,
          fontWeight: FontWeight.w900,
          letterSpacing: .5,
        ),
      ),
    );
  }

  // ============================================================
  // HEADER
  // ============================================================

  Widget header() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              floatingButton(Icons.arrow_back_rounded, () {}),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 58,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.94),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.13),
                        blurRadius: 22,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 37,
                        height: 37,
                        decoration: BoxDecoration(
                          color: dark,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.navigation_rounded,
                          color: orange,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Seguimiento',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              '#HB-1024 · Hamburguesería',
                              style: TextStyle(
                                fontSize: 9,
                                color: Colors.black45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF8EF),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.circle,
                              color: Color(0xFF20A354),
                              size: 7,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'LIVE',
                              style: TextStyle(
                                color: Color(0xFF16853A),
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
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

  Widget floatingButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      elevation: 5,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: dark, size: 21),
        ),
      ),
    );
  }

  // ============================================================
  // CONTROLES DEL MAPA
  // ============================================================

  Widget mapControls() {
    return Positioned(
      right: 15,
      top: 150,
      child: Column(
        children: [
          mapButton(Icons.my_location_rounded, () {
            mapController.move(customer, 15.5);
          }),
          const SizedBox(height: 8),
          mapButton(Icons.add_rounded, () {
            mapController.move(
              mapController.camera.center,
              mapController.camera.zoom + 1,
            );
          }),
          const SizedBox(height: 8),
          mapButton(Icons.remove_rounded, () {
            mapController.move(
              mapController.camera.center,
              mapController.camera.zoom - 1,
            );
          }),
        ],
      ),
    );
  }

  Widget mapButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      elevation: 5,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, color: dark, size: 20),
        ),
      ),
    );
  }

  // ============================================================
  // BOTTOM SHEET NUEVO
  // ============================================================

  Widget floatingSheet() {
    return DraggableScrollableSheet(
      controller: sheetController,

      // POQUITO VISIBLE AL INICIO
      initialChildSize: .16,

      minChildSize: .13,

      // CASI TODA LA PARTE INFERIOR
      maxChildSize: .68,

      snap: true,

      snapSizes: const [.16, .38, .68],

      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: dark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            children: [
              // HANDLE
              const SizedBox(height: 10),

              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              const SizedBox(height: 15),

              // ==================================================
              // MINI PANEL
              // ==================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: orange.withOpacity(.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.two_wheeler_rounded,
                        color: orange,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            deliveryStatus,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            'Carlos · Repartidor',
                            style: TextStyle(color: muted, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${remainingEta.round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Text(
                          'min',
                          style: TextStyle(color: muted, fontSize: 9),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 19),

              // ==================================================
              // PROGRESO
              // ==================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: progressLine(),
              ),

              const SizedBox(height: 24),

              // ==================================================
              // INFORMACIÓN AMPLIADA
              // ==================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  children: [
                    infoRow(
                      icon: Icons.storefront_rounded,
                      title: 'Restaurante',
                      subtitle: 'Hamburguesería Demo',
                      active: true,
                    ),
                    connectorLine(),
                    infoRow(
                      icon: Icons.two_wheeler_rounded,
                      title: 'Repartidor',
                      subtitle: 'Carlos · ★ 4.9',
                      active: demoRunning || delivered,
                    ),
                    connectorLine(),
                    infoRow(
                      icon: Icons.home_rounded,
                      title: 'Cliente',
                      subtitle: 'Ubicación seleccionada',
                      active: delivered,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ==================================================
              // DATOS
              // ==================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    metric('DISTANCIA', '${distanceKm.toStringAsFixed(1)} km'),
                    const SizedBox(width: 8),
                    metric('TIEMPO', '${remainingEta.round()} min'),
                    const SizedBox(width: 8),
                    metric(
                      'ESTADO',
                      delivered
                          ? 'Listo'
                          : demoRunning
                          ? 'En ruta'
                          : 'Preparado',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // ==================================================
              // BOTONES
              // ==================================================
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: smallAction(
                        icon: Icons.my_location_rounded,
                        text: locating ? 'Buscando...' : 'Mi ubicación',
                        onTap: locating ? null : useMyLocation,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: loadingRoute
                        ? null
                        : demoRunning
                        ? stopDemo
                        : startDemo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: demoRunning
                          ? const Color(0xFF292F35)
                          : orange,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          demoRunning
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          demoRunning ? 'DETENER DEMO' : 'INICIAR DEMO',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 25),

              Center(
                child: Text(
                  'Desliza hacia abajo para volver al mapa',
                  style: TextStyle(
                    color: Colors.white.withOpacity(.28),
                    fontSize: 9,
                  ),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // LÍNEA DE PROGRESO
  // ============================================================

  Widget progressLine() {
    double progress = 0;

    if (routePoints.length > 1) {
      progress = currentRouteIndex / (routePoints.length - 1);
    }

    if (delivered) {
      progress = 1;
    }

    return Column(
      children: [
        Row(
          children: [
            progressDot(Icons.storefront_rounded, true),
            Expanded(
              child: Stack(
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: orange,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            progressDot(Icons.two_wheeler_rounded, demoRunning || delivered),
            Expanded(
              child: Container(
                height: 3,
                color: delivered ? orange : Colors.white12,
              ),
            ),
            progressDot(Icons.home_rounded, delivered),
          ],
        ),
        const SizedBox(height: 7),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'RESTAURANTE',
              style: TextStyle(
                color: muted,
                fontSize: 7,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'EN CAMINO',
              style: TextStyle(
                color: muted,
                fontSize: 7,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'CLIENTE',
              style: TextStyle(
                color: muted,
                fontSize: 7,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget progressDot(IconData icon, bool active) {
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: active ? orange : Colors.white10,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        color: active ? Colors.white : Colors.white30,
        size: 14,
      ),
    );
  }

  // ============================================================
  // INFO
  // ============================================================

  Widget infoRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool active,
  }) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: active
                ? orange.withOpacity(.13)
                : Colors.white.withOpacity(.05),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: active ? orange : Colors.white30, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: muted, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget connectorLine() {
    return Padding(
      padding: const EdgeInsets.only(left: 20),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(width: 2, height: 17, color: Colors.white10),
      ),
    );
  }

  // ============================================================
  // MÉTRICAS
  // ============================================================

  Widget metric(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.045),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(.05)),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: muted,
                fontSize: 7,
                fontWeight: FontWeight.w700,
                letterSpacing: .5,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // ACCIÓN UBICACIÓN
  // ============================================================

  Widget smallAction({
    required IconData icon,
    required String text,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: 47,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(
          text,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: orange,
          side: BorderSide(color: orange.withOpacity(.55)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ======================================================
          // MAPA COMPLETO
          // ======================================================
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: initialCustomer,
              initialZoom: 14.5,

              minZoom: 3,
              maxZoom: 19,

              onTap: (_, point) {
                selectCustomer(point);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.hamburgueseria_demo',
              ),

              // SOMBRA DE LA RUTA
              if (routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 10,
                      color: Colors.black.withOpacity(.20),
                    ),

                    // RUTA REAL
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5,
                      color: orange,
                    ),
                  ],
                ),

              // MARCADORES
              MarkerLayer(
                markers: [
                  Marker(
                    point: restaurant,
                    width: 105,
                    height: 90,
                    child: restaurantMarker(),
                  ),
                  Marker(
                    point: customer,
                    width: 100,
                    height: 90,
                    child: customerMarker(),
                  ),
                  Marker(
                    point: courier,
                    width: 115,
                    height: 100,
                    child: courierMarker(),
                  ),
                ],
              ),

              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          ),

          // HEADER
          header(),

          // CONTROLES
          mapControls(),

          // BOTTOM SHEET
          floatingSheet(),
        ],
      ),
    );
  }
}
