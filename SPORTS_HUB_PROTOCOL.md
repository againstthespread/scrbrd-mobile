# Sports Hub Protocol

Protocol version: 1

Advertising name:
Peter Sports Hub

Service UUID:
d8f6a9b0-7a5e-4e8c-9f2a-2b2f5b6c1001

Writable characteristic UUID:
d8f6a9b1-7a5e-4e8c-9f2a-2b2f5b6c1001

Temporary wake-notification characteristic UUID:
d8f6a9b2-7a5e-4e8c-9f2a-2b2f5b6c1001

Encoding:
compact UTF-8 JSON

Game packet:

```json
{"version":1,"type":"game","league":"NFL","away":"BUF","home":"NE","awayScore":17,"homeScore":24,"status":"LIVE","clock":"Q4 8:31"}
```

Required fields:

| Field | Type | Rule |
| --- | --- | --- |
| `version` | integer | Must be `1`. |
| `type` | string | Must be `"game"`. |
| `league` | string | Required, non-empty, maximum 12 UTF-8 bytes. |
| `away` | string | Required, non-empty, maximum 32 UTF-8 bytes. |
| `home` | string | Required, non-empty, maximum 32 UTF-8 bytes. |
| `awayScore` | integer | Required, 0 through 255. |
| `homeScore` | integer | Required, 0 through 255. |
| `status` | string | Required, one of `UPCOMING`, `LIVE`, or `FINAL`; maximum 8 UTF-8 bytes. |
| `clock` | string | Required, non-empty, maximum 24 UTF-8 bytes. |

Canonical statuses:

- `UPCOMING`
- `LIVE`
- `FINAL`

Unknown extra fields:
Allowed. The ESP32 firmware ignores fields it does not recognize.
