// R9: the typed tool-args layer is the ONLY sanctioned way to read ReAct tool
// params. These tests lock the Dart ToolArgsParser/ToolArgs 1:1 contract:
// JSON reject, cross-line value reject, int/bool/list coercion, Chinese-comma +
// bracket tolerance, and the ToolArgException message.
import {describe,it,expect} from "vitest";
import {ToolArgs, ToolArgsParser, ToolArgException} from "../src/tools/tool_args.js";
const NL = String.fromCharCode(10); // newline

describe("ToolArgsParser.parse (R9 contract)",()=>{
 it("rejects JSON (leading brace)",()=>{
   expect(ToolArgsParser.parse("{a:1}")).toBeNull();
   expect(ToolArgsParser.parse('{"a":1}')).toBeNull();
 });

 it("rejects a value line that has no colon (cross-line value)",()=>{
   // "content: 这是" then a continuation line without a colon => no-colon line => null
   const txt="content: hello"+NL+"second line has no colon";
   expect(ToolArgsParser.parse(txt)).toBeNull();
 });

 it("accepts an empty value + a following key",()=>{
   const m=ToolArgsParser.parse("a:"+NL+"b: c");
   expect(m).not.toBeNull();
   expect(m!.a).toBe("");
   expect(m!.b).toBe("c");
 });

 it("coerces int / bool / string[] ",()=>{
   const m=ToolArgsParser.parse("timeout: 60"+NL+"recursive: true"+NL+"hostIds: web1,web2,db1")!;
   expect(m.timeout).toBe(60);
   expect(m.recursive).toBe(true);
   expect(m.hostIds).toEqual(["web1","web2","db1"]);
 });

 it("negative int + false bool",()=>{
   const m=ToolArgsParser.parse("n: -5"+NL+"flag: false")!;
   expect(m.n).toBe(-5);
   expect(m.flag).toBe(false);
 });

 it("blank input -> null",()=>{
   expect(ToolArgsParser.parse("")).toBeNull();
   expect(ToolArgsParser.parse("   ")).toBeNull();
 });
 });

describe("ToolArgs typed accessors",()=>{
 it("getStringList splits ASCII + Chinese comma, strips JSON brackets",()=>{
   const a=ToolArgs.wrap({x:"[web1, web2]"});
   expect(a.getStringList("x")).toEqual(["web1","web2"]);
   const b=ToolArgs.wrap({x:"web1"+String.fromCharCode(0xFF0C)+"web2"});
   expect(b.getStringList("x")).toEqual(["web1","web2"]);
 });

 it("getStringList default when missing",()=>{
   expect(ToolArgs.wrap({}).getStringList("missing",["d"])).toEqual(["d"]);
 });

 it("getString joins a list value with commas",()=>{
   const a=ToolArgs.wrap({hostIds:["w","d"]});
   expect(a.getString("hostIds")).toBe("w,d");
 });

 it("getInt truncates float, defaults on missing",()=>{
   const a=ToolArgs.wrap({n:3.9,missing:undefined});
   expect(a.getInt("n")).toBe(3);
   expect(a.getInt("missing",42)).toBe(42);
 });

 it("getBool coerces string true/false",()=>{
   expect(ToolArgs.wrap({a:"true"}).getBool("a")).toBe(true);
   expect(ToolArgs.wrap({a:"false"}).getBool("a")).toBe(false);
   expect(ToolArgs.wrap({}).getBool("a",true)).toBe(true);
 });

 it("requireString throws ToolArgException on blank, message carries the key",()=>{
   const a=ToolArgs.wrap({});
   let threw="";
   try{a.requireString("path");}catch(e){threw=String((e as Error).message);} 
   expect(threw).toContain("path");
   expect(()=>new ToolArgException("cwd").message).not.toThrow();
 });

 it("firstOf returns first non-blank among candidate keys",()=>{
   expect(ToolArgs.wrap({remote:"/a"}).firstOf(["remote","remoteDir"])).toBe("/a");
   expect(ToolArgs.wrap({}).firstOf(["a","b"],"z")).toBe("z");
 });

 it("describe summarizes and truncates long values",()=>{
   const a=ToolArgs.wrap({k:"v"});
   expect(a.describe()).toContain("k=v");
   expect(ToolArgs.wrap({}).describe()).toBe("(no args)");
   const long=ToolArgs.wrap({k:"x".repeat(200)});
   expect(long.describe()).toContain("...");
 });

 it("ToolArgs.parse free-text -> wrapper",()=>{
   const a=ToolArgs.parse("url: https://example.com");
   expect(a?.getString("url")).toBe("https://example.com");
   expect(ToolArgs.parse("")).toBeNull();
 });
 });