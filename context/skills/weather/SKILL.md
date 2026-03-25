---
name: weather
description: Get current weather and forecasts using free APIs (no API key required). Use when the user asks about weather, temperature, forecasts, or conditions for any location.
requires_bins: curl
---

# Weather

Two free services, no API keys needed. Use `exec` or `web_fetch` to query them.

## wttr.in (primary)

Quick one-liner via exec:
```bash
curl -s "wttr.in/London?format=3"
# Output: London: ⛅️ +8°C
```

Compact format with multiple fields:
```bash
curl -s "wttr.in/London?format=%l:+%c+%t+%h+%w"
# Output: London: ⛅️ +8°C 71% ↙5km/h
```

Full forecast:
```bash
curl -s "wttr.in/London?T"
```

Format codes: `%c` condition, `%t` temp, `%h` humidity, `%w` wind, `%l` location, `%m` moon phase.

Tips:
- URL-encode spaces: `wttr.in/New+York`
- Airport codes: `wttr.in/JFK`
- Units: `?m` (metric) `?u` (USCS/imperial)
- Today only: `?1` — Current only: `?0`

## Open-Meteo (fallback, JSON)

Free, no key, good for programmatic use. Use `web_fetch`:
```
web_fetch(url="https://api.open-meteo.com/v1/forecast?latitude=51.5&longitude=-0.12&current_weather=true")
```

Requires knowing coordinates. Look up coordinates first if needed:
```
web_fetch(url="https://geocoding-api.open-meteo.com/v1/search?name=London&count=1")
```

Returns JSON with temp, windspeed, weathercode.
