// tail_buffer.test.ts - tests for src/utils/tail_buffer.ts
// Mirrors Dart output_buffer_utils_test.dart TailTextBuffer group (47 lines).

import {describe, it, expect} from "vitest";
import {TailTextBuffer} from "../src/utils/tail_buffer.js";

describe("TailTextBuffer (Dart oracle: output_buffer_utils_test.dart)", () => {

  it("trims once the buffer exceeds the cap", () => {
    const buffer = new TailTextBuffer(10);
    buffer.write('0123456789ABCDEFGHIJK'); // 21 chars > 10
    expect(buffer.length()).toBe(10);
    expect(buffer.tail()).toBe('BCDEFGHIJK');
  });

  it("tail() always caps at maxChars", () => {
    const buffer = new TailTextBuffer(8);
    buffer.write('abcdefghijklmnop');
    expect(buffer.tail().length).toBe(8);
    expect(buffer.tail()).toBe('ijklmnop');
  });

  it("empty buffer has length 0", () => {
    const buffer = new TailTextBuffer(5);
    expect(buffer.length()).toBe(0);
    expect(buffer.tail()).toBe("");
  });

  it("writing exactly the cap does not trim", () => {
    const buffer = new TailTextBuffer(5);
    buffer.write('hello');
    expect(buffer.length()).toBe(5);
    expect(buffer.tail()).toBe('hello');
    expect(buffer.isFull).toBe(true);
  });

  it("one char over the cap evicts the head", () => {
    const buffer = new TailTextBuffer(5);
    buffer.write('hello');
    buffer.write('w');
    expect(buffer.length()).toBe(5);
    expect(buffer.tail()).toBe('ellow');
  });

  it("clear() resets to empty", () => {
    const buffer = new TailTextBuffer(10);
    buffer.write('abcdefghij');
    buffer.clear();
    expect(buffer.length()).toBe(0);
    expect(buffer.isFull).toBe(false);
  });

  it("set() overwrites and truncates to cap", () => {
    const buffer = new TailTextBuffer(3);
    buffer.set('abcdef');
    expect(buffer.length()).toBe(3);
    expect(buffer.tail()).toBe('def');
  });

  it("constructor rejects invalid maxChars", () => {
    expect(() => new TailTextBuffer(0)).toThrow(RangeError);
    expect(() => new TailTextBuffer(-1)).toThrow(RangeError);
    expect(() => new TailTextBuffer(Infinity)).toThrow(RangeError);
  });
});