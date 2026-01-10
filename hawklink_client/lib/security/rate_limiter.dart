import 'dart:io';

class RateLimiter {
  // Max requests per second
  static const int _kMaxRequestsPerSecond = 10;
  // Max requests per minute (burst)
  static const int _kMaxRequestsPerMinute = 200;
  
  // Track requests per socket
  static final Map<Socket, List<DateTime>> _requestLog = {};
  
  /// Check if the request is allowed
  static bool isAllowed(Socket socket) {
    final now = DateTime.now();
    final log = _requestLog.putIfAbsent(socket, () => []);
    
    // Prune old logs (> 1 minute)
    log.removeWhere((t) => now.difference(t).inMinutes >= 1);
    
    // Check constraints
    final logsLastSecond = log.where((t) => now.difference(t).inSeconds < 1);
    
    if (logsLastSecond.length >= _kMaxRequestsPerSecond) {
      return false; // Rate limit exceeded (Immediate)
    }
    
    if (log.length >= _kMaxRequestsPerMinute) {
      return false; // Rate limit exceeded (Minute)
    }
    
    // Log new request
    log.add(now);
    return true;
  }
  
  /// Clean up disconnected sockets
  static void cleanup(Socket socket) {
    _requestLog.remove(socket);
  }
}
