#!/bin/bash
set -e

TGZ=$(npm pack)

rm -rf test-env
mkdir test-env
cd test-env

npm init -y
npm install typescript @types/node --save-dev
npm install ../$TGZ

cat << 'INNER_EOF' > test.ts
import { WireLongRunningOperationEntry, WireCourseMetadataLogEntry, WireReadingAssignmentLogEntry, WireSyllabusParseResultLogEntry, WireClassMapping } from "@thkp-eng/goals-types";

let a: WireLongRunningOperationEntry | undefined;
let b: WireCourseMetadataLogEntry | undefined;
let c: WireReadingAssignmentLogEntry | undefined;
let d: WireSyllabusParseResultLogEntry | undefined;
let e: WireClassMapping | undefined;
INNER_EOF

cat << 'INNER_EOF' > tsconfig.json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "skipLibCheck": true,
    "esModuleInterop": true
  }
}
INNER_EOF

npx tsc --noEmit

echo "Consumer package test passed"
