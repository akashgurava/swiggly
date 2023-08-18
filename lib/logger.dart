import 'package:logger/logger.dart';

class ServicePrinter extends LogPrinter {
  String name;

  ServicePrinter(this.name);

  @override
  List<String> log(LogEvent event) {
    return ["${event.time} - ${event.level.name.split(".")[0].toUpperCase()} - $name - ${event.message}"];
  }
}

class SyncServicePrinter extends ServicePrinter {
  SyncServicePrinter(String serverIp, String clientIp, int port)
      : super("SyncService - Server: tcp://$serverIp/$port - Client: $clientIp");
}

extension SyncServiceLogger on Logger {
  static Logger service() {
    return Logger(printer: ServicePrinter("SyncService"));
  }

  static Logger server(String ip, int port) {
    return Logger(printer: ServicePrinter("SyncService.Server:$ip:$port"));
  }

  static Logger client(String ip) {
    return Logger(printer: ServicePrinter("SyncService.Client:$ip"));
  }

  static Logger connection(String serverIp, String clientIp) {
    return Logger(printer: ServicePrinter("SyncService.Connection:$serverIp-$clientIp"));
  }
}
