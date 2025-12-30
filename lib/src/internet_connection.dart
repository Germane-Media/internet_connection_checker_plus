// src/internet_connection_base.dart
part of '../internet_connection_checker_plus.dart';

/// A callback function for checking if a specific internet endpoint is
/// reachable.
///
/// Takes a single [InternetCheckOption] and returns a
/// [Future] that completes with an [InternetCheckResult].
///
/// This allows for complete customization of how connectivity is checked for
/// each endpoint.
typedef ConnectivityCheckCallback = Future<InternetCheckResult> Function(
  InternetCheckOption option,
);

/// A utility class for checking internet connectivity status with
/// performance tracking and smart endpoint selection.
class InternetConnection {
  /// Returns an instance of [InternetConnection].
  ///
  /// This is a singleton class, meaning that there is only one instance of it.
  factory InternetConnection() => _instance;

  /// Creates an enhanced instance with performance tracking and smart DNS.
  ///
  /// The [checkInterval] defines the interval duration between status checks.
  ///
  /// The [customCheckOptions] specify the list of [Uri]s to check for
  /// connectivity. If not provided, default platform-specific endpoints are used.
  ///
  /// The [enableStrictCheck] flag indicates whether all endpoints must succeed
  /// to consider the internet as connected.
  ///
  /// The [customConnectivityCheck] allows you to provide a custom method for
  /// checking endpoint reachability.
  InternetConnection.createInstance({
    Duration? checkInterval,
    List<InternetCheckOption>? customCheckOptions,
    this.enableStrictCheck = false,
    this.customConnectivityCheck,
  }) : _checkInterval = checkInterval ?? _defaultCheckInterval {
    // Use custom options if provided, otherwise use platform-specific defaults
    _internetCheckOptions = customCheckOptions ?? _getPlatformDefaultOptions();

    _statusController.onListen = _maybeEmitStatusUpdate;
    _statusController.onCancel = _handleStatusChangeCancel;
  }

  /// The default check interval duration.
  static const _defaultCheckInterval = Duration(seconds: 10);

