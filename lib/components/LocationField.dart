import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:intl/intl.dart';
import 'package:darksky_weather/darksky_weather_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'package:conditions/models/SunData.dart';
import 'package:conditions/models/MoonData.dart';

class LocationField extends StatefulWidget {
  LocationField(this.updateSunData, this.updateMoonData, this.updateDarkSkyData,
      this.updateUnitIdx);

  final Function(Future<SunData>) updateSunData;
  final Function(Future<List<MoonData>>) updateMoonData;
  final Function(Future<Forecast>) updateDarkSkyData;
  final Function(int) updateUnitIdx;
  _LocationFieldState createState() => new _LocationFieldState();
}

class _LocationFieldState extends State<LocationField> {
  bool locUsed;
  final TextEditingController locationController = TextEditingController();
  // Geolocator geolocator = Geolocator();
  bool invalidLoc;
  String _darkSkyKey;
  String _hereAppId;
  String _hereAppCode;

  // Load in the Dark Sky API Key from the config file
  Future<String> loadAsset() async {
    return await rootBundle.loadString('assets/config.json');
  }

  // Assign key to variable
  _LocationFieldState() {
    loadAsset().then((val) => setState(() {
          final Map<String, dynamic> data = jsonDecode(val);
          _darkSkyKey = data['dark_sky_key'];
          _hereAppId = data['here_app_id'];
          _hereAppCode = data['here_app_code'];
        }));
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled don't continue
      // accessing the position and request users of the
      // App to enable the location services.
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied, next time you could try
        // requesting permissions again (this is also where
        // Android's shouldShowRequestPermissionRationale
        // returned true. According to Android guidelines
        // your App should show an explanatory UI now.
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    // When we reach here, permissions are granted and we can
    // continue accessing the position of the device.
    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.lowest);
  }

  void fetchInfo({Position coords, String location}) async {
    List<Placemark> placemark;
    List<Location> locations;
    if (coords != null) {
      placemark =
          await placemarkFromCoordinates(coords.latitude, coords.longitude);
    } else {
      try {
        locations = await locationFromAddress(location);
        placemark = await placemarkFromCoordinates(
            locations[0].latitude, locations[0].longitude);
      } on PlatformException catch (_) {
        setState(() {
          invalidLoc = true;
        });
        widget.updateSunData(Future<SunData>.value(null));
        widget.updateMoonData(Future<List<MoonData>>.value(null));
        widget.updateDarkSkyData(Future<Forecast>.value(null));
        return null;
      }
      if (locations != null) {
        coords = Position(
            latitude: locations[0].latitude,
            longitude: locations[0].longitude,
            accuracy: null,
            altitude: null,
            heading: null,
            speed: null,
            speedAccuracy: null,
            timestamp: null);
      }
    }
    widget.updateSunData(callSunAPI(coords, placemark[0]));
    widget.updateMoonData(callMoonApi(coords));
    widget.updateDarkSkyData(callDarkSkyAPI(coords));
  }

  Future<SunData> callSunAPI(Position coords, Placemark placemark) async {
    final String today = DateFormat("yyyy-MM-dd").format(DateTime.now());
    final String placeName =
        '${placemark.locality}, ${placemark.administrativeArea}';
    locationController.text = placeName;

    // SSL Cert Expired so had to change it to http, at least for now
    Uri sunApi = Uri.parse(
        'http://api.sunrise-sunset.org/json?lat=${coords.latitude}&lng=${coords.longitude}&date=$today&formatted=0');
    final response = await http.get(sunApi);

    if (response.statusCode == 200) {
      setState(() {
        invalidLoc = false;
      });
      return SunData.fromJson(json.decode(response.body));
    } else {
      setState(() {
        invalidLoc = true;
      });
      return null;
    }
  }

  Future<List<MoonData>> callMoonApi(Position coords) async {
    Uri hereApi = Uri.parse(
        'https://weather.cit.api.here.com/weather/1.0/report.json?product=forecast_astronomy&latitude=${coords.latitude}&longitude=${coords.longitude}&app_id=$_hereAppId&app_code=$_hereAppCode');
    final response = await http.get(hereApi);

    if (response.statusCode == 200) {
      final List<MoonData> moonDataList = [];
      final List<dynamic> jsonList =
          json.decode(response.body)['astronomy']['astronomy'];
      for (Map<String, dynamic> item in jsonList) {
        moonDataList.add(MoonData.fromJson(item));
      }
      return moonDataList;
    } else {
      return Future.error('Unable to fetch moon data');
    }
  }

  Future<Forecast> callDarkSkyAPI(Position coords) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    int unitIdx = (prefs.getInt('unit') ?? 3);
    widget.updateUnitIdx(unitIdx);
    var darksky = new DarkSkyWeather(_darkSkyKey,
        language: Language.English, units: Units.values[unitIdx]);
    var forecast = await darksky.getForecast(coords.latitude, coords.longitude);

    if (forecast.currently == null) {
      return Future.error('Error loading Dark Sky data');
    }
    return forecast;
  }

  @override
  void initState() {
    locUsed = false;
    invalidLoc = false;
    locationController.text = 'Pittsburgh, PA';
    super.initState();
  }

  @override
  void dispose() {
    // Clean up the controller when the Widget is disposed
    locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.all(10.0),
      child: TextField(
        controller: locationController,
        onSubmitted: (value) {
          setState(() {
            locUsed = false;
          });
          fetchInfo(location: value);
        },
        decoration: InputDecoration(
            labelText: 'Enter a location',
            prefix: IconButton(
              icon: Icon(FontAwesomeIcons.locationArrow,
                  color: locUsed ? Colors.blueAccent[700] : Colors.grey),
              onPressed: () async {
                final Position currentLocation =
                    await _determinePosition();
                setState(() {
                  locUsed = true;
                });
                fetchInfo(coords: currentLocation);
                FocusScope.of(context)
                    .requestFocus(new FocusNode()); // Dismiss the keyboard
              },
            ),
            suffix: IconButton(
              icon: Icon(FontAwesomeIcons.search),
              onPressed: () {
                setState(() {
                  locUsed = false;
                });
                fetchInfo(location: locationController.text);
                FocusScope.of(context)
                    .requestFocus(new FocusNode()); // Dismiss the keyboard
              },
            ),
            errorBorder: OutlineInputBorder(
              borderSide: invalidLoc
                  ? BorderSide(width: 2, color: Colors.red)
                  : BorderSide(),
            ),
            errorText: invalidLoc ? 'Please enter a valid US location' : null),
      ),
    );
  }
}
