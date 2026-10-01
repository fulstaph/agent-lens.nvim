import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// Minimal MessagePack transport for Neovim's builtin RPC; no dependencies.
function pack(v) {
  if (v === null) return Buffer.from([0xc0]);
  if (typeof v === 'boolean') return Buffer.from([v ? 0xc3 : 0xc2]);
  if (typeof v === 'number') { const b=Buffer.alloc(5); b[0]=0xd2; b.writeInt32BE(v,1); return b; }
  if (typeof v === 'string') { const b=Buffer.from(v);const h=Buffer.alloc(5);h[0]=0xdb;h.writeUInt32BE(b.length,1);return Buffer.concat([h,b]); }
  if (Array.isArray(v)) { const h=Buffer.alloc(3);h[0]=0xdc;h.writeUInt16BE(v.length,1);return Buffer.concat([h,...v.map(pack)]); }
  const entries=Object.entries(v);const h=Buffer.alloc(3);h[0]=0xde;h.writeUInt16BE(entries.length,1);return Buffer.concat([h,...entries.flatMap(([k,x])=>[pack(k),pack(x)])]);
}
function unpack(b, start=0) {
  let p=start;
  const take=(n)=>{if(p+n>b.length) throw new RangeError('incomplete');const x=b.subarray(p,p+n);p+=n;return x;};
  const uint=(n)=>take(n).readUIntBE(0,n);
  const read=()=>{const c=uint(1);
    if(c<128) return c;if(c>=224) return c-256;
    if(c===0xc0) return null;if(c===0xc2 || c===0xc3) return c===0xc3;
    if(c>=0xcc && c<=0xcf) {const n=[1,2,4,8][c-0xcc];const x=take(n);return n===8?Number(x.readBigUInt64BE()):x.readUIntBE(0,n);}
    if(c>=0xd0 && c<=0xd3) {const n=[1,2,4,8][c-0xd0];const x=take(n);return n===8?Number(x.readBigInt64BE()):x.readIntBE(0,n);}
    if(c===0xca || c===0xcb) {const x=take(c===0xca?4:8);return c===0xca?x.readFloatBE():x.readDoubleBE();}
    if((c>=0xa0 && c<0xc0) || (c>=0xd9 && c<=0xdb)) return take(c>=0xa0 && c<0xc0?c-0xa0:uint([1,2,4][c-0xd9])).toString();
    if((c>=0x90 && c<0xa0) || c===0xdc || c===0xdd) {const n=c<0xa0?c-0x90:uint(c===0xdc?2:4);return Array.from({length:n},read);}
    if((c>=0x80 && c<0x90) || c===0xde || c===0xdf) {const n=c<0x90?c-0x80:uint(c===0xde?2:4);const out={};for(let i=0;i<n;i++)out[read()]=read();return out;}
    if(c>=0xc4 && c<=0xc6) return take(uint([1,2,4][c-0xc4]));
    if((c>=0xc7 && c<=0xc9) || (c>=0xd4 && c<=0xd8)) {const n=c<=0xc9?uint([1,2,4][c-0xc7]):[1,2,4,8,16][c-0xd4];take(1);return take(n);}
    throw new Error(`unknown RPC tag ${c}`);
  };
  const value=read();return [value,p];
}
const root=mkdtempSync(join(tmpdir(),'agent-lens-input-'));
writeFileSync(join(root,'file.lua'),'one\ntwo\nthree\n');
const editor=spawn('nvim',['--embed','--headless','-u','NONE','-i','NONE']);
let pending=Buffer.alloc(0),id=0,stderr='';const replies=new Map();
editor.stderr.on('data',chunk=>stderr+=chunk);
editor.stdout.on('data',chunk=>{
  pending=Buffer.concat([pending,chunk]);
  while(pending.length) {
    let message,used;try { [message,used]=unpack(pending); } catch(e) {if(e instanceof RangeError) break;throw e;}
    pending=pending.subarray(used);
    if(message[0]===1) {const answer=replies.get(message[1]);replies.delete(message[1]);if(message[2]) answer?.reject(new Error(JSON.stringify(message[2])));else answer?.resolve(message[3]);}
  }
});
async function rpc(method,args=[]) {
  const request=++id;
  const result=new Promise((resolve,reject)=>replies.set(request,{resolve,reject}));
  editor.stdin.write(pack([0,request,method,args]));
  let timer;try{return await Promise.race([result,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error(`RPC timeout ${stderr}`)),3000);})]);}finally{clearTimeout(timer);}
}
const lua=(code)=>rpc('nvim_exec_lua',[code,[]]);
const delay=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));
try {
  await rpc('nvim_ui_attach',[70,20,{rgb:true,ext_linegrid:true}]);
  await lua(`vim.opt.rtp:append(vim.fn.getcwd());vim.o.swapfile=false
    _G.root=vim.uv.fs_realpath(${JSON.stringify(root)});_G.follow=require('agent-lens.follow')
    require('agent-lens.config').setup({enabled=false,follow={enabled=true,window='split',animation=false}})
    follow.setup(require('agent-lens.config').options.follow)
    _G.user_win=vim.api.nvim_get_current_win();_G.user_buf=vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(user_buf,0,-1,false,{'unsaved text'})
    follow.record_location(root,{call_id='read',phase='start',tool='read',path='file.lua',line=2,agent='pi'})`);
  await rpc('nvim_input',['i']);await delay(40);
  assert((await lua('return vim.fn.mode(1)')).startsWith('i'),'RPC leaves real Insert mode active');
  await lua("follow.record_location(root,{call_id='edit',phase='start',tool='edit',path='file.lua',line=3,agent='pi'})");
  assert.equal(await lua('return follow.state().control'),'following','split stays following during unrelated Insert');
  await lua("assert(follow.record_preview(root,{toolCallId='edit',tool='edit',path='file.lua',line=2,sequence=1,agent='pi',lines={'one','DRAFT','three'}}))");
  assert.equal(await lua('return vim.api.nvim_get_current_win()'),await lua('return user_win'));
  await rpc('nvim_input',['X']);await delay(30);
  assert((await lua('return vim.api.nvim_buf_get_lines(user_buf,0,-1,false)[1]')).includes('X'),'typing remains in source');
  assert.equal(await lua('return vim.api.nvim_get_current_buf()'),await lua('return user_buf'));
  await rpc('nvim_input',['\x1b']);await delay(20);
  await lua('follow.stop()');
  console.log('Embedded input and split streaming OK');
} finally { editor.kill(); rmSync(root,{recursive:true,force:true}); }
