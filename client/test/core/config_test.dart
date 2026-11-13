import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/core/config.dart';

void main() {
  group('releaseConfigProblem', () {
    test('a release build on the production API is fine', () {
      expect(
        releaseConfigProblem(
          'https://mixtape-api.goalympics.workers.dev',
          release: true,
        ),
        isNull,
      );
    });

    test('a release build without API_BASE_URL is refused', () {
      expect(
        releaseConfigProblem('http://localhost:8787', release: true),
        contains('API_BASE_URL'),
      );
      expect(
        releaseConfigProblem('https://127.0.0.1:8787', release: true),
        isNotNull,
      );
    });

    test('a release build over plain http is refused', () {
      expect(
        releaseConfigProblem('http://api.example.com', release: true),
        isNotNull,
      );
    });

    test('debug builds may use localhost', () {
      expect(
        releaseConfigProblem('http://localhost:8787', release: false),
        isNull,
      );
    });

    test('a release build with an odd share base is refused', () {
      const api = 'https://mixtape-api.goalympics.workers.dev';
      expect(
        releaseConfigProblem(
          api,
          release: true,
          shareBaseUrl: 'https://miixtape.netlify.app',
        ),
        isNull,
      );
      expect(
        releaseConfigProblem(
          api,
          release: true,
          shareBaseUrl: 'http://miixtape.netlify.app',
        ),
        contains('SHARE_BASE_URL'),
      );
      expect(
        releaseConfigProblem(
          api,
          release: true,
          shareBaseUrl: 'https://localhost:5173',
        ),
        contains('SHARE_BASE_URL'),
      );
      expect(
        releaseConfigProblem(
          api,
          release: true,
          shareBaseUrl: 'https://miixtape.netlify.app/app',
        ),
        contains('SHARE_BASE_URL'),
      );
    });

    test('the default share base is the production site', () {
      expect(AppConfig.shareBaseUrl, 'https://miixtape.netlify.app');
    });
  });
}
