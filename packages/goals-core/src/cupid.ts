import { randomBytes } from "crypto";

/**
 * Compressed Universal Parseable IDentifier (Cupid)
 * Typescript port of Dart Cupid class from compressed_uuid.dart
 */
export enum EncodedCupidFormat {
  uuid = "uuid",
  base64Url = "base64Url",
}

export class Cupid {
  static defaultEncodingFormat: EncodedCupidFormat =
    EncodedCupidFormat.base64Url;
  readonly value: bigint;

  constructor(uuid: string) {
    this.value = Cupid.uuidToBigInt(uuid);
  }

  static uuidToBigInt(uuid: string): bigint {
    return BigInt("0x" + uuid.replace(/-/g, ""));
  }

  static fromBigInt(value: bigint): Cupid {
    const c = Object.create(Cupid.prototype);
    c.value = value;
    return c;
  }

  private toBytes(): Uint8Array {
    const hex = this.value.toString(16).padStart(32, "0");
    const bytes = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      bytes[i] = parseInt(hex.substring(i * 2, 2), 16);
    }
    return bytes;
  }

  static fromBytes(bytes: Uint8Array): Cupid {
    const hex = Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    return Cupid.fromBigInt(BigInt("0x" + hex));
  }

  static random(): Cupid {
    const bytes = randomBytes(16);
    // Set version (4) and variant bits for UUID v4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return Cupid.fromBytes(bytes);
  }

  static decode(compressedUuid: string): Cupid {
    // If it's a UUID, parse as UUID
    if (/^[0-9a-fA-F-]{36}$/.test(compressedUuid)) {
      return new Cupid(compressedUuid);
    }
    // Otherwise, treat as base64url
    let base64 = compressedUuid.replace(/-/g, "+").replace(/_/g, "/");
    while (base64.length % 4 !== 0) base64 += "=";
    const bytes = Buffer.from(base64, "base64");
    return Cupid.fromBytes(bytes);
  }

  encode(format: EncodedCupidFormat = Cupid.defaultEncodingFormat): string {
    if (format === EncodedCupidFormat.uuid) {
      return this.toUuid();
    }
    // base64url encoding, no padding
    return Buffer.from(this.toBytes())
      .toString("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  }

  toUuid(): string {
    const hex = this.value.toString(16).padStart(32, "0");
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(
      12,
      16,
    )}-${hex.substring(16, 20)}-${hex.substring(20)}`;
  }
}
