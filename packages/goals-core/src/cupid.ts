import { randomBytes } from "crypto";

export const UUID_MASK = 0x000000000000f000c000000000000000n;
export const UUID_V4_VALUE = 0x00000000000040008000000000000000n;
export const UUID_V5_VALUE = 0x00000000000050008000000000000000n;

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
    const bitLength = this.value === 0n ? 0 : this.value.toString(2).length;
    const bytesLength = Math.ceil(bitLength / 8);
    const bytes = new Uint8Array(bytesLength);
    for (let i = 0; i < bytesLength; i++) {
      bytes[i] = Number((this.value >> BigInt(i * 8)) & 0xffn);
    }
    return bytes;
  }

  static fromBytes(bytes: Uint8Array): Cupid {
    let value = 0n;
    for (let i = 0; i < bytes.length; i++) {
      value |= BigInt(bytes[i]) << BigInt(i * 8);
    }
    const maskedValue = value & UUID_MASK;
    if (maskedValue !== UUID_V4_VALUE && maskedValue !== UUID_V5_VALUE) {
      throw new Error(
        `Invalid UUID bytes: [${Array.from(bytes).join(", ")}], maskedValue: ${maskedValue.toString(16)}`,
      );
    }
    return Cupid.fromBigInt(value);
  }

  static random(): Cupid {
    const bytes = randomBytes(10);
    // Set UUID v4 version (4) and variant (10xx xxxx) bits in little-endian order
    bytes[9] = (bytes[9] & 0x0f) | 0x40;
    bytes[7] = (bytes[7] & 0x3f) | 0x80;
    return Cupid.fromBytes(bytes);
  }

  static decode(compressedUuid: string): Cupid {
    // If it's a UUID, parse as UUID
    if (
      /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(
        compressedUuid,
      )
    ) {
      return new Cupid(compressedUuid);
    }
    // Validate base64url characters
    if (!/^[A-Za-z0-9_-]+$/.test(compressedUuid)) {
      throw new Error(`Invalid compressed UUID string: ${compressedUuid}`);
    }
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
    return Buffer.from(this.toBytes()).toString("base64url");
  }

  toUuid(): string {
    const hex = this.value.toString(16).padStart(32, "0");
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(
      12,
      16,
    )}-${hex.substring(16, 20)}-${hex.substring(20)}`;
  }
}
