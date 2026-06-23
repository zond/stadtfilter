import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// A discovered UPnP/DLNA MediaRenderer (a network speaker such as Sonos or
/// WiiM) that we can push a stream URL to and control.
class DlnaRenderer {
  final String name;
  final Uri controlUrl; // AVTransport control endpoint
  final Uri? renderingControlUrl; // RenderingControl endpoint (volume), if any
  final String udn; // unique device id (for de-duping)

  const DlnaRenderer({
    required this.name,
    required this.controlUrl,
    required this.udn,
    this.renderingControlUrl,
  });

  bool get supportsVolume => renderingControlUrl != null;

  @override
  bool operator ==(Object other) => other is DlnaRenderer && other.udn == udn;
  @override
  int get hashCode => udn.hashCode;
}

/// Minimal UPnP control point: SSDP discovery + AVTransport (transport) and
/// RenderingControl (volume) actions. Pure Dart, no external plugin.
class DlnaService {
  static const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';
  static final InternetAddress _ssdpAddr = InternetAddress('239.255.255.250');
  static const _ssdpPort = 1900;

  final http.Client _http = http.Client();

  /// Discovers MediaRenderers on the local network.
  Future<List<DlnaRenderer>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final locations = <String>{};

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final text = String.fromCharCodes(dg.data);
      final loc = _header(text, 'location');
      if (loc != null) locations.add(loc);
    });

    final search = _mSearch(_avTransport);
    // Send a few times — UDP is lossy and devices answer with jitter.
    for (var i = 0; i < 3; i++) {
      socket.send(search, _ssdpAddr, _ssdpPort);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(timeout);
    socket.close();
    debugPrint('[dlna] SSDP returned ${locations.length} location(s)');

    final renderers = <String, DlnaRenderer>{};
    await Future.wait(locations.map((loc) async {
      final r = await _describe(loc);
      if (r != null) renderers[r.udn] = r;
    }));
    return renderers.values.toList();
  }

  /// Points the speaker at [streamUrl] and starts playback.
  Future<void> playStream(
    DlnaRenderer device,
    Uri streamUrl, {
    String title = 'Radio Stadtfilter',
  }) async {
    await _soap(device.controlUrl, _avTransport, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': streamUrl.toString(),
      'CurrentURIMetaData': _didl(streamUrl, title),
    });
    await _soap(device.controlUrl, _avTransport, 'Play', {
      'InstanceID': '0',
      'Speed': '1',
    });
  }

  Future<void> play(DlnaRenderer device) =>
      _soap(device.controlUrl, _avTransport, 'Play',
          {'InstanceID': '0', 'Speed': '1'});

  Future<void> pause(DlnaRenderer device) =>
      _soap(device.controlUrl, _avTransport, 'Pause', {'InstanceID': '0'});

  Future<void> stop(DlnaRenderer device) =>
      _soap(device.controlUrl, _avTransport, 'Stop', {'InstanceID': '0'});

  /// Reads the speaker's current volume (0–100), or null if unsupported.
  Future<int?> getVolume(DlnaRenderer device) async {
    final rc = device.renderingControlUrl;
    if (rc == null) return null;
    final doc = await _soap(rc, _renderingControl, 'GetVolume',
        {'InstanceID': '0', 'Channel': 'Master'});
    final text = doc?.findAllElements('CurrentVolume').firstOrNull?.innerText;
    return text == null ? null : int.tryParse(text);
  }

  /// Sets the speaker's volume (0–100).
  Future<void> setVolume(DlnaRenderer device, int volume) {
    final rc = device.renderingControlUrl;
    if (rc == null) return Future.value();
    return _soap(rc, _renderingControl, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': volume.clamp(0, 100).toString(),
    });
  }

  void dispose() => _http.close();

  // ---- SSDP / description --------------------------------------------------

  List<int> _mSearch(String st) => (StringBuffer()
        ..write('M-SEARCH * HTTP/1.1\r\n')
        ..write('HOST: 239.255.255.250:1900\r\n')
        ..write('MAN: "ssdp:discover"\r\n')
        ..write('MX: 2\r\n')
        ..write('ST: $st\r\n\r\n'))
      .toString()
      .codeUnits;

  String? _header(String response, String name) {
    final lower = name.toLowerCase();
    for (final line in response.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == lower) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  /// Fetches a device description and extracts its name + AVTransport and
  /// RenderingControl control URLs, if it is a renderer.
  Future<DlnaRenderer?> _describe(String location) async {
    try {
      final res = await _http
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final doc = XmlDocument.parse(res.body);
      final base = Uri.parse(location);

      final name = doc.findAllElements('friendlyName').firstOrNull?.innerText ??
          'Unknown speaker';
      final udn =
          doc.findAllElements('UDN').firstOrNull?.innerText ?? location;

      Uri? avTransport;
      Uri? renderingControl;
      for (final service in doc.findAllElements('service')) {
        final type = service.getElement('serviceType')?.innerText ?? '';
        final control = service.getElement('controlURL')?.innerText;
        if (control == null || control.isEmpty) continue;
        if (type.contains(':AVTransport:')) {
          avTransport = base.resolve(control);
        } else if (type.contains(':RenderingControl:')) {
          // Match the per-player RenderingControl, NOT Sonos's
          // GroupRenderingControl (which has no Get/SetVolume).
          renderingControl = base.resolve(control);
        }
      }
      if (avTransport == null) return null; // not something we can drive
      debugPrint('[dlna] "${name.trim()}" av=$avTransport rc=$renderingControl');

      return DlnaRenderer(
        name: name.trim(),
        udn: udn.trim(),
        controlUrl: avTransport,
        renderingControlUrl: renderingControl,
      );
    } catch (_) {
      // Not a usable renderer / unreachable — skip.
    }
    return null;
  }

  // ---- SOAP ----------------------------------------------------------------

  Future<XmlDocument?> _soap(
    Uri controlUrl,
    String serviceType,
    String action,
    Map<String, String> args,
  ) async {
    final argsXml = args.entries
        .map((e) => '<${e.key}>${_esc(e.value)}</${e.key}>')
        .join();
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">'
        '$argsXml'
        '</u:$action></s:Body></s:Envelope>';
    final res = await _http
        .post(
          controlUrl,
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$serviceType#$action"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 6));
    debugPrint('[dlna] $action ${args.values.join(",")} '
        '-> HTTP ${res.statusCode} @ $controlUrl');
    if (res.statusCode >= 400) {
      debugPrint('[dlna] $action fault: '
          '${res.body.replaceAll(RegExp(r"\s+"), " ").trim()}');
      throw Exception('UPnP $action failed (${res.statusCode})');
    }
    try {
      return XmlDocument.parse(res.body);
    } catch (_) {
      return null;
    }
  }

  /// DIDL-Lite metadata describing the stream as a radio broadcast. Sonos in
  /// particular rejects SetAVTransportURI without sensible metadata.
  String _didl(Uri url, String title) {
    return '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_esc(title)}</dc:title>'
        '<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>'
        '<res protocolInfo="http-get:*:audio/mpeg:*">${_esc(url.toString())}</res>'
        '</item></DIDL-Lite>';
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
