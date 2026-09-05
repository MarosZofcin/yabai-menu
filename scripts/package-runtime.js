#!/usr/bin/env node
// Produces a single bounded data asset; no executable archives or extraction.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'Runtime/manifest.json'), 'utf8'));
const script = fs.readFileSync(path.join(root, 'Runtime/runtime.js'), 'utf8');
assert.equal(manifest.api, 2);
assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
const context = vm.createContext({});
vm.runInContext(script, context, {timeout: 1000});
function call(method, input) {
    context.testMethod = method; context.testInput = input;
    return JSON.parse(JSON.stringify(vm.runInContext('dispatch(testMethod,testInput)', context, {timeout: 1000})));
}
assert.deepEqual(call('selfTest', {}), {ok:true});
assert.equal(call('gitPlan', {ahead:2,behind:0}).integration, 'none');
assert.equal(call('gitPlan', {ahead:0,behind:3}).integration, 'fastForward');
assert.equal(call('gitPlan', {ahead:2,behind:3}).integration, 'rebase');
const systemResult = call('systemEvent', {
    kind:'clipboard.text.changed',
    payload:{text:'https://example.com/a?id=7&utm_source=x&fbclid=y'},
    state:{}
});
assert.deepEqual(systemResult, {operations:[{kind:'clipboard.replaceText',text:'https://example.com/a?id=7'}]});
assert.deepEqual(call('systemEvent', {
    kind:'workspace.didWake', payload:{}, state:{}
}), {operations:[]});
const window = (id,x,child) => ({id,space:1,display:1,frame:{x,y:0,w:500,h:800},
    'has-ax-reference':true,'is-visible':true,'is-floating':false,'is-hidden':false,
    'is-minimized':false,'split-type':'vertical','split-child':child,'stack-index':0});
const snapshots = [window(1,0,'first_child'), window(2,506,'second_child')];
const input = {target:1,snapshots,tolerance:1.5,candidateLimit:256};
assert.deepEqual(call('bspBranches',input)[0].windowIDs,[1,2]);
assert.throws(() => call('bspBranches',{...input,target:3}), /targetNotFound/);
assert.throws(() => call('bspBranches',{...input,snapshots:[snapshots[0]]}), /noParentBranch/);
const payload = JSON.stringify({...manifest,script}, null, 2) + '\n';
assert.ok(Buffer.byteLength(payload) < 1000000);
const output = process.argv[2] || path.join(root,'dist');
fs.mkdirSync(output,{recursive:true});
const filename = `Yabai-Menu-Runtime-${manifest.version}.json`;
fs.writeFileSync(path.join(output,filename),payload);
console.log(filename);
