import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeReference,maskReference,referenceHash,encryptReference,decryptReference} from '../_shared/payments/reference.ts';
const secret=btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
const reference='SYNTHETIC-'+crypto.randomUUID();
test('NFC and whitespace normalization',()=>{assert.equal(normalizeReference('\t cafe\u0301 \n'),'caf\u00e9');assert.equal(normalizeReference(' '.repeat(10001)+'abc '),'abc');});
test('case and separators preserved',()=>assert.equal(normalizeReference(' aB-c_12 '),'aB-c_12'));
test('Unicode code point boundary',()=>{assert.equal([...normalizeReference('\u{1F600}'.repeat(100))].length,100);assert.throws(()=>normalizeReference('\u{1F600}'.repeat(101)));});
for(const [name,value] of Object.entries({blank:'  ',control:'a\nb',lineSeparator:'a\u2028b',null:'a\0b',bidi:'a\u202eb',surrogate:'\ud800',wrongType:42}))test('reject '+name,()=>assert.throws(()=>normalizeReference(value)));
test('short references never disclosed in full',()=>{for(const s of ['a','ab','abc','abcd'])assert.ok(!maskReference(s).includes(s));assert.equal(maskReference('abcde'),'********bcde');});
test('hash matches known SHA256 UTF8 vector',async()=>assert.equal(await referenceHash('abc'),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
test('same plaintext stable hash randomized authenticated ciphertext',async()=>{
 const hash=await referenceHash(reference),one=await encryptReference(reference,'easypaisa',hash,secret),two=await encryptReference(reference,'easypaisa',hash,secret);
 assert.notEqual(one,two);assert.ok(!one.includes(Buffer.from(reference).toString('hex')));
 assert.equal(await decryptReference(one,'easypaisa',hash,secret),reference);assert.equal(await decryptReference(two,'easypaisa',hash,secret),reference);
});
test('tampering and associated data changes fail closed',async()=>{
 const hash=await referenceHash(reference),value=await encryptReference(reference,'easypaisa',hash,secret);
 for(const [cipher,method,h] of [[value.slice(0,-2)+(value.endsWith('ff')?'00':'ff'),'easypaisa',hash],[value,'jazzcash',hash],[value,'easypaisa','0'.repeat(64)],['\\x02'+value.slice(4),'easypaisa',hash]])await assert.rejects(()=>decryptReference(cipher,method,h,secret),{code:'INTERNAL_ERROR'});
});
test('wrong key cannot decrypt',async()=>{const hash=await referenceHash(reference),value=await encryptReference(reference,'easypaisa',hash,secret);await assert.rejects(()=>decryptReference(value,'easypaisa',hash,btoa('a'.repeat(32))),{code:'INTERNAL_ERROR'});});
test('invalid or missing key fails without diagnostics',async()=>{const hash=await referenceHash(reference);for(const key of [undefined,'',btoa('a'.repeat(31)),'invalid',secret+'\n'])await assert.rejects(()=>encryptReference(reference,'easypaisa',hash,key),{code:'INTERNAL_ERROR',message:'An unexpected error occurred.'});});
