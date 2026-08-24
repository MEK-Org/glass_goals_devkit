export class HLC {
  private _timestamp: number;
  private _counter: number;

  constructor(
    timestamp: number,
    counter: number,
    public readonly clientId: string,
  ) {
    this._timestamp = timestamp;
    this._counter = counter;
  }

  public get timestamp(): number {
    return this._timestamp;
  }

  public get counter(): number {
    return this._counter;
  }

  public static now(clientId: string): HLC {
    return new HLC(Date.now(), 0, clientId);
  }

  // The counter is packed in radix 36, matching the Dart `hlc` package's
  // `count.toRadixString(36).padLeft(5, '0')` (pack) and
  // `int.parse(parts[1], radix: 36)` (unpack) — the wire format Dart Glass
  // Goals clients read and write. The port used radix 16, so any counter >= 16
  // within a single millisecond serialized to a string Dart parses (and
  // orders) wrong, and a Dart-written op deserialized to the wrong counter
  // here. Radices 16 and 36 agree only for counters 0..15. Refs
  // MEK-Org/meta-coder#1174.
  public pack(): string {
    return `${this._timestamp.toString().padStart(15, "0")}:${this._counter
      .toString(36)
      .padStart(5, "0")}:${this.clientId}`;
  }

  public static unpack(packed: string): HLC {
    const parts = packed.split(":");
    // Dart's unpack rejoins `parts.sublist(2)` with the delimiter, so a clientId
    // that itself contains ":" round-trips instead of being truncated at the
    // first one. base64url clientIds carry no ":" today, so this is
    // faithfulness insurance rather than a live fix — but it mirrors the Dart's
    // unpack exactly and costs one line. Refs MEK-Org/meta-coder#1174.
    const [ts, counter] = parts;
    const clientId = parts.slice(2).join(":");
    return new HLC(parseInt(ts, 10), parseInt(counter, 36), clientId);
  }

  /**
   * Returns a new HLC that is incremented.
   *
   * Matches the Dart `hlc` package (`hlc-1.0.4/lib/hlc.dart`):
   *
   *   HLC increment() => copy(count: count + 1);
   *
   * A pure counter bump — the timestamp is NOT advanced from the wall clock
   * here. The Dart's timestamp only moves forward via `receive()` (folding a
   * later remote op) or a fresh `HLC.now()`; local op creation just climbs the
   * counter on the frozen timestamp. The previous TS implementation consulted
   * `Date.now()` and reset to `(now, 0)` whenever the wall clock had advanced,
   * which diverged from the Dart at every op-creation site. Refs
   * MEK-Org/meta-coder#1174.
   */
  public increment(): HLC {
    return new HLC(this._timestamp, this._counter + 1, this.clientId);
  }

  /**
   * Mutates the current HLC and returns the packed string.
   * For backward compatibility with older code.
   */
  public next(): string {
    const now = Date.now();
    if (now > this._timestamp) {
      this._timestamp = now;
      this._counter = 0;
    } else {
      this._counter++;
    }
    return this.pack();
  }

  public receive(remote: HLC): HLC {
    const now = Date.now();
    const maxTs = Math.max(now, this._timestamp, remote.timestamp);

    if (maxTs > this._timestamp && maxTs > remote.timestamp) {
      return new HLC(maxTs, 0, this.clientId);
    }

    if (this._timestamp === remote.timestamp) {
      return new HLC(
        this._timestamp,
        Math.max(this._counter, remote.counter) + 1,
        this.clientId,
      );
    }

    if (this._timestamp > remote.timestamp) {
      return new HLC(this._timestamp, this._counter + 1, this.clientId);
    }

    return new HLC(remote.timestamp, remote.counter + 1, this.clientId);
  }

  public comesBefore(other: HLC | string): boolean {
    const otherPacked = typeof other === "string" ? other : other.pack();
    return this.pack() < otherPacked;
  }

  public comesAfter(other: HLC | string): boolean {
    const otherPacked = typeof other === "string" ? other : other.pack();
    return this.pack() > otherPacked;
  }
}
