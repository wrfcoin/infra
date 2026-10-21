/**
 * Sensor Data Source
 *
 * Queries the WRFCoin backend weather API for recent station readings.
 * Groups readings by stationId for LLM-based pattern detection.
 *
 * infra#88: Watchdog IoT Sensor Data Quality Screening
 */

export interface SensorDataConfig {
  backend_api_url: string;
  window_minutes: number;
  max_stations_per_batch: number;
}

export interface SensorReading {
  timestamp: string;
  temperature?: number;
  humidity?: number;
  pressure?: number;
  windSpeed?: number;
  airQuality?: number;
}

export interface StationReadings {
  stationId: string;
  readings: SensorReading[];
  latitude?: number;
  longitude?: number;
}

const REQUEST_TIMEOUT_MS = 10_000;

export class SensorDataSource {
  private config: SensorDataConfig;

  constructor(config: SensorDataConfig) {
    this.config = config;
  }

  async fetchRecentReadings(): Promise<StationReadings[]> {
    const since = new Date(
      Date.now() - this.config.window_minutes * 60 * 1000,
    );

    let records: any[];
    try {
      const url = `${this.config.backend_api_url}/api/weather/data?startDate=${since.toISOString()}&limit=1000`;

      const controller = new AbortController();
      const timeoutId = setTimeout(
        () => controller.abort(),
        REQUEST_TIMEOUT_MS,
      );

      const response = await fetch(url, {
        signal: controller.signal,
        headers: { Accept: 'application/json' },
      });
      clearTimeout(timeoutId);

      if (!response.ok) {
        console.warn(
          `[sensor-data] Backend API returned HTTP ${response.status}, skipping`,
        );
        return [];
      }

      const body = (await response.json()) as {
        weatherData?: any[];
      };
      records = body.weatherData ?? [];
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        console.warn(
          `[sensor-data] Backend API timed out after ${REQUEST_TIMEOUT_MS}ms, skipping`,
        );
      } else {
        console.warn(
          `[sensor-data] Failed to fetch from backend: ${(err as Error).message}`,
        );
      }
      return [];
    }

    if (records.length === 0) return [];

    // Group by stationId
    const grouped = new Map<string, { readings: SensorReading[]; lat?: number; lon?: number }>();

    for (const rec of records) {
      const sid = rec.stationId;
      if (!sid) continue;

      const reading: SensorReading = {
        timestamp: rec.timestamp,
        ...(rec.temperature != null && { temperature: rec.temperature }),
        ...(rec.humidity != null && { humidity: rec.humidity }),
        ...(rec.pressure != null && { pressure: rec.pressure }),
        ...(rec.windSpeed != null && { windSpeed: rec.windSpeed }),
        ...(rec.airQuality != null && { airQuality: rec.airQuality }),
      };

      const group = grouped.get(sid);
      if (group) {
        group.readings.push(reading);
      } else {
        grouped.set(sid, {
          readings: [reading],
          lat: rec.latitude ?? rec.lat,
          lon: rec.longitude ?? rec.lon ?? rec.lng,
        });
      }
    }

    // Sort readings by timestamp within each station, sort stations by reading count desc
    const stations: StationReadings[] = [];
    for (const [stationId, data] of grouped) {
      data.readings.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
      stations.push({
        stationId,
        readings: data.readings,
        ...(data.lat != null && { latitude: data.lat }),
        ...(data.lon != null && { longitude: data.lon }),
      });
    }

    // Most active stations first, cap at max_stations_per_batch
    stations.sort((a, b) => b.readings.length - a.readings.length);
    return stations.slice(0, this.config.max_stations_per_batch);
  }
}