  /// Get platform-specific default options
  List<InternetCheckOption> _getPlatformDefaultOptions() {
    if (kIsWeb) {
      return [
        InternetCheckOption(
          uri: Uri.parse('https://corsproxy.io/?https://www.google.com/favicon.ico'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://jsonplaceholder.typicode.com/posts/1'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://httpbin.org/ip'),
          timeout: Duration(seconds: 2),
        ),
        // Super fast endpoint
        InternetCheckOption(
          uri: Uri.parse('https://httpbin.org/status/200'),
          timeout: Duration(milliseconds: 1500),
          headers: {'Accept': '*/*'},
        ),
      ];
    } else {
      return [
        InternetCheckOption(
          uri: Uri.parse('https://www.google.com'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://www.cloudflare.com'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://one.one.one.one'),
          timeout: Duration(milliseconds: 1500), // DNS service, usually fastest
        ),
        InternetCheckOption(
          uri: Uri.parse('https://icanhazip.com/'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://flashstart.com/'),
          timeout: Duration(seconds: 2),
        ),
        InternetCheckOption(
          uri: Uri.parse('https://controld.com/'),
          timeout: Duration(seconds: 2),
        ),
      ];
    }
  }

  // Performance tracking
  final Map<String, _EndpointStats> _endpointStats = {};
  final Random _random = Random();

  /// The list of [Uri]s used for checking internet reachability.
  late List<InternetCheckOption> _internetCheckOptions;

  /// The controller for the internet connection status stream.
  final _statusController = StreamController<InternetStatus>.broadcast();

  /// The singleton instance of [InternetConnection].
  static final _instance = InternetConnection.createInstance();

  /// The duration between consecutive status checks.
  ///
  /// Defaults to [_defaultCheckInterval].
  Duration _checkInterval;

  /// If `true`, all checks must be successful to consider the internet as
  /// connected.
  ///
  /// If `false`, only one successful check is required to consider the internet
  /// as connected.
  ///
  /// Defaults to `false`.
  final bool enableStrictCheck;

  /// Function to check reachability of a single network endpoint.
  ///
  /// This can be customized to allow for different ways of checking
  /// connectivity.
  final ConnectivityCheckCallback? customConnectivityCheck;

  /// The last known internet connection status result.
  InternetStatus? _lastStatus;

  /// The handle for the timer used for periodic status checks.
  Timer? _timerHandle;

  /// Connectivity subscription.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Checks if the [Uri] specified in [option] is reachable.
  Future<InternetCheckResult> _checkReachabilityFor(
    InternetCheckOption option,
  ) async {
    try {
      if (customConnectivityCheck != null) {
        return customConnectivityCheck!(option);
      }

      final response = await http.head(option.uri, headers: option.headers).timeout(option.timeout);

      return InternetCheckResult(
        option: option,
        isSuccess: option.responseStatusFn(response),
      );
    } catch (_) {
      return InternetCheckResult(
        option: option,
        isSuccess: false,
      );
    }
  }

  /// Enhanced hasInternetAccess with performance tracking and smart selection
  Future<bool> get hasInternetAccess async {
    // Get smartly ordered options
    final orderedOptions = _getOrderedCheckOptions();

    int successCount = 0;

    for (final option in orderedOptions) {
      final startTime = DateTime.now();

      try {
        final result = await _checkReachabilityFor(option);

        final responseTime = DateTime.now().difference(startTime);

        // Update statistics
        _updateEndpointStats(option.uri, result.isSuccess, responseTime);

        if (result.isSuccess) {
          successCount++;

          if (!enableStrictCheck) {
            // Quick success in non-strict mode
            return true;
          }
        } else if (enableStrictCheck) {
          // Quick failure in strict mode
          return false;
        }
      } catch (_) {
        _updateEndpointStats(option.uri, false, option.timeout);

        if (enableStrictCheck) {
          return false;
        }
        continue;
      }
    }

    return enableStrictCheck ? successCount == orderedOptions.length : successCount > 0;
  }

  /// Returns the current internet connection status.
  Future<InternetStatus> get internetStatus async => await hasInternetAccess ? InternetStatus.connected : InternetStatus.disconnected;

  /// Smart endpoint ordering
  List<InternetCheckOption> _getOrderedCheckOptions() {
    // Start with all options
    final allOptions = List<InternetCheckOption>.from(_internetCheckOptions);

    // Platform-specific prioritization
    if (kIsWeb) {
      return _prioritizeWebOptions(allOptions);
    }

    return _prioritizeByPerformance(allOptions);
  }

  /// Web-specific prioritization
  List<InternetCheckOption> _prioritizeWebOptions(List<InternetCheckOption> options) {
    // Separate endpoints by CORS compatibility
    final corsOptions = <InternetCheckOption>[];
    final nonCorsOptions = <InternetCheckOption>[];

    for (final option in options) {
      if (_isCorsFriendly(option.uri)) {
        corsOptions.add(option);
      } else {
        nonCorsOptions.add(option);
      }
    }

    // Shuffle within priority groups
    corsOptions.shuffle(_random);
    nonCorsOptions.shuffle(_random);

    return [...corsOptions, ...nonCorsOptions];
  }

  /// Performance-based prioritization
  List<InternetCheckOption> _prioritizeByPerformance(List<InternetCheckOption> options) {
    // If no stats yet, return shuffled list
    if (_endpointStats.isEmpty) {
      final shuffled = List<InternetCheckOption>.from(options)..shuffle(_random);
      return shuffled;
    }

    // Calculate scores
    final scoredOptions = options.map((option) {
      final score = _getReliabilityScore(option.uri);
      return _ScoredOption(option: option, score: score);
    }).toList();

    // Sort by score (highest first)
    scoredOptions.sort((a, b) => b.score.compareTo(a.score));

    // Add some randomness for top contenders
    return _addRandomness(scoredOptions.map((s) => s.option).toList());
  }

  /// Check if URI is CORS-friendly
  bool _isCorsFriendly(Uri uri) {
    const corsFriendlyDomains = ['corsproxy.io', 'jsonplaceholder.typicode.com', 'httpbin.org'];

    return corsFriendlyDomains.contains(uri.host);
  }

  /// Add randomness to avoid always same order
  List<InternetCheckOption> _addRandomness(List<InternetCheckOption> options) {
    if (options.length <= 1) return options;

    // If top scores are close, shuffle top 3
    if (options.length >= 3) {
      final firstScore = _getReliabilityScore(options[0].uri);
      final thirdScore = _getReliabilityScore(options[2].uri);

      if ((firstScore - thirdScore).abs() < 0.15) {
        final topThree = options.sublist(0, 3)..shuffle(_random);
        return [...topThree, ...options.sublist(3)];
      }
    }

    return options;
  }

  /// Calculate reliability score for an endpoint
  double _getReliabilityScore(Uri uri) {
    final key = uri.toString();
    final stats = _endpointStats[key];

    // Default score for untested endpoints with slight randomness
    if (stats == null) return 0.5 + (_random.nextDouble() * 0.1);

    // Success rate
    final successRate = stats.successCount / math.max(1, stats.totalAttempts);

    // Response time score (faster = better)
    final avgResponseTimeMs =
        stats.successCount > 0 ? stats.totalResponseTime.inMilliseconds / stats.successCount : 10000; // 10 seconds default if no successes

    // Normalize: 0-2000ms = good, 2000-10000ms = decreasing score
    final timeScore = avgResponseTimeMs <= 2000 ? 1.0 : math.max(0.1, 1.0 - (avgResponseTimeMs - 2000) / 8000);

    // Weighted score: 70% success rate, 30% speed
    return (successRate * 0.7) + (timeScore * 0.3);
  }

  /// Update endpoint statistics
  void _updateEndpointStats(Uri uri, bool success, Duration responseTime) {
    final key = uri.toString();
    final stats = _endpointStats[key] ??= _EndpointStats();

    stats.totalAttempts++;
    stats.lastUpdated = DateTime.now();

    if (success) {
      stats.successCount++;
      stats.totalResponseTime += responseTime;
    }

    // Clean up old stats occasionally
    if (_endpointStats.length > 50) {
      _cleanupOldStats();
    }
  }

  /// Clean up oldest stats
  void _cleanupOldStats() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _endpointStats.forEach((key, stats) {
      if (now.difference(stats.lastUpdated).inDays > 7) {
        keysToRemove.add(key);
      }
    });

    for (final key in keysToRemove) {
      _endpointStats.remove(key);
    }

    // If still too many, remove oldest
    if (_endpointStats.length > 50) {
      final oldestKey = _endpointStats.entries.reduce((a, b) => a.value.lastUpdated.isBefore(b.value.lastUpdated) ? a : b).key;
      _endpointStats.remove(oldestKey);
    }
  }

  // Stream handling methods
  Future<void> _maybeEmitStatusUpdate() async {
    _startListeningToConnectivityChanges();
    _timerHandle?.cancel();

    final currentStatus = await internetStatus;

    if (!_statusController.hasListener) return;

    if (_lastStatus != currentStatus && _statusController.hasListener) {
      _statusController.add(currentStatus);
    }

    _timerHandle = Timer(_checkInterval, _maybeEmitStatusUpdate);
    _lastStatus = currentStatus;
  }

  void _handleStatusChangeCancel() {
    if (_statusController.hasListener) return;

    _connectivitySubscription?.cancel().then((_) {
      _connectivitySubscription = null;
    });
    _timerHandle?.cancel();
    _timerHandle = null;
    _lastStatus = null;
  }

  void _startListeningToConnectivityChanges() {
    if (_connectivitySubscription != null) return;
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (_) {
        if (_statusController.hasListener) {
          _maybeEmitStatusUpdate();
        }
      },
      onError: (_, __) {},
    );
  }

  /// Public API
  Stream<InternetStatus> get onStatusChange => _statusController.stream;
  InternetStatus? get lastTryResults => _lastStatus;
  Duration get checkInterval => _checkInterval;

  /// Updates the interval between connection checks.
  void setIntervalAndResetTimer(Duration duration) {
    _checkInterval = duration;
    _timerHandle?.cancel();
    _timerHandle = Timer(_checkInterval, _maybeEmitStatusUpdate);
  }

  /// Reset all statistics
  void resetStatistics() {
    _endpointStats.clear();
  }

  /// Get performance report for debugging
  Map<String, dynamic> getPerformanceReport() {
    return _endpointStats.map((key, stats) => MapEntry(key, {
          'totalAttempts': stats.totalAttempts,
          'successCount': stats.successCount,
          'successRate': stats.successCount / math.max(1, stats.totalAttempts),
          'avgResponseTimeMs': stats.successCount > 0 ? stats.totalResponseTime.inMilliseconds / stats.successCount : 0,
          'lastUpdated': stats.lastUpdated.toIso8601String(),
        }));
  }
}

/// Statistics for an endpoint
class _EndpointStats {
  int totalAttempts = 0;
  int successCount = 0;
  Duration totalResponseTime = Duration.zero;
  DateTime lastUpdated = DateTime.now();
}

/// Helper class for scoring options
class _ScoredOption {
  final InternetCheckOption option;
  final double score;

  _ScoredOption({required this.option, required this.score});
}
