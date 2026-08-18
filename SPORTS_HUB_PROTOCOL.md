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

Game slate packet:

```json
{"version":1,"type":"slate","league":"MLB","games":[{"id":"101","away":"NYY","home":"BOS","awayScore":4,"homeScore":3,"status":"LIVE","clock":"BOT 7"},{"id":"102","away":"LAD","home":"SF","awayScore":2,"homeScore":2,"status":"FINAL","clock":"FINAL"}]}
```

Slate rules:

- `version` remains `1`; `type` is `"slate"`.
- `league` follows the single-game league rule and applies to every game.
- Legacy one-packet `slate` messages remain supported with 1 through 4 games.
- The complete compact UTF-8 packet must not exceed 512 bytes.
- Every game uses the single-game `away`, `home`, `awayScore`, `homeScore`, `status`, and `clock` rules.
- `id` is optional, stable event metadata with a maximum of 48 UTF-8 bytes. The ESP32 stores it but does not render it.
- A slate is fully validated before it replaces the active received games.

Chunked slate transfer (preferred):

```json
{"version":1,"type":"slate_start","league":"MLB","slateId":"transfer-123","totalGames":15,"totalChunks":4}
{"version":1,"type":"slate_chunk","slateId":"transfer-123","chunkIndex":0,"games":[{"id":"101","away":"NYY","home":"BOS","awayScore":4,"homeScore":3,"status":"LIVE","clock":"BOT 7"}]}
{"version":1,"type":"slate_end","slateId":"transfer-123"}
```

Chunked-transfer rules:

- A logical slate contains 1 through 20 games from one league.
- Every start, chunk, and end message is compact UTF-8 JSON no larger than 512 bytes.
- The sender chooses chunk boundaries conservatively based on encoded byte size and sends packets sequentially.
- `slateId` is required, non-empty, and at most 48 UTF-8 bytes. It identifies one transfer, not a sporting event.
- `chunkIndex` is zero-based. Chunks must arrive once each and in ascending order.
- Each game follows the same field rules as the one-packet slate, including optional event `id` metadata.
- `slate_end` activates the staged slate only when every declared chunk and game was received. Invalid, abandoned, or incomplete transfers leave the previous active slate unchanged.
- Staging expires after 30 seconds without an accepted packet. A new valid `slate_start` replaces any older staging transfer.
