import { describe, expect, it } from "vitest";
import {
  CASE_ENTRY_TYPE,
  REPORTER_ENTRY_TYPE,
  caseGoalLogEntryFromWire,
  caseGoalLogEntryToWire,
  reporterGoalLogEntryFromWire,
  reporterGoalLogEntryToWire,
} from "./case-metadata";

describe("CaseGoalLogEntry", () => {
  it("converts between wire and pretty format", () => {
    const wire = {
      i: "case-goal-1",
      cT: 1700000000000,
      t: CASE_ENTRY_TYPE,
      n: "Authors Guild v. Google, Inc.",
      c: "2d Cir.",
      y: 2015,
      dD: "October 16, 2015",
    };
    const pretty = caseGoalLogEntryFromWire(wire);
    expect(pretty).toEqual({
      id: "case-goal-1",
      creationTime: 1700000000000,
      path: undefined,
      type: "case",
      name: "Authors Guild v. Google, Inc.",
      court: "2d Cir.",
      year: 2015,
      decisionDate: "October 16, 2015",
    });

    const roundTripWire = caseGoalLogEntryToWire(pretty!);
    expect(roundTripWire).toEqual(wire);
  });

  it("handles string year in wire format", () => {
    const wire = {
      i: "case-goal-2",
      cT: 1700000000000,
      t: CASE_ENTRY_TYPE,
      n: "Brown v. Board of Education",
      c: null,
      y: "1954",
    };
    const pretty = caseGoalLogEntryFromWire(wire);
    expect(pretty?.year).toBe(1954);
    expect(pretty?.court).toBeNull();
  });
});

describe("ReporterGoalLogEntry", () => {
  it("converts between wire and pretty format", () => {
    const wire = {
      i: "reporter-goal-1",
      cT: 1700000000000,
      t: REPORTER_ENTRY_TYPE,
      r: "804 F.3d",
      sP: 202,
      rI: 0,
      cGI: "case-goal-1",
    };
    const pretty = reporterGoalLogEntryFromWire(wire);
    expect(pretty).toEqual({
      id: "reporter-goal-1",
      creationTime: 1700000000000,
      path: undefined,
      type: "rep",
      reporter: "804 F.3d",
      startPage: 202,
      reporterIndex: 0,
      caseGoalId: "case-goal-1",
    });

    const roundTripWire = reporterGoalLogEntryToWire(pretty!);
    expect(roundTripWire).toEqual(wire);
  });

  it("handles string startPage and reporterIndex in wire format", () => {
    const wire = {
      i: "reporter-goal-2",
      cT: 1700000000000,
      t: REPORTER_ENTRY_TYPE,
      r: "2015 U.S. App. LEXIS 17988",
      sP: "1",
      rI: "1",
    };
    const pretty = reporterGoalLogEntryFromWire(wire);
    expect(pretty?.startPage).toBe(1);
    expect(pretty?.reporterIndex).toBe(1);
    expect(pretty?.caseGoalId).toBeNull();
  });
});
