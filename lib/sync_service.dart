// ignore_for_file: unused_field

import "dart:io";
import "dart:typed_data";

import "package:logger/logger.dart";
import "package:network_info_plus/network_info_plus.dart";

import "constants.dart";
import "logger.dart";

/// Server for data synchronization.
class SyncServer {
  final ServerSocket _inner;
  final Logger _logger;

  static var connections = <SyncConnection>[];

  SyncServer._(this._inner, this._logger);

  static Future<SyncServer> from(String ip, int port) async {
    var logger = SyncServiceLogger.server(ip, port);

    logger.v("Starting.");

    final ServerSocket server;
    try {
      server = await ServerSocket.bind(ip, port);
    } on SocketException {
      logger.e("Another instance of server already running. Exiting.");
      rethrow;
    } catch (e) {
      logger.e("Unable to start sync server. Reason: $e. Exiting.");
      rethrow;
    }

    server.listen((Socket connection) async {
      connections.add(await SyncConnection.x(server, connection));
    });

    logger.v("Started.");
    return SyncServer._(server, logger);
  }
}

/// Client for data synchronization.
class SyncClient {
  final Socket _inner;
  final Logger _logger;

  SyncClient._(this._inner, this._logger);

  static Future<SyncClient> from(String ip, int port) async {
    var logger = SyncServiceLogger.client(ip);

    logger.v("Starting.");

    final client = await Socket.connect(ip, port);

    client.listen(
      (Uint8List data) {
        final serverResponse = String.fromCharCodes(data);
        logger.v("Received response: $serverResponse");
      },
      onError: (error) {
        logger.e("Error. $error. Destroying client.");
        client.destroy();
      },
      onDone: () {
        logger.i("Server closed. Destroying client.");
        client.destroy();
      },
    );

    logger.v("Started.");
    return SyncClient._(client, logger);
  }
}

/// Connection between a [SyncServer] and [SyncClient] for data synchronization.
class SyncConnection {
  final Logger _logger;

  SyncConnection._(this._logger);

  static Future<SyncConnection> x(ServerSocket server, Socket connection) async {
    var logger = SyncServiceLogger.connection(server.address.address, connection.remoteAddress.address);

    connection.listen(
      (Uint8List data) async {
        final msg = String.fromCharCodes(data);
        logger.v("Received new message from client. Message: $msg");

        if (msg == echoReq) {
          connection.write(echoRes);
        }
      },
      onError: (error) {
        logger.e("Error. $error. Closing connection.");
        connection.close();
      },
      onDone: () {
        logger.e("Client left. Closing connection.");
        connection.close();
      },
    );
    return SyncConnection._(logger);
  }
}

/// Data synchronization service.
/// This service is only accessible using the singleton [SyncService.getService].
///
/// This service scans the local network for any existing SyncService server at [serverPort].
/// If no server is found, A server is started from here.
class SyncService {
  /// Private singleton instance.
  static SyncService? _instance;

  /// Logger for the service.
  static final Logger _logger = SyncServiceLogger.service();

  /// Server for the sync service. This will be `null` if we use any existing server in network.
  SyncServer? server;

  /// Client for the sync service.
  SyncClient client;

  /// Private constructor to prevent new objects.
  SyncService._(this.server, this.client);

  /// Primary method to get or create a [SyncService].
  /// A SyncService is created if it does not already exist.
  static Future<SyncService> getService() async {
    _logger.v("Get SyncService.");
    if (_instance == null) {
      _logger.v("SyncService not yet initialized.");
      return _makeService();
    }
    return _instance!;
  }

  /// Create a new [SyncService].
  /// 1. We retrieve the IP Address of current machine. If we are unable to get IP address we exit.
  /// 2. We then scan local network to see if a server is already running on [serverPort] in the local network.
  /// 3. If another server is already running we just create a new client and establish connection to the server.
  /// 4. If no server found we start the server.
  static Future<SyncService> _makeService() async {
    _logger.v("Creating SyncService.");

    var myIp = await NetworkInfo().getWifiIP();
    _logger.i("Current device IP Address: $myIp.");

    if (myIp == null) {
      throw const SocketException("Unable to fetch IP address of device.");
    }

    var serverIp = await scanNetwork(myIp, serverPort);
    SyncServer? server;
    SyncClient client;
    if (serverIp == null) {
      _logger.i("No running server found. Starting server from current device.");

      server = await SyncServer.from(myIp, serverPort);
      client = await SyncClient.from(myIp, serverPort);
    } else {
      _logger.i("Existing server found at $serverIp. Connecting.");

      client = await SyncClient.from(serverIp, serverPort);
    }

    var instance = SyncService._(server, client);
    _instance = instance;
    _logger.v("Created SyncService.");
    return instance;
  }

  /// Check if a server is already running and if its a valid server.
  /// 1. We try to connect on [testServerIp] [port].
  /// 2. If we connect successfully we send [echoReq] message from test client.
  /// 3. if the response from server matches [echoRes], we have a valid server.
  static Future<String?> _testServer(String testServerIp, int port) async {
    var logger = SyncServiceLogger.client(testServerIp);

    Socket client;
    try {
      client = await Socket.connect(testServerIp, port, timeout: socketSearchTimeout);
      logger.i("Server found at IP: $testServerIp.");
    } catch (_) {
      return null;
    }

    client.listen(
      (Uint8List data) {
        final serverResponse = String.fromCharCodes(data);
        if (serverResponse != echoRes) {
          logger.i("Server at IP: $testServerIp. Responded with unexpected response: $serverResponse.");
          client.destroy();
          throw SocketException("Unexpected response: $serverResponse");
        } else {
          logger.i("Server at IP: $testServerIp. Responded with expected response.");
          client.destroy();
        }
      },
      onError: (error) {
        logger.e("Error. $error. Destroying client.");
        client.destroy();
      },
      onDone: () {
        logger.i("Server closed. Destroying client.");
        client.destroy();
      },
    );

    client.write(echoReq);
    return testServerIp;
  }

  /// Scan the local network to see if we have a valid server already running.
  /// 1. We make 255 parallel requests with for each valid ip in the local network.
  /// 2. If we have any server that returns a valid response we consider it a valid server.
  static Future<String?> scanNetwork(String ip, int port) async {
    _logger.i("Searching local network for existing servers.");

    final String subnet = ip.substring(0, ip.lastIndexOf("."));
    var futures = <Future<String?>>[];
    for (var i = 0; i < 255; i++) {
      String ip = "$subnet.$i";
      futures.add(_testServer(ip, port));
    }
    var responses = await Future.wait(futures);
    return responses.where((element) => element != null).firstOrNull;
  }
}
