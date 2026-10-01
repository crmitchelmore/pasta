import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../_worker.js';
import {readFileSync} from 'node:fs';
test('Alpha routing never intercepts Stable downloads or home page', async()=>{
 const env={ASSETS:{fetch:async()=>new Response('stable')}};
 for(const path of ['/','/download','/appcast.xml']) assert.equal(await (await worker.fetch(new Request('https://pasta-app.com'+path),env)).text(),'stable');
 const routes=JSON.parse(readFileSync(new URL('../../_routes.json',import.meta.url)));
 assert.deepEqual(routes.include,['/alpha/*']);
});
test('Alpha pointer selects immutable prerelease assets and rejects malformed pointers',async(t)=>{
 t.mock.method(globalThis,'fetch',async()=>Response.json({tag:'alpha-build-42',version:'1.9.0'}));
 const result=await worker.fetch(new Request('https://pasta-app.com/alpha/download'),{});
 assert.equal(result.status,302);assert.equal(result.headers.get('Location'),'https://github.com/crmitchelmore/pasta/releases/download/alpha-build-42/Pasta%20Alpha-1.9.0.dmg');
 globalThis.fetch=async()=>Response.json({tag:'v1.9.0',version:'1.9.0'});
 assert.equal((await worker.fetch(new Request('https://pasta-app.com/alpha/appcast.xml'),{})).status,503);
});
