import test from "node:test";
import assert from "node:assert/strict";
import { parseModels, parseStatus } from "../lib/cursor";
import { PUT, GET } from "../app/api/cursor/[resource]/route";

test("Cursor metadata cannot imply execution and catalogs validate names", () => {
  assert.equal(parseStatus({provider:"cursor",state:"connected",model_policy:"whitelist",inference_enabled:false,checked_at_ms:1}).state,"connected");
  assert.throws(()=>parseStatus({provider:"cursor",state:"connected",model_policy:"whitelist",inference_enabled:true,checked_at_ms:1}));
  assert.deepEqual(parseModels({models:[{id:"composer-2",name:"Composer"}]}),[{id:"composer-2",name:"Composer"}]);
  assert.throws(()=>parseModels({models:[{id:"composer-2"}]}));
});
test("Cursor proxy rejects cross-origin writes and execution resources", async () => {
  const params=Promise.resolve({resource:"policy"});
  assert.equal((await PUT(new Request("http://localhost/api/cursor/policy",{method:"PUT"}),{params})).status,403);
  assert.equal((await PUT(new Request("http://localhost/api/cursor/policy",{method:"PUT",headers:{origin:"https://other.example",host:"localhost"}}),{params})).status,403);
  assert.equal((await GET(new Request("http://localhost/api/cursor/agents"),{params:Promise.resolve({resource:"agents"})})).status,404);
});
