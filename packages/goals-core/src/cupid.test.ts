import { describe, expect, it } from "vitest";
import { Cupid } from "./cupid";

describe("Cupid Dart-TS parity (#273)", () => {
  it("UUID v4/v5 round-trip (toUuid)", () => {
    const uuid_4 = "00000000-0000-4000-8000-000000000000";
    const cupid_4 = new Cupid(uuid_4);
    expect(cupid_4.toUuid()).toBe(uuid_4);

    const uuid_5 = "00000000-0000-5000-8000-000000000000";
    const cupid_5 = new Cupid(uuid_5);
    expect(cupid_5.toUuid()).toBe(uuid_5);
  });

  it("decode parity with compressed_uuid_test.dart", () => {
    expect(Cupid.decode("AAAAAAAAAIAAQA").toUuid()).toBe(
      "00000000-0000-4000-8000-000000000000",
    );
    expect(Cupid.decode("AAAAAAAAAIAAUA").toUuid()).toBe(
      "00000000-0000-5000-8000-000000000000",
    );
  });

  it("encode produces AAAAAAAAAIAAQA and AAAAAAAAAIAAUA", () => {
    expect(new Cupid("00000000-0000-4000-8000-000000000000").encode()).toBe(
      "AAAAAAAAAIAAQA",
    );
    expect(new Cupid("00000000-0000-5000-8000-000000000000").encode()).toBe(
      "AAAAAAAAAIAAUA",
    );
    expect(Cupid.decode("AAAAAAAAAIAAQA").encode()).toBe("AAAAAAAAAIAAQA");
    expect(Cupid.decode("AAAAAAAAAIAAUA").encode()).toBe("AAAAAAAAAIAAUA");
  });

  it("Cupid.random().encode() produces 14-character base64url strings matching Dart little-endian layout", () => {
    const UUID_MASK = 0x000000000000f000c000000000000000n;
    const UUID_V4_VALUE = 0x00000000000040008000000000000000n;

    for (let i = 0; i < 50; i++) {
      const cupid = Cupid.random();
      const encoded = cupid.encode();

      // Exactly 14 characters base64url
      expect(encoded).toHaveLength(14);
      expect(encoded).toMatch(/^[A-Za-z0-9_-]{14}$/);

      // Value mask must match UUID v4
      expect(cupid.value & UUID_MASK).toBe(UUID_V4_VALUE);

      // UUID format checks: upper 48 bits zero, version 4, variant 8/9/a/b
      const uuid = cupid.toUuid();
      expect(uuid).toMatch(
        /^00000000-0000-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/,
      );

      // Round-trip through Cupid.decode
      const decoded = Cupid.decode(encoded);
      expect(decoded.value).toBe(cupid.value);
      expect(decoded.toUuid()).toBe(uuid);
      expect(decoded.encode()).toBe(encoded);
    }
  });

  it("detects invalid encoded value and throws", () => {
    expect(() => Cupid.decode("somerandomstring")).toThrow();
    expect(() => Cupid.fromBytes(new Uint8Array(10))).toThrow();
  });
});
