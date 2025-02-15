import 'dart:async';
import 'package:connectivity/connectivity.dart';
import 'package:dio/dio.dart';
import 'package:dio_retry/src/http_status_codes.dart';

typedef RetryEvaluator = FutureOr<bool> Function(DioError error, int attempt);
typedef RefreshTokenFunction = Future<void> Function();
typedef AccessTokenGetter = String Function();
typedef ToNoInternetPageNavigator = Future<void> Function();

/// An interceptor that will try to send failed request again
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    this.logPrint,
    this.retries = 1,
    this.refreshTokenFunction,
    this.accessTokenGetter,
    required this.toNoInternetPageNavigator,
    this.moreRequestAwaitDuration = const Duration(seconds: 2),
    this.retryDelays = const [
      Duration(seconds: 1),
    ],
  });

  /// The original dio
  final Dio dio;

  ///refresh token functions get api client
  final RefreshTokenFunction? refreshTokenFunction;

  /// More request await duration
  final Duration? moreRequestAwaitDuration;

  /// Access token getter from storage
  final AccessTokenGetter? accessTokenGetter;

  /// ToNoInternetPage navigate
  final ToNoInternetPageNavigator toNoInternetPageNavigator;

  /// For logging purpose
  final Function(String message)? logPrint;

  /// The number of retry in case of an error
  final int retries;

  /// The delays between attempts.
  /// Empty [retryDelays] means no delay.
  ///
  /// If [retries] count more than [retryDelays] count,
  /// the last value of [retryDelays] will be used.
  final List<Duration> retryDelays;

  var _isRefreshing = false;
  var _isNavigatingNoInternet = false;

  /// Evaluating if a retry is necessary.regarding the error.
  ///
  /// It can be a good candidate for additional operations too, like
  /// updating authentication token in case of a unauthorized error (be careful
  /// with concurrency though).
  ///
  /// Defaults to [defaultRetryEvaluator].
  // final RetryEvaluator _retryEvaluator;

  /// Returns true only if the response hasn't been cancelled or got
  /// a bas status code.

  // ignore: avoid-unused-parameters
  FutureOr<bool> defaultRetryEvaluator(DioError error, int attempt) async {
    bool? shouldRetry;
    if (error.type == DioErrorType.response) {
      final statusCode = error.response?.statusCode;
      shouldRetry = statusCode != null ? isRetryable(statusCode) : true;
      if ((statusCode ?? 500) == 401 && !_isRefreshing) {
        _isRefreshing = true;
        await refreshTokenFunction!();
        _isRefreshing = false;
      } else if ((statusCode ?? 500) == 401 && _isRefreshing) {
        await Future.delayed(moreRequestAwaitDuration ?? Duration(seconds: 2));
      }
    }
    if (error.type == DioErrorType.other) {
      var connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none && !_isNavigatingNoInternet) {
        _isNavigatingNoInternet = true;
        await toNoInternetPageNavigator();
        _isNavigatingNoInternet = false;
      }
      shouldRetry = true;
    }
    return shouldRetry ?? false;
  }

  @override
  Future onError(DioError err, ErrorInterceptorHandler handler) async {
    if (err.requestOptions.disableRetry) return super.onError(err, handler);
    var attempt = err.requestOptions._attempt + 1;
    final shouldRetry = attempt <= retries && await defaultRetryEvaluator(err, attempt);

    if (!shouldRetry) return super.onError(err, handler);

    err.requestOptions._attempt = attempt;
    final delay = _getDelay(attempt);
    logPrint?.call(
      '[${err.requestOptions.uri}] An error occurred during request, '
      'trying again '
      '(attempt: $attempt/$retries, '
      'wait ${delay.inMilliseconds} ms, '
      'error: ${err.error})',
    );
    if (delay != Duration.zero) await Future<void>.delayed(delay);

    var header = Map<String, dynamic>();
    header.addAll(err.requestOptions.headers);
    if (accessTokenGetter != null) {
      header['Authorization'] = accessTokenGetter!();
    }
    // ignore: unawaited_futures
    err.requestOptions.headers = header;
    try {
      dio.fetch<void>(err.requestOptions).then((value) {
        handler.resolve(value);
      }).catchError(
        () => handler.resolve(
          Response(
            requestOptions: RequestOptions(path: ''),
            data: {},
          ),
        ),
      );
    } catch (e) {
      handler.resolve(Response(
        requestOptions: RequestOptions(path: ''),
        data: {},
      ));
    }
  }

  Duration _getDelay(int attempt) {
    if (retryDelays.isEmpty) return Duration.zero;
    return attempt - 1 < retryDelays.length ? retryDelays[attempt - 1] : retryDelays.last;
  }
}

Future<ConnectivityResult> connect() async => await Connectivity().checkConnectivity();

ConnectivityResult get connectNone => ConnectivityResult.none;

ConnectivityResult get connectMobile => ConnectivityResult.mobile;

ConnectivityResult get connectWifi => ConnectivityResult.wifi;

extension RequestOptionsX on RequestOptions {
  static const _kAttemptKey = 'ro_attempt';
  static const _kDisableRetryKey = 'ro_disable_retry';

  int get _attempt => extra[_kAttemptKey] ?? 0;

  set _attempt(int value) => extra[_kAttemptKey] = value;

  bool get disableRetry => (extra[_kDisableRetryKey] as bool?) ?? false;

  set disableRetry(bool value) => extra[_kDisableRetryKey] = value;
}
